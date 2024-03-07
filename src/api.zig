const std = @import("std");
const logger = @import("log.zig");
const redis = @import("redis/client.zig");
const validators = @import("utils/validators.zig");
const UUID = @import("utils/uuid.zig").UUID;
const endpoint = @import("endpoints/handler.zig");
const response_helper = @import("utils/response_helper.zig");
const http = std.http;
const log = logger.get(.api);
const main = @import("main.zig");

pub var client: redis.Client = undefined;
var uni_to_ascii: std.StringHashMap([]const u8) = undefined;

pub fn init() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    try initStringHashMap(allocator);
    defer uni_to_ascii.deinit();

    const redis_ip = try std.net.Address.parseIp4(main.redis_addr, main.redis_port);
    const redis_connection = std.net.tcpConnectToAddress(redis_ip) catch |err| {
        log.err("Failed to connect to redis service! {any}", .{err});
        return err;
    };

    try client.init(redis_connection);
    defer client.close();

    var server = http.Server.init(allocator, .{});
    defer server.deinit();

    log.info("Listening at {s}:{d}", .{ main.server_addr, main.server_port });
    const address = std.net.Address.parseIp4(main.server_addr, main.server_port) catch unreachable;
    try server.listen(address);

    runServer(&server, allocator) catch |err| {
        // Handle server errors.
        log.err("server error: {}\n", .{err});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        std.os.exit(1);
    };
}

pub fn deinit() void {}

// Run the server and handle incoming requests.
fn runServer(server: *http.Server, allocator: std.mem.Allocator) !void {
    outer: while (true) {
        // Accept incoming connection.
        var response = try server.accept(.{
            .allocator = allocator,
        });
        defer response.deinit();

        // Handle errors during request processing.
        response.wait() catch |err| switch (err) {
            else => {
                log.err("wait::{any}", .{err});
                continue :outer;
            },
        };

        // Process the request.
        handleRequest(&response, allocator) catch |err| switch (err) {
            else => {
                log.err("handle::{any}", .{err});
                continue :outer;
            },
        };
    }
}

// Handle an individual request.
fn handleRequest(response: *http.Server.Response, allocator: std.mem.Allocator) !void {
    // Log the request details.
    log.info("{s} {s} {s}", .{ @tagName(response.request.method), @tagName(response.request.version), response.request.target });

    // Read the request body.
    const body_unparsed = try response.reader().readAllAlloc(allocator, 1024);
    const body_buf = try allocator.alloc(u8, body_unparsed.len);
    const body = try parseBodyToAscii(body_unparsed, body_buf);
    defer allocator.free(body_unparsed);
    defer allocator.free(body_buf);

    // Set "connection" header to "keep-alive" if present in request headers.
    if (response.request.headers.contains("connection")) {
        try response.headers.append("connection", "keep-alive");
    }

    if (std.mem.startsWith(u8, response.request.target, "/")) {
        try response.headers.append("content-type", "text/plain");
    }

    endpoint.parseEndpoint(response, allocator, body) catch |err| {
        switch (err) {
            validators.APIError.InvalidEmail => log.err("endpoint-err:{any}", .{err}),
            validators.APIError.InvalidPassword => log.err("endpoint-err:{any}", .{err}),
            validators.APIError.InvalidUsername => log.err("endpoint-err:{any}", .{err}),
            validators.APIError.NameTaken => log.err("endpoint-err:{any}", .{err}),
            validators.APIError.EmailTaken => log.err("endpoint-err:{any}", .{err}),
            validators.APIError.FailedLock => log.err("endpoint-err:{any}", .{err}),
            validators.APIError.FormTooLarge => log.err("endpoint-err:{any}", .{err}),
            validators.APIError.MissingData => log.err("endpoint-err:{any}", .{err}),
            else => { //missing endpoint
                sendErrorPage(response, allocator) catch |internal_err| {
                    return internal_err;
                };
            },
        }
    };

    if (response.state == .responded)
        try response.finish();
}

fn sendErrorPage(response: *http.Server.Response, allocator: std.mem.Allocator) !void {
    if (response.state == .waited) //If waited then we need to send headers
        try response.do();

    if (response.request.method != .HEAD) {
        const buf = try response_helper.writeError(response, "Not found", allocator);
        defer allocator.free(buf);
    }
}

pub fn parseBodyToAscii(body: []const u8, buf: []u8) ![]u8 {
    log.debug("before-body:{s}", .{body});
    var changed: usize = 0;
    var skip: usize = 0;
    var actual_index: usize = 0;
    for (0.., body) |i, ch| {
        actual_index = i - (changed * 2);
        if (skip != 0) {
            skip -= 1;
            continue;
        }

        if (i + 1 >= body.len) {
            buf[actual_index] = ch;
            continue;
        }

        if (!std.mem.eql(u8, body[i .. i + 1], "%")) {
            buf[actual_index] = ch;
            continue;
        }

        if (i + 2 >= body.len) {
            buf[actual_index] = ch;
            continue;
        }

        const uni_ch = body[i .. i + 3];
        if (uni_to_ascii.get(uni_ch)) |v| {
            changed += 1;
            for (0.., v) |c, parsed_ch| {
                buf[actual_index + c] = parsed_ch;
                skip = 2;
            }
        } else {
            buf[actual_index] = ch;
            log.err("Failed to find '{s}' in stringMap", .{uni_ch});
        }
    }
    log.debug("after-body:{s} changed:{any}", .{ buf[0 .. actual_index + 1], changed });
    return buf[0 .. actual_index + 1];
}

pub fn initStringHashMap(allocator: std.mem.Allocator) !void {
    uni_to_ascii = std.StringHashMap([]const u8).init(allocator);
    try uni_to_ascii.put("%21", "!");
    try uni_to_ascii.put("%22", "\"");
    try uni_to_ascii.put("%23", "#");
    try uni_to_ascii.put("%24", "$");
    try uni_to_ascii.put("%25", "%");
    try uni_to_ascii.put("%26", "&");
    try uni_to_ascii.put("%27", "'");
    try uni_to_ascii.put("%28", "(");
    try uni_to_ascii.put("%29", ")");
    try uni_to_ascii.put("%30", "*");
    try uni_to_ascii.put("%31", "+");
    try uni_to_ascii.put("%32", ",");
    try uni_to_ascii.put("%33", "-");
    try uni_to_ascii.put("%34", ".");
    try uni_to_ascii.put("%35", "/");
    try uni_to_ascii.put("%3A", ":");
    try uni_to_ascii.put("%3B", ";");
    try uni_to_ascii.put("%3C", "<");
    try uni_to_ascii.put("%3D", "=");
    try uni_to_ascii.put("%3E", ">");
    try uni_to_ascii.put("%3F", "?");
    try uni_to_ascii.put("%40", "@");
    try uni_to_ascii.put("%5B", "[");
    try uni_to_ascii.put("%5C", "\\");
    try uni_to_ascii.put("%5D", "]");
    try uni_to_ascii.put("%5E", "^");
    try uni_to_ascii.put("%5F", "_");
    try uni_to_ascii.put("%60", "`");
    try uni_to_ascii.put("%7B", "{");
    try uni_to_ascii.put("%7C", "|");
    try uni_to_ascii.put("%7D", "}");
    try uni_to_ascii.put("%7E", "~");
}

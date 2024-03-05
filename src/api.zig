const std = @import("std");
const logger = @import("log.zig");
const redis = @import("redis/client.zig");
const validators = @import("utils/validators.zig");
const UUID = @import("utils/uuid.zig").UUID;
const endpoint = @import("endpoints/handler.zig");
const http = std.http;

const redis_addr = "127.0.0.1";
const redis_port = 6379;

const server_addr = "127.0.0.1";
const server_port = 8080;

const log = logger.get(.api);

pub var client: redis.Client = undefined;

pub fn init() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const redis_ip = try std.net.Address.parseIp4(redis_addr, redis_port);
    const redis_connection = std.net.tcpConnectToAddress(redis_ip) catch |err| {
        log.err("Failed to connect to redis service! {any}", .{err});
        return err;
    };

    try client.init(redis_connection);
    defer client.close();

    var server = http.Server.init(allocator, .{});
    defer server.deinit();

    log.info("Listening at {s}:{d}", .{ server_addr, server_port });
    const address = std.net.Address.parseIp4(server_addr, server_port) catch unreachable;
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
    const body = try response.reader().readAllAlloc(allocator, 1024);
    defer allocator.free(body);

    // Set "connection" header to "keep-alive" if present in request headers.
    if (response.request.headers.contains("connection")) {
        try response.headers.append("connection", "keep-alive");
    }

    if (std.mem.startsWith(u8, response.request.target, "/")) {
        try response.headers.append("content-type", "text/plain");
    }

    // Check if the request target starts with "/get".
    if (!try endpoint.parseEndpoint(response, allocator)) {
        try sendErrorPage(response);
    }

    try response.finish();
}

fn sendErrorPage(response: *http.Server.Response) !void {
    // Set "content-type" header to "text/plain".
    response.transfer_encoding = .{ .content_length = 10 };
    try response.headers.append("content-type", "text/plain");
    try response.do();
    if (response.request.method != .HEAD) {
        try response.writeAll("Not Found\n");
    }
}

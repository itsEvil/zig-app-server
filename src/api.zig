const std = @import("std");
const logger = @import("log.zig");
const redis = @import("redis/client.zig");
const validators = @import("utils/validators.zig");
const UUID = @import("utils/uuid.zig").UUID;
const http = std.http;

const redis_addr = "127.0.0.1";
const redis_port = 6379;

const server_addr = "127.0.0.1";
const server_port = 8080;

const log = logger.get(.api);

var client: redis.Client = undefined;

pub fn init() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const redis_ip = try std.net.Address.parseIp4(redis_addr, redis_port);
    const redis_connection = try std.net.tcpConnectToAddress(redis_ip);

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
    const body = try response.reader().readAllAlloc(allocator, 8192);
    defer allocator.free(body);

    // Set "connection" header to "keep-alive" if present in request headers.
    if (response.request.headers.contains("connection")) {
        try response.headers.append("connection", "keep-alive");
    }

    if (std.mem.startsWith(u8, response.request.target, "/")) {
        try response.headers.append("content-type", "text/plain");
    }

    // Check if the request target starts with "/get".
    if (!try parseEndpoint(response, allocator)) {
        try sendErrorPage(response);
    }
}

fn sendErrorPage(response: *http.Server.Response) !void {
    // Set "content-type" header to "text/plain".
    response.transfer_encoding = .{ .content_length = 10 };
    try response.headers.append("content-type", "text/plain");
    try response.do();
    if (response.request.method != .HEAD) {
        try response.writeAll("Not Found\n");
    }
    try response.finish();
}

fn parseEndpoint(response: *http.Server.Response, allocator: std.mem.Allocator) !bool {
    if (std.mem.startsWith(u8, response.request.target, "/account/register")) {
        try handleRegister(response, allocator);
        return true;
    }

    return false;
}

fn handleRegister(response: *http.Server.Response, allocator: std.mem.Allocator) !void {
    //response.transfer_encoding = .{ .content_length = 64 };
    // Set "content-type" header to "text/plain".
    response.transfer_encoding = .chunked;
    try response.headers.append("content-type", "text/plain");

    // Write the response body.
    try response.do();
    const req = response.request;
    const target = req.target;

    if (response.request.method != .HEAD) {
        var queries = std.mem.splitSequence(u8, target, "?");

        while (queries.next()) |msg| {
            try response.writeAll(msg);
            try response.writeAll("\n");
        }

        try validators.checkSize(response, 5);

        var details = std.mem.splitSequence(u8, response.request.target, "=");
        details.reset();
        _ = details.next();
        var email: []const u8 = "";
        var password: []const u8 = "";
        var username: []const u8 = "";

        if (details.next()) |data| {
            const email_index = std.mem.indexOf(u8, data, "?");
            if (email_index) |index| {
                email = data[0..index];
                log.info("email: '{s}'", .{email});
            }
        }

        if (details.next()) |data| {
            const password_index = std.mem.indexOf(u8, data, "?");
            if (password_index) |index| {
                password = data[0..index];
                log.info("password: '{s}'", .{password});
            }
        }

        if (details.next()) |data| {
            username = data;
            log.info("username: '{s}'", .{username});
        }

        //validate basic user inputs
        if (email.len == 0 or password.len == 0 or username.len == 0)
            return validators.APIError.MissingData;

        if (!validators.isValidEmail(email))
            return validators.APIError.InvalidEmail;

        if (!validators.isValidPassword(password))
            return validators.APIError.InvalidPassword;

        if (!validators.isValidUsername(username))
            return validators.APIError.InvalidUsername;

        const uuid = UUID.init();
        const uuid_arr = try allocator.alloc(u8, 36);
        defer allocator.free(uuid_arr);
        uuid.to_string(uuid_arr);
        log.info("uuid: {s}", .{uuid_arr});
        //check if Db already has email or username registered
        try client.send(void, .{ "SETNX", "regLock", uuid_arr });
        const lock_result = try client.sendAlloc([]const u8, allocator, .{ "GET", "regLock" });
        log.info("lock result: {s}", .{lock_result});

        if (!std.mem.eql(u8, uuid_arr, lock_result)) {
            log.info("lock uuid not the same!", .{});
            return validators.APIError.FailedLock;
        }

        const email_upper = std.ascii.upperString(try allocator.alloc(u8, email.len), email);
        defer allocator.free(email_upper);

        const username_upper = std.ascii.upperString(try allocator.alloc(u8, username.len), username);
        defer allocator.free(username_upper);

        const email_exists = try client.send(i64, .{ "HEXISTS", "logins", email_upper });
        log.info("Does email exist: {d}", .{email_exists});
        if (email_exists != 0)
            return validators.APIError.EmailTaken;

        const name_exists = try client.send(i64, .{ "HEXISTS", "names", username_upper });
        log.info("Does name exist: {d}", .{name_exists});
        if (name_exists != 0)
            return validators.APIError.NameTaken;

        const email_set_result = try client.send(i64, .{ "HSET", "logins", email_upper, "{}" });
        log.info("Did we set email: {d}", .{email_set_result});

        const name_set_result = try client.send(i64, .{ "HSET", "names", username_upper, email_upper });
        log.info("Did we set username: {d}", .{name_set_result});

        const next_acc_id = try client.send(i64, .{ "INCR", "nextAccId" });
        log.info("Next account Id: {d}", .{next_acc_id});

        const account_field = try std.fmt.allocPrint(allocator, "account.{d}", .{next_acc_id});

        const account_result = try client.send(i64, .{ "HSET", account_field, "email", email });
        log.info("account result: {d}", .{account_result});

        //check if Db already has email or username registered
        try client.send(void, .{ "DEL", "regLock" });
        try response.finish();
    }
}

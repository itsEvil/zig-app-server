const std = @import("std");
const api = @import("api.zig");
const logger = @import("log.zig");
const log = logger.get(.main);

const std_options = .{
    .enable_segfault_handler = std.debug.default_enable_segfault_handler,
    .log_level = std.log.Level.err,
    .logFn = myLogFn,
};

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) < @intFromEnum(main.std_options.log_level))
        return;

    const scope_prefix = @tagName(scope) ++ "::";
    const prefix = comptime level.asText() ++ "::" ++ scope_prefix;
    // Print the message to stderr, silently ignoring any errors
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    const stderr = std.io.getStdErr().writer();
    stderr.print(prefix ++ format ++ "\n", args) catch |err| {
        std.debug.print("err:{any}", .{err});
    };
}

pub const redis_addr = "127.0.0.1";
pub const redis_port = 6379;

pub const server_addr = "127.0.0.1";
pub const server_port = 8080;

pub fn main() !void {
    log.info("Starting up...", .{});

    try api.init();
    defer api.deinit();
}

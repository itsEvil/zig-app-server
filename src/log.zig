const std = @import("std");
const log = std.log;

pub const std_options = .{
    .log_level = .debug,
    .logFn = myLogFn,
};

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = @tagName(scope) ++ "::";
    const prefix = comptime level.asText() ++ "::" ++ scope_prefix;

    // Print the message to stderr, silently ignoring any errors
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
}

pub fn get(comptime scope: @Type(.EnumLiteral)) type {
    return std.log.scoped(scope);
}

pub fn read() !void {
    var buf: [10]u8 = undefined;
    _ = try std.io.getStdIn().reader().readUntilDelimiterOrEof(buf[0..], '\n');
}

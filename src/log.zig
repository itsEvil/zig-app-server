const std = @import("std");
const main = @import("main.zig");
const log = std.log;

pub fn myLogFn(
    comptime level: log.Level,
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

pub fn get(comptime scope: @Type(.EnumLiteral)) type {
    return log.scoped(scope);
}

pub fn read() !void {
    var buf: [10]u8 = undefined;
    _ = try std.io.getStdIn().reader().readUntilDelimiterOrEof(buf[0..], '\n');
}

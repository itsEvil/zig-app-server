const std = @import("std");

pub fn addXml(comptime tag: []const u8, comptime value_fmt: []const u8, value: anytype, allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "<{s}>" ++ value_fmt ++ "</{s}>", .{ tag, value, tag });
}

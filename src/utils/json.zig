const std = @import("std");
const json = std.json;
const logger = @import("../log.zig");
const log = logger.get(.json_utils);

pub fn toString(value: anytype, allocator: std.mem.Allocator) !std.ArrayList(u8) {
    var string = std.ArrayList(u8).init(allocator);
    try std.json.stringify(value, .{}, string.writer());
    return string;
}

const std = @import("std");
const api = @import("api.zig");
const logger = @import("log.zig");
const log = logger.get(.main);

pub fn main() !void {
    log.info("Starting up...", .{});

    try api.init();
    defer api.deinit();
}

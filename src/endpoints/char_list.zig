const std = @import("std");
const validators = @import("../utils/validators.zig");
const redis = @import("../redis/client.zig");
const http = std.http;

const logger = @import("../log.zig");
const log = logger.get(.char_list);

const api = @import("../api.zig");

pub fn handle(_: *http.Server.Response, _: std.mem.Allocator) !void {}

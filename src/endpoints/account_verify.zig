const std = @import("std");
const validators = @import("../utils/validators.zig");
const redis = @import("../redis/client.zig");
const http = std.http;

const handler = @import("handler.zig");
const logger = @import("../log.zig");
const log = logger.get(.acc_verify);

const api = @import("../api.zig");

pub fn handle(_: *http.Server.Response, _: std.mem.Allocator, _: handler.Credentials) !void {}

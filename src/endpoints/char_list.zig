const std = @import("std");
const validators = @import("../utils/validators.zig");
const redis = @import("../redis/client.zig");
const http = std.http;

const handler = @import("handler.zig");
const logger = @import("../log.zig");
const log = logger.get(.char_list);

const api = @import("../api.zig");
const helper = @import("../utils/response_helper.zig");

pub fn handle(response: *http.Server.Response, allocator: std.mem.Allocator, creds: handler.Credentials) !void {
    log.debug("handle::{s}::{s}", .{ creds.email, creds.password });
    const buf = try helper.writeError(response, "Not implemented", allocator);
    defer allocator.free(buf);
}

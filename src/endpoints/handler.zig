const std = @import("std");
const redis = @import("../redis/client.zig");
const acc_register = @import("account_register.zig");
const acc_verify = @import("account_verify.zig");
const char_list = @import("char_list.zig");
const http = std.http;

pub fn parseEndpoint(response: *http.Server.Response, allocator: std.mem.Allocator) !bool {
    if (std.mem.startsWith(u8, response.request.target, "/account/verify")) {
        try acc_verify.handle(response, allocator);
        return true;
    } else if (std.mem.startsWith(u8, response.request.target, "/char/list")) {
        try char_list.handle(response, allocator);
        return true;
    } else if (std.mem.startsWith(u8, response.request.target, "/account/register")) {
        try acc_register.handle(response, allocator);
        return true;
    }

    return false;
}

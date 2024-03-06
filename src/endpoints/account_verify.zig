const std = @import("std");
const validators = @import("../utils/validators.zig");
const redis = @import("../redis/client.zig");
const http = std.http;

const handler = @import("handler.zig");
const logger = @import("../log.zig");
const log = logger.get(.acc_verify);

const api = @import("../api.zig");
const helper = @import("../utils/response_helper.zig");
const json = @import("../utils/json.zig");
const rParser = @import("../redis/parser.zig").RESP3Parser;

pub const SlotCost = 1000;
pub const SlotCurrency = 1; //0 gold, 1 fame, 2 guild fame

pub fn handle(response: *http.Server.Response, allocator: std.mem.Allocator, creds: handler.Credentials) !void {
    log.debug("handle::{s}::{s}", .{ creds.email, creds.password });

    const email_buf = try allocator.alloc(u8, creds.email.len);
    defer allocator.free(email_buf);
    const email_upper = std.ascii.upperString(email_buf, creds.email);

    const email_reply = try api.client.sendAlloc([]const u8, allocator, .{ "HGET", "logins", email_upper });

    log.debug("Reply: {s}", .{email_reply});

    const json_obj = try json.parse(email_reply, allocator);
    defer json_obj.deinit(allocator);
    //defer allocator.destroy(json_obj);

    const salt = json_obj.get("salt").string();
    const hash = json_obj.get("hash").string();
    const accId = json_obj.get("accountId").integer();

    const salted_pass = try validators.combineStrings(creds.password, salt, allocator);
    const hashed_pass = try validators.generateHash(salted_pass, allocator);
    defer allocator.free(salted_pass);
    defer allocator.free(hashed_pass);

    if (!std.mem.eql(u8, hashed_pass, hash)) {
        const buf = try helper.writeError(response, "Invalid Credentials", allocator);
        defer allocator.free(buf);
        return validators.APIError.InvalidCredentials;
    }
    const account_field = try validators.getAccountField(accId, allocator);
    const account_reply = api.client.sendAlloc([][]const u8, allocator, .{ "HGETALL", account_field }) catch |err| {
        log.err("senderror:{any}", .{err});
        return err;
    };
    defer allocator.free(account_field);
    defer allocator.free(account_reply);

    const account = try handler.AccountStruct.parse(account_reply);
    const xml = try account.toXml(accId, allocator);
    defer allocator.free(xml);
    log.debug("xml: {s}", .{xml});
    try helper.writeXML(response, xml);
}

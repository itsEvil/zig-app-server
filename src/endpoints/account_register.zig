const std = @import("std");
const validators = @import("../utils/validators.zig");
const redis = @import("../redis/client.zig");
const http = std.http;

const UUID = @import("../utils/uuid.zig").UUID;
const logger = @import("../log.zig");
const log = logger.get(.acc_register);

const api = @import("../api.zig");

pub fn handle(response: *http.Server.Response, allocator: std.mem.Allocator) !void {
    response.transfer_encoding = .chunked;
    try response.headers.append("content-type", "text/plain");

    // Write the response body.
    try response.do();
    const req = response.request;
    const target = req.target;

    if (response.request.method != .HEAD) {
        var queries = std.mem.splitSequence(u8, target, "?");

        while (queries.next()) |msg| {
            try response.writeAll(msg);
            try response.writeAll("\n");
        }

        try validators.checkSize(response, 5);

        var details = std.mem.splitSequence(u8, response.request.target, "=");
        details.reset();
        _ = details.next();
        var email: []const u8 = "";
        var password: []const u8 = "";
        var username: []const u8 = "";

        if (details.next()) |data| {
            const email_index = std.mem.indexOf(u8, data, "?");
            if (email_index) |index| {
                email = data[0..index];
                log.debug("email: '{s}'", .{email});
            }
        }

        if (details.next()) |data| {
            const password_index = std.mem.indexOf(u8, data, "?");
            if (password_index) |index| {
                password = data[0..index];
                log.debug("password: '{s}'", .{password});
            }
        }

        if (details.next()) |data| {
            username = data;
            log.debug("username: '{s}'", .{username});
        }

        //validate basic user inputs
        if (email.len == 0 or password.len == 0 or username.len == 0)
            return validators.APIError.MissingData;

        if (!validators.isValidEmail(email))
            return validators.APIError.InvalidEmail;

        if (!validators.isValidPassword(password))
            return validators.APIError.InvalidPassword;

        if (!validators.isValidUsername(username))
            return validators.APIError.InvalidUsername;

        const uuid = UUID.init();
        const uuid_arr = try allocator.alloc(u8, 36);
        defer allocator.free(uuid_arr);
        uuid.to_string(uuid_arr);
        log.debug("uuid: {s}", .{uuid_arr});
        //check if Db already has email or username registered
        try api.client.send(void, .{ "SETNX", "regLock", uuid_arr });
        const lock_result = try api.client.sendAlloc([]const u8, allocator, .{ "GET", "regLock" });
        log.debug("lock result: {s}", .{lock_result});

        if (!std.mem.eql(u8, uuid_arr, lock_result)) {
            log.err("lock uuid not the same!", .{});
            return validators.APIError.FailedLock;
        }

        //only unlock when we exit the register request when its our lock
        defer api.client.send(void, .{ "DEL", "regLock" }) catch |err| {
            log.err("regLockErr::{any}", .{err});
        };

        const email_upper = std.ascii.upperString(try allocator.alloc(u8, email.len), email);
        defer allocator.free(email_upper);

        const username_upper = std.ascii.upperString(try allocator.alloc(u8, username.len), username);
        defer allocator.free(username_upper);

        const email_exists = try api.client.send(i64, .{ "HEXISTS", "logins", email_upper });
        log.debug("Does email exist: {d}", .{email_exists});
        if (email_exists != 0)
            return validators.APIError.EmailTaken;

        const name_exists = try api.client.send(i64, .{ "HEXISTS", "names", username_upper });
        log.debug("Does name exist: {d}", .{name_exists});
        if (name_exists != 0)
            return validators.APIError.NameTaken;

        const email_set_result = try api.client.send(i64, .{ "HSET", "logins", email_upper, "{}" });
        log.debug("Did we set email: {d}", .{email_set_result});

        const name_set_result = try api.client.send(i64, .{ "HSET", "names", username_upper, email_upper });
        log.debug("Did we set username: {d}", .{name_set_result});

        const next_acc_id = try api.client.send(i64, .{ "INCR", "nextAccId" });
        log.debug("Next account Id: {d}", .{next_acc_id});

        const account_field = try std.fmt.allocPrint(allocator, "account.{d}", .{next_acc_id});

        const account = AccountStruct{
            .email = email,
            .name = username,
        };

        const command = .{
            "HSET",           account_field,
            "email",          account.email,
            "name",           account.name,
            "rank",           account.rank,
            "guildId",        account.guildId,
            "vaultCount",     account.vaultCount,
            "maxCharSlot",    account.maxCharSlots,
            "regTime",        std.time.timestamp(),
            "fame",           account.fame,
            "totalFame",      account.totalFame,
            "credits",        account.credits,
            "totalCredits",   account.totalCredits,
            "passResetToken", account.passResetToken,
        };

        const account_result = try api.client.send(i64, command);

        log.debug("account result: {d}", .{account_result});
    }
}

//Default values for new accounts
const AccountStruct = struct {
    email: []const u8,
    name: []const u8,
    rank: i32 = 0,
    guildId: i32 = 0,
    guildRank: i32 = 0,
    vaultCount: i32 = 2,
    maxCharSlots: i32 = 2,
    regTime: i64 = 0,
    fame: i32 = 0,
    totalFame: i32 = 0,
    credits: i32 = 0,
    totalCredits: i32 = 0,
    passResetToken: []const u8 = "",
};

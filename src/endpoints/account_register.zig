const std = @import("std");
const validators = @import("../utils/validators.zig");
const redis = @import("../redis/client.zig");
const http = std.http;
const handler = @import("handler.zig");
const response_helper = @import("../utils/response_helper.zig");
const UUID = @import("../utils/uuid.zig").UUID;
const logger = @import("../log.zig");
const log = logger.get(.acc_register);
const json = @import("../utils/json.zig");

const api = @import("../api.zig");

pub fn handle(response: *http.Server.Response, allocator: std.mem.Allocator, credentials: handler.Credentials) !void {
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
        try response_helper.writeError(response, "Failed Lock, Try again", allocator);
        return validators.APIError.FailedLock;
    }

    //only unlock when we exit the register request when its our lock
    defer api.client.send(void, .{ "DEL", "regLock" }) catch |err| {
        log.err("regLockErr::{any}", .{err});
    };

    const email_buf = try allocator.alloc(u8, credentials.email.len);
    defer allocator.free(email_buf);
    const email_upper = std.ascii.upperString(email_buf, credentials.email);

    const username_buf = try allocator.alloc(u8, credentials.username.len);
    defer allocator.free(username_buf);
    const username_upper = std.ascii.upperString(username_buf, credentials.username);

    const email_exists = try api.client.send(i64, .{ "HEXISTS", "logins", email_upper });
    log.debug("Does email exist: {d}", .{email_exists});
    if (email_exists != 0) {
        try response_helper.writeError(response, "Email taken", allocator);
        return validators.APIError.EmailTaken;
    }

    const name_exists = try api.client.send(i64, .{ "HEXISTS", "names", username_upper });
    log.debug("Does name exist: {d}", .{name_exists});
    if (name_exists != 0) {
        try response_helper.writeError(response, "Name taken", allocator);
        return validators.APIError.NameTaken;
    }

    const name_set_result = try api.client.send(i64, .{ "HSET", "names", username_upper, email_upper });
    log.debug("Did we set username: {d}", .{name_set_result});

    const next_acc_id = try api.client.send(i64, .{ "INCR", "nextAccId" });
    log.debug("Next account Id: {d}", .{next_acc_id});

    const account_field = try std.fmt.allocPrint(allocator, "account.{d}", .{next_acc_id});

    const newAccount = handler.AccountStruct{
        .email = credentials.email,
        .name = credentials.username,
    };

    const command = .{
        "HSET",           account_field,
        "email",          newAccount.email,
        "name",           newAccount.name,
        "rank",           newAccount.rank,
        "guildId",        newAccount.guildId,
        "vaultCount",     newAccount.vaultCount,
        "maxCharSlot",    newAccount.maxCharSlots,
        "regTime",        std.time.timestamp(),
        "fame",           newAccount.fame,
        "totalFame",      newAccount.totalFame,
        "credits",        newAccount.credits,
        "totalCredits",   newAccount.totalCredits,
        "passResetToken", newAccount.passResetToken,
    };

    const login_info = try validators.generateLoginInfo(credentials, allocator, next_acc_id);
    defer allocator.free(login_info.salt);
    defer allocator.free(login_info.hash);

    const account_result = try api.client.send(i64, command);
    log.debug("account result: {d}", .{account_result});

    const login_arr_list = try json.toString(login_info, allocator);
    const login_json = login_arr_list.items;
    log.debug("login info json: '{s}'", .{login_json});
    defer login_arr_list.deinit();

    const login_info_result = try api.client.send(i64, .{ "HSET", "logins", email_upper, login_json });
    log.debug("login info result: {d}", .{login_info_result});

    try response_helper.writeSuccess(response);
}

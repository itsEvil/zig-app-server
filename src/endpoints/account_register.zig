const std = @import("std");
const validators = @import("../utils/validators.zig");
const redis = @import("../redis/client.zig");
const http = std.http;
const handler = @import("handler.zig");
const response_helper = @import("../utils/response_helper.zig");

const UUID = @import("../utils/uuid.zig").UUID;
const logger = @import("../log.zig");
const log = logger.get(.acc_register);

const Base64Encoder = std.base64.standard.Encoder;

const api = @import("../api.zig");

const rand = std.crypto.random;
const sha512 = std.crypto.hash.sha3.Sha3_512;

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

    //const email_set_result = try api.client.send(i64, .{ "HSET", "logins", email_upper, "{}" });
    //log.debug("Did we set email: {d}", .{email_set_result});

    const name_set_result = try api.client.send(i64, .{ "HSET", "names", username_upper, email_upper });
    log.debug("Did we set username: {d}", .{name_set_result});

    const next_acc_id = try api.client.send(i64, .{ "INCR", "nextAccId" });
    log.debug("Next account Id: {d}", .{next_acc_id});

    const account_field = try std.fmt.allocPrint(allocator, "account.{d}", .{next_acc_id});

    const newAccount = AccountStruct{
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

    const salt_buf: []u8 = try allocator.alloc(u8, 20);
    defer allocator.free(salt_buf);
    std.crypto.random.bytes(salt_buf);
    const base64_len = GetLength(salt_buf.len);
    const base64_buf: []u8 = try allocator.alloc(u8, base64_len);
    defer allocator.free(base64_buf);

    const salt = Base64Encode(salt_buf, base64_buf);
    const salted_pass = try std.fmt.allocPrint(allocator, "{s}{s}", .{ credentials.password, salt });

    var hash_buf: [sha512.digest_length]u8 = undefined;
    sha512.hash(salted_pass, &hash_buf, .{});
    const hash_base64_len = GetLength(hash_buf.len);
    const hash_base64_buf: []u8 = try allocator.alloc(u8, hash_base64_len);
    const hash = Base64Encode(&hash_buf, hash_base64_buf);
    defer allocator.free(hash_base64_buf);

    log.info("salt:{s} salted:{s}, hash:{s}", .{ salt, salted_pass, hash });

    const login_info = LoginInfo{ .salt = salt, .hash = @constCast(hash), .accountId = next_acc_id };
    const account_result = try api.client.send(i64, command);
    log.debug("account result: {d}", .{account_result});

    var string = std.ArrayList(u8).init(allocator);
    try std.json.stringify(login_info, .{}, string.writer());
    log.debug("json item: '{s}'", .{string.items});
    const login_info_result = try api.client.send(i64, .{ "HSET", "logins", email_upper, string.items });
    log.debug("login info result: {d}", .{login_info_result});

    try response_helper.writeSuccess(response);
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

const LoginInfo = struct {
    salt: []const u8,
    hash: []u8,
    accountId: i64,
};

fn GetLength(length: usize) usize {
    return Base64Encoder.calcSize(length);
}

fn Base64Encode(buf: []const u8, out_buf: []u8) []const u8 {
    return Base64Encoder.encode(out_buf, buf);
}

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

    const email_upper = std.ascii.upperString(try allocator.alloc(u8, credentials.email.len), credentials.email);
    defer allocator.free(email_upper);

    const username_upper = std.ascii.upperString(try allocator.alloc(u8, credentials.username.len), credentials.username);
    defer allocator.free(username_upper);

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

    const email_set_result = try api.client.send(i64, .{ "HSET", "logins", email_upper, "{}" });
    log.debug("Did we set email: {d}", .{email_set_result});

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

    const salt = try GenerateSalt(allocator);
    const salted_pass = try std.fmt.allocPrint(allocator, "{s}{s}", .{ credentials.password, salt });

    var hash_buf: [sha512.digest_length]u8 = undefined;
    sha512.hash(salted_pass, &hash_buf, .{});
    log.info("salt:{s} hash:{s}", .{ salt, hash_buf });

    //const login_info = LoginInfo{ .salt = salt, .hash = &hash_buf, .accountId = next_acc_id };
    const account_result = try api.client.send(i64, command);
    log.debug("account result: {d}", .{account_result});

    //var buf: [100]u8 = undefined;
    //var fba = std.heap.FixedBufferAllocator.init(&buf);
    //var string = std.ArrayList(u8).init(fba.allocator());
    //try std.json.stringify(login_info, .{}, string.writer());
    //log.debug("json items: '{s}'", .{string.items});
    //const login_info_result = try api.client.send(i64, .{ "HSET", "logins", email_upper, string.items });
    //log.debug("login info result: {d}", .{login_info_result});

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

fn GenerateSalt(allocator: std.mem.Allocator) ![]const u8 {
    const buf: []const u8 = try allocator.alloc(u8, 20);
    defer allocator.free(buf);
    const encoded_length = Base64Encoder.calcSize(buf.len);
    const encoded_buf = try allocator.alloc(u8, encoded_length);
    _ = Base64Encoder.encode(encoded_buf, buf);
    return encoded_buf;
}

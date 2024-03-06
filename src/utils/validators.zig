const std = @import("std");
const net = std.net;
const Response = std.http.Server.Response;
const endpoint = @import("../endpoints/handler.zig");
const logger = @import("../log.zig");
const log = logger.get(.validators);
const Base64Encoder = std.base64.standard.Encoder;
const rand = std.crypto.random;
const sha512 = std.crypto.hash.sha3.Sha3_512;

const Alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
pub const APIError = error{
    FormTooLarge,
    InvalidCredentials,
    InvalidEmail,
    InvalidUsername,
    InvalidPassword,
    FailedLock,
    MissingData,
    EmailTaken,
    NameTaken,
    InvalidEndpoint,
};

pub fn checkSize(response: *Response, expected_size: u8) !void {
    var details = std.mem.splitSequence(u8, response.request.target, "=");
    var details_counter: u8 = 0;
    while (details.next()) |data| {
        details_counter += 1;
        log.info("data:{s}", .{data});

        //Throw error if too many details
        if (details_counter >= expected_size)
            return APIError.FormTooLarge;
    }
}

//god the body can be utf8 which makes this annoying
///Returns true if '@' symbol is before a '.' and theres at least 1 character between them
pub fn isValidEmail(email: []const u8) !bool {
    log.info("email-len:{any}", .{email.len});
    if (email.len < 5 or email.len > 64)
        return false;

    const atsAscii = std.mem.count(u8, email, "@");
    if (atsAscii == 0) {
        const atsUnicode = std.mem.count(u8, email, "%401");
        if (atsUnicode == 0 or atsUnicode > 1)
            return false;
    }

    if (atsAscii > 1)
        return false;

    const dots = std.mem.count(u8, email, ".");
    if (dots == 0)
        return false;

    if (std.mem.indexOf(u8, email, "@")) |at_index| {
        if (std.mem.indexOf(u8, email, ".")) |dot_index| {
            if (at_index + 1 < dot_index)
                return true;
        }
    } else if (std.mem.indexOf(u8, email, "%401")) |at_index| {
        if (std.mem.indexOf(u8, email, ".")) |dot_index| {
            if (at_index + 4 < dot_index)
                return true;
        }
    }

    return false;
}

///Returns true if the length is greater then 8
pub fn isValidPassword(password: []const u8) bool {
    log.info("password-len:{any}", .{password.len});
    if (password.len > 8 or password.len < 32)
        return true;

    return false;
}

///Returns true if the length is greater then 3 and is only characters made up from the ASCII Alphabet
pub fn isValidUsername(username: []const u8) bool {
    log.info("username-len:{any}", .{username.len});
    if (username.len < 3 or username.len > 12)
        return false;

    var counter: usize = 0;
    for (0..username.len) |i| {
        const ch_arr = username[i..i];
        if (std.mem.indexOf(u8, Alphabet, ch_arr)) |_|
            counter += 1;
    }

    log.info("Counter:{any} Length:{any}", .{ counter, username.len });
    if (counter != username.len)
        return false;

    return true;
}

fn GetLength(length: usize) usize {
    return Base64Encoder.calcSize(length);
}

fn Base64Encode(buf: []const u8, out_buf: []u8) []const u8 {
    return Base64Encoder.encode(out_buf, buf);
}

///Free LoginInfo.Salt and LoginInfo.Hash afterwards
pub fn generateLoginInfo(creds: endpoint.Credentials, allocator: std.mem.Allocator, acc_id: i64) !endpoint.LoginInfo {
    const salt_buf: []u8 = try allocator.alloc(u8, 20);
    defer allocator.free(salt_buf);
    std.crypto.random.bytes(salt_buf);
    const base64_len = GetLength(salt_buf.len);
    const base64_buf: []u8 = try allocator.alloc(u8, base64_len);
    //defer allocator.free(base64_buf);

    const salt = Base64Encode(salt_buf, base64_buf);
    const salted_pass = try combineStrings(creds.password, salt, allocator);
    const hash = try generateHash(salted_pass, allocator);

    log.info("salt:{s} salted:{s}, hash:{s}", .{ salt, salted_pass, hash });

    return endpoint.LoginInfo{ .salt = salt, .hash = hash, .accountId = acc_id };
}

pub fn combineStrings(left: []const u8, right: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ left, right });
}

pub fn getAccountField(accId: i64, allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "account.{d}", .{accId});
}

///Free arr afterwards
pub fn generateHash(salt: []u8, allocator: std.mem.Allocator) ![]const u8 {
    var hash_buf: [sha512.digest_length]u8 = undefined;
    sha512.hash(salt, &hash_buf, .{});
    const hash_base64_len = GetLength(hash_buf.len);
    const hash_base64_buf: []u8 = try allocator.alloc(u8, hash_base64_len);
    return Base64Encode(&hash_buf, hash_base64_buf);
}

const std = @import("std");
const net = std.net;
const Response = std.http.Server.Response;

const logger = @import("../log.zig");
const log = logger.get(.validators);

const Alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
pub const APIError = error{
    FormTooLarge,
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

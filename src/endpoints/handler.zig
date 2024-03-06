const std = @import("std");
const redis = @import("../redis/client.zig");
const acc_register = @import("account_register.zig");
const acc_verify = @import("account_verify.zig");
const char_list = @import("char_list.zig");
const response_helper = @import("../utils/response_helper.zig");
const validators = @import("../utils/validators.zig");
const http = std.http;

const logger = @import("../log.zig");
const log = logger.get(.endpoint_handler);

pub fn parseEndpoint(response: *http.Server.Response, allocator: std.mem.Allocator, body: []const u8) !void {
    response.transfer_encoding = .chunked;
    try response.headers.append("content-type", "text/xml");

    if (std.mem.startsWith(u8, response.request.target, "/account/verify")) {
        const creds = try parseLogin(body);
        try validateLogin(response, creds, allocator, false);
        try acc_verify.handle(response, allocator, creds);
        return;
    } else if (std.mem.startsWith(u8, response.request.target, "/char/list")) {
        const creds = try parseLogin(body);
        try validateLogin(response, creds, allocator, false);
        try char_list.handle(response, allocator, creds);
        return;
    } else if (std.mem.startsWith(u8, response.request.target, "/account/register")) {
        // Write the response body.
        try response.do();

        if (response.request.method != .POST) {
            try response_helper.writeError(response, "Bad request method", allocator);
            return;
        }

        const creds = try parseLogin(body);
        try validateLogin(response, creds, allocator, true);
        try acc_register.handle(response, allocator, creds);
        return;
    }

    return validators.APIError.InvalidEndpoint;
}

///Checks credentials and tries to make sure they are valid
pub fn validateLogin(response: *http.Server.Response, creds: Credentials, allocator: std.mem.Allocator, check_username: bool) !void {
    //validate basic user inputs
    if (creds.email.len == 0 or creds.password.len == 0) {
        try response_helper.writeError(response, "Missing data", allocator);
        return validators.APIError.MissingData;
    }

    if (!try validators.isValidEmail(creds.email)) {
        try response_helper.writeError(response, "Invalid Email", allocator);
        return validators.APIError.InvalidEmail;
    }

    if (!validators.isValidPassword(creds.password)) {
        try response_helper.writeError(response, "Invalid Password", allocator);
        return validators.APIError.InvalidPassword;
    }

    if (check_username) {
        if (creds.username.len == 0) {
            try response_helper.writeError(response, "Missing data", allocator);
            return validators.APIError.MissingData;
        }

        if (!validators.isValidUsername(creds.username)) {
            try response_helper.writeError(response, "Invalid Username", allocator);
            return validators.APIError.InvalidUsername;
        }
    }
}

pub fn parseLogin(body: []const u8) !Credentials {
    log.debug("body: '{s}", .{body});
    const email_index = std.mem.indexOf(u8, body, "email=");
    var email: []const u8 = "";
    var password: []const u8 = "";
    var username: []const u8 = "";
    if (email_index) |index| {
        const email_end_index = std.mem.indexOf(u8, body, "&");
        if (email_end_index) |end_index| {
            email = body[index + 6 .. end_index];
            log.debug("email: '{s}'", .{email});
        }
    }

    const pass_index = std.mem.indexOf(u8, body, "password=");
    if (pass_index) |index| {
        const pass_end_index = std.mem.indexOf(u8, body, "&username="); //register endpoint
        if (pass_end_index) |end_index| {
            password = body[index + 9 .. end_index];
        } else { //other endpoints
            password = body[index + 9 ..];
        }

        log.debug("password: '{s}'", .{password});
    }

    const username_index = std.mem.indexOf(u8, body, "username=");
    if (username_index) |index| { //register endpoint
        username = body[index + 9 ..];
        log.debug("username: '{s}'", .{username});
    }

    return .{ .email = email, .password = password, .username = username };
}

pub const Credentials = struct {
    email: []const u8,
    password: []const u8,
    username: []const u8 = "",
};

pub const LoginInfo = struct {
    salt: []const u8,
    hash: []const u8,
    accountId: i64 = -1,
};

//Default values for new accounts
pub const AccountStruct = struct {
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

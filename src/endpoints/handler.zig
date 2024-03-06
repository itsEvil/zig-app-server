const std = @import("std");
const redis = @import("../redis/client.zig");
const acc_register = @import("account_register.zig");
const acc_verify = @import("account_verify.zig");
const char_list = @import("char_list.zig");
const response_helper = @import("../utils/response_helper.zig");
const validators = @import("../utils/validators.zig");
const http = std.http;
const xml = @import("../utils/xml.zig");

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
            const buf = try response_helper.writeError(response, "Bad request method", allocator);
            defer allocator.free(buf);
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
        const buf = try response_helper.writeError(response, "Missing data", allocator);
        defer allocator.free(buf);
        return validators.APIError.MissingData;
    }

    if (!try validators.isValidEmail(creds.email)) {
        const buf = try response_helper.writeError(response, "Invalid Email", allocator);
        defer allocator.free(buf);
        return validators.APIError.InvalidEmail;
    }

    if (!validators.isValidPassword(creds.password)) {
        const buf = try response_helper.writeError(response, "Invalid Password", allocator);
        defer allocator.free(buf);
        return validators.APIError.InvalidPassword;
    }

    if (check_username) {
        if (creds.username.len == 0) {
            const buf = try response_helper.writeError(response, "Missing data", allocator);
            defer allocator.free(buf);
            return validators.APIError.MissingData;
        }

        if (!validators.isValidUsername(creds.username)) {
            const buf = try response_helper.writeError(response, "Invalid Username", allocator);
            defer allocator.free(buf);
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
    rank: i64 = 0,
    guildId: i64 = 0,
    guildRank: i64 = 0,
    vaultCount: i64 = 2,
    maxCharSlots: i64 = 2,
    regTime: i64 = 0,
    fame: i64 = 0,
    totalFame: i64 = 0,
    credits: i64 = 0,
    totalCredits: i64 = 0,
    passResetToken: []const u8 = "",

    pub fn toXml(self: AccountStruct, acc_id: i64, allocator: std.mem.Allocator) ![]u8 {
        const id_data = try xml.addXml("AccountId", "{d}", acc_id, allocator);
        const name_data = try xml.addXml("Name", "{s}", self.name, allocator);

        defer allocator.free(id_data);
        defer allocator.free(name_data);
        return try std.fmt.allocPrint(allocator, "<Account>{s}{s}</Account>", .{ id_data, name_data }); //closing
    }

    pub fn parse(data: [][]const u8) !AccountStruct {
        var email: []const u8 = "";
        var name: []const u8 = "";
        var rank: i64 = 0;
        var guildId: i64 = 0;
        var vaultcount: i64 = 0;
        var maxCharSlot: i64 = 0;
        var regTime: i64 = 0;
        var fame: i64 = 0;
        var totalFame: i64 = 0;
        var credits: i64 = 0;
        var totalCredits: i64 = 0;
        const eql = std.mem.eql;
        const int = std.fmt.parseInt;
        for (0.., data) |i, word| {
            if (eql(u8, "email", word)) {
                email = data[i + 1];
            } else if (eql(u8, "name", word)) {
                name = data[i + 1];
            } else if (eql(u8, "rank", word)) {
                rank = try int(i64, data[i + 1], 10);
            } else if (eql(u8, "guildId", word)) {
                guildId = try int(i64, data[i + 1], 10);
            } else if (eql(u8, "vaultCount", word)) {
                vaultcount = try int(i64, data[i + 1], 10);
            } else if (eql(u8, "maxCharSlot", word)) {
                maxCharSlot = try int(i64, data[i + 1], 10);
            } else if (eql(u8, "regTime", word)) {
                regTime = try int(i64, data[i + 1], 10);
            } else if (eql(u8, "fame", word)) {
                fame = try int(i64, data[i + 1], 10);
            } else if (eql(u8, "totalFame", word)) {
                totalFame = try int(i64, data[i + 1], 10);
            } else if (eql(u8, "credits", word)) {
                credits = try int(i64, data[i + 1], 10);
            } else if (eql(u8, "totalCredits", word)) {
                totalCredits = try int(i64, data[i + 1], 10);
            }
        }

        return AccountStruct{ .email = email, .name = name, .rank = rank, .guildId = guildId, .vaultCount = vaultcount, .maxCharSlots = maxCharSlot, .regTime = regTime, .fame = fame, .totalFame = fame, .credits = totalCredits };
    }
};

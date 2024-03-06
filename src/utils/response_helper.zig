const std = @import("std");
const http = std.http;

pub fn writeString(response: *http.Server.Response, msg: []const u8) !void {
    if (response.state == .waited)
        try response.do();

    if (response.state != .responded)
        return;

    try response.writeAll(msg);
}

pub fn writeNewLine(response: *http.Server.Response) !void {
    if (response.state == .waited)
        try response.do();

    if (response.state != .responded)
        return;

    try response.writeAll("\n");
}

pub fn writeError(response: *http.Server.Response, msg: []const u8, allocator: std.mem.Allocator) !void {
    if (response.state == .waited)
        try response.do();

    if (response.state != .responded)
        return;

    try response.writeAll(try std.fmt.allocPrint(allocator, "<Error>{s}</Error>", .{msg}));
}

pub fn writeSuccess(response: *http.Server.Response) !void {
    if (response.state == .waited)
        try response.do();

    if (response.state != .responded)
        return;

    try response.writeAll("<Success/>");
}

pub fn writeXML(response: *http.Server.Response, xml: []const u8) !void {
    if (response.state == .waited)
        try response.do();

    if (response.state != .responded)
        return;

    try response.writeAll(xml);
}

const xml = @import("mod.zig");
const std = @import("std");
const expect = std.testing.expect;

test "xml" {
    const input =
        \\<?xml version="1.0" standalone="yes" ?>
        \\<category name="Technology">
        \\  <book title="Learning Amazon Web Services" author="Mark Wilkins">
        \\    <price>$20</price>
        \\  </book>
        \\  <book title="The Hunger Games" author="Suzanne Collins">
        \\    <price>$13</price>
        \\  </book>
        \\  <book title="The Lightning Thief: Percy Jackson and the Olympians" author="Rick Riordan"></book>
        \\</category>
    ;
    var fbs = std.io.fixedBufferStream(input);
    var doc = try xml.parse(std.testing.allocator, "<stdin>", fbs.reader());
    defer doc.deinit();

    try expectEqualStrings(doc.str(doc.root.tag_name), "category");

    const children = doc.elem_children(doc.root);
    try expect(children.len == 3);
    try expect(doc.node(children[0]) == .element);
    try expect(doc.node(children[1]) == .element);
    try expect(doc.node(children[2]) == .element);

    const child1 = doc.node(children[1]).element;
    try expectEqualStrings(doc.str(child1.tag_name), "book");
    try expectEqualStrings(doc.elem_attr(child1, "title").?, "The Hunger Games");

    const children2 = doc.elem_children(child1);
    try expect(children2.len == 1);
    try expect(doc.node(children2[0]) == .element);

    const child2 = doc.node(children2[0]).element;
    try expectEqualStrings(doc.str(child2.tag_name), "price");
    const children3 = doc.elem_children(child2);
    try expect(children3.len == 1);
    try expect(doc.node(children3[0]) == .text);
    try expectEqualStrings(doc.str(doc.node(children3[0]).text), "$13");
}

fn expectEqualStrings(actual: []const u8, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, actual);
}

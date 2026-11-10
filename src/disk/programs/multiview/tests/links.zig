// SPDX-License-Identifier: MIT
//! Host tests of where MultiView's links lead: on the web, on a disk,
//! and on the page itself. utility.library is the ROM's, made on the
//! ROM's exec, for undoing a link's escapes.

const std = @import("std");
const host = @import("host_rom");
const sdk = @import("sdk");
const links = @import("../links.zig");
const UtilityBase = sdk.interface.utility.UtilityBase;

const testing = std.testing;

/// Where `link` on the page at `from` leads: the page's name, or `#` and
/// the place's for a place on the page itself, or "nowhere".
fn leads(ub: *UtilityBase, from: []const u8, link: []const u8, into: *[2048]u8) ![]const u8 {
    var base = links.Location{};
    try testing.expect(base.take(from));
    var target = links.Location{};
    switch (links.resolve(ub, &base, link, &target)) {
        .here => |place| return std.fmt.bufPrint(into, "#{s}", .{place}),
        .page => |place| {
            if (place.len == 0) return std.fmt.bufPrint(into, "{s}", .{target.slice()});
            return std.fmt.bufPrint(into, "{s} #{s}", .{ target.slice(), place });
        },
        .nowhere => return "nowhere",
    }
}

test "links on a page from the web" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var into: [2048]u8 = undefined;
    const base = "https://en.wikipedia.org/wiki/HTML?x=1#top";
    const cases = [_][2][]const u8{
        .{ "/wiki/XML", "https://en.wikipedia.org/wiki/XML" },
        .{ "Markup#History", "https://en.wikipedia.org/wiki/Markup #History" },
        .{ "../w/index.php?title=HTML&action=edit", "https://en.wikipedia.org/w/index.php?title=HTML&action=edit" },
        .{ "./a/./b/../c", "https://en.wikipedia.org/wiki/a/c" },
        .{ "//de.wikipedia.org/wiki/HTML", "https://de.wikipedia.org/wiki/HTML" },
        .{ "?y=2", "https://en.wikipedia.org/wiki/HTML?y=2" },
        .{ "#cite_note-1", "#cite_note-1" },
        .{ "#", "#" },
        .{ "", "#" },
        .{ " http://example.com ", "http://example.com" },
        .{ "HTTPS://Example.com/a b", "HTTPS://Example.com/a b" },
        .{ "../../../up", "https://en.wikipedia.org/up" },
        .{ "mailto:someone@example.com", "nowhere" },
        .{ "javascript:void(0)", "nowhere" },
    };
    for (cases) |case| try testing.expectEqualStrings(case[1], try leads(ub, base, case[0], &into));
    try testing.expectEqualStrings("http://host/x", try leads(ub, "http://host", "x", &into));
    try testing.expectEqualStrings("http://host/a/", try leads(ub, "http://host/a/b", ".", &into));
    try host.utility.tearDown(rom_ub);
}

test "links on a page from a disk" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var into: [2048]u8 = undefined;
    const base = "SYS:Tests/datatypes/Page.html";
    const cases = [_][2][]const u8{
        .{ "Reading.md", "SYS:Tests/datatypes/Reading.md" },
        .{ "./sub/x.html#part", "SYS:Tests/datatypes/sub/x.html #part" },
        .{ "../Readme", "SYS:Tests/Readme" },
        .{ "../../../top", "SYS:top" },
        .{ "/Docs/a%20b.html?q=1", "SYS:Docs/a b.html" },
        .{ "Gr%C3%BC%C3%9Fe.html", "Gr\xFC\xDFe.html" },
        .{ "RAM:other.html", "RAM:other.html" },
        .{ "https://example.com/", "https://example.com/" },
        .{ "mailto:x@y", "nowhere" },
        .{ "#anchor", "#anchor" },
    };
    for (cases[0..5]) |case| try testing.expectEqualStrings(case[1], try leads(ub, base, case[0], &into));
    try testing.expectEqualStrings("SYS:Tests/datatypes/Gr\xFC\xDFe.html", try leads(ub, base, cases[5][0], &into));
    for (cases[6..]) |case| try testing.expectEqualStrings(case[1], try leads(ub, base, case[0], &into));
    // From a name relative to the current drawer.
    try testing.expectEqualStrings("b.html", try leads(ub, "a.html", "b.html", &into));
    try testing.expectEqualStrings("/b.html", try leads(ub, "a.html", "../b.html", &into));
    try testing.expectEqualStrings("//b.html", try leads(ub, "/a.html", "../b.html", &into));
    try testing.expectEqualStrings(":b.html", try leads(ub, "a.html", "/b.html", &into));
    try host.utility.tearDown(rom_ub);
}

test "what a page on the web would be called as a file" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var into: [64]u8 = undefined;
    const cases = [_][2][]const u8{
        .{ "https://github.com/a/b/blob/main/README.md", "README.md" },
        .{ "https://host/raw/Notes.markdown?plain=1#top", "Notes.markdown" },
        .{ "https://en.wikipedia.org/wiki/HTML", "HTML" },
        .{ "http://host/Gr%C3%BC%C3%9Fe.md", "Gr\xFC\xDFe.md" },
        .{ "http://host/drawer/", "" },
        .{ "http://host", "" },
        .{ "http://host?q=/x.md", "" },
        .{ "http://host/%ZZ.md", "" },
    };
    for (cases) |case| try testing.expectEqualStrings(case[1], links.fileOf(ub, case[0], &into));
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("", links.fileOf(ub, "http://host/long.md", &small));
    try host.utility.tearDown(rom_ub);
}

test "a location knows the web from a disk" {
    var where = links.Location{};
    try testing.expect(where.take("https://example.com/x"));
    try testing.expect(where.web);
    try testing.expect(where.take("SYS:x"));
    try testing.expect(!where.web);
    try testing.expect(!links.isWeb("http:x"));
    try testing.expect(!where.take("x" ** (links.location_most + 1)));
}

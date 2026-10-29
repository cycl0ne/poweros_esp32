// SPDX-License-Identifier: MIT
//! Host tests of m3u.zig: M3U with and without `#EXTINF`, its attributes
//! and its mark of UTF-8, PLS in any order, a location found from the
//! list's drawer, a path made relative to it, what is written read back
//! the same, and the station a station's list stands for.

const std = @import("std");
const m3u = @import("../m3u.zig");
const icy = @import("sdk").http.icy;

const testing = std.testing;

fn expectItem(item: ?m3u.Item, location: []const u8, title: []const u8, seconds: ?u32) !void {
    const got = item orelse return error.TestExpectedItem;
    try testing.expectEqualStrings(location, got.location);
    try testing.expectEqualStrings(title, got.title);
    try testing.expectEqual(seconds, got.seconds);
}

test "Player's lists: the kind by the ending, in any case" {
    try testing.expectEqual(m3u.Kind.m3u, m3u.kindOf("Party.m3u").?);
    try testing.expectEqual(m3u.Kind.m3u, m3u.kindOf("DH0:Lists/Party.M3U8").?);
    try testing.expectEqual(m3u.Kind.pls, m3u.kindOf("groove.pls").?);
    try testing.expect(m3u.kindOf("song.mp3") == null);
    try testing.expect(m3u.kindOf("m3u") == null);
}

test "Player's lists: M3U, plain and extended" {
    var plain = m3u.Reader.init("Fire.mp3\r\n\r\n# a comment\r\nMore/Rise.flac\r\n");
    try testing.expectEqual(m3u.Kind.m3u, plain.form);
    try expectItem(plain.next(), "Fire.mp3", "", null);
    try expectItem(plain.next(), "More/Rise.flac", "", null);
    try testing.expect(plain.next() == null);

    var extended = m3u.Reader.init(
        \\#EXTM3U
        \\#EXTINF:238,Daft Punk - Around the World
        \\Music/World.mp3
        \\#EXTINF:-1 tvg-logo="http://radio.example/logo.png" group-title="A, B",Groove Salad
        \\http://ice1.example/groovesalad-128-mp3
        \\#EXTINF:12.75,
        \\Short.wav
        \\Plain.ogg
    );
    try expectItem(extended.next(), "Music/World.mp3", "Daft Punk - Around the World", 238);
    const station = extended.next().?;
    try expectItem(station, "http://ice1.example/groovesalad-128-mp3", "Groove Salad", null);
    try testing.expectEqualStrings("http://radio.example/logo.png", station.logo);
    try expectItem(extended.next(), "Short.wav", "", 12);
    // An #EXTINF says nothing of the song after the one it is before.
    try expectItem(extended.next(), "Plain.ogg", "", null);
    try testing.expect(extended.next() == null);
}

test "Player's lists: UTF-8 found for the whole file, its mark passed over" {
    var marked = m3u.Reader.init("\xEF\xBB\xBF#EXTINF:1,Caf\xC3\xA9\nCaf\xC3\xA9.mp3\n");
    try testing.expect(marked.utf8);
    const item = marked.next().?;
    try testing.expectEqualStrings("Caf\xC3\xA9.mp3", item.location);
    var title: [16]u8 = undefined;
    icy.latin1As(item.title, marked.utf8, &title);
    try testing.expectEqualStrings("Caf\xE9", std.mem.sliceTo(&title, 0));

    // A byte past ASCII that is no UTF-8 makes the file Latin-1.
    var old = m3u.Reader.init("#EXTINF:1,Caf\xE9\nx.mp3\n");
    try testing.expect(!old.utf8);
    icy.latin1As(old.next().?.title, old.utf8, &title);
    try testing.expectEqualStrings("Caf\xE9", std.mem.sliceTo(&title, 0));
}

test "Player's lists: PLS, its keys in any order and case" {
    var pls = m3u.Reader.init(
        \\
        \\[playlist]
        \\NumberOfEntries=2
        \\Title2=Second
        \\File1=http://radio.example:8000/live
        \\title1=First station
        \\Length1=-1
        \\FILE2=Songs\Two.mp3
        \\Length2=181
        \\Version=2
    );
    try testing.expectEqual(m3u.Kind.pls, pls.form);
    try expectItem(pls.next(), "http://radio.example:8000/live", "First station", null);
    try expectItem(pls.next(), "Songs\\Two.mp3", "Second", 181);
    try testing.expect(pls.next() == null);
}

test "Player's lists: a location from the list's drawer" {
    var room: [64]u8 = undefined;
    const cases = [_]struct { drawer: []const u8, location: []const u8, wanted: []const u8 }{
        .{ .drawer = "DH0:Music", .location = "Fire.mp3", .wanted = "DH0:Music/Fire.mp3" },
        .{ .drawer = "DH0:", .location = "Fire.mp3", .wanted = "DH0:Fire.mp3" },
        .{ .drawer = "DH0:Music/Lists", .location = "../Rock/Fire.mp3", .wanted = "DH0:Music/Rock/Fire.mp3" },
        .{ .drawer = "DH0:Music/Lists", .location = "../../Fire.mp3", .wanted = "DH0:Fire.mp3" },
        .{ .drawer = "DH0:Music", .location = "./a/b.mp3", .wanted = "DH0:Music/a/b.mp3" },
        .{ .drawer = "DH0:Music", .location = "..\\Other\\c.mp3", .wanted = "DH0:Other/c.mp3" },
        .{ .drawer = "DH0:Music/Lists", .location = "/Songs/d.mp3", .wanted = "DH0:Songs/d.mp3" },
        .{ .drawer = "DH0:Music", .location = "SD0:e.mp3", .wanted = "SD0:e.mp3" },
        .{ .drawer = "DH0:Music", .location = "http://radio.example/x", .wanted = "http://radio.example/x" },
        .{ .drawer = "", .location = "f.mp3", .wanted = "f.mp3" },
    };
    for (cases) |case| try testing.expectEqualStrings(case.wanted, m3u.locate(case.drawer, case.location, &room).?);
    var small: [8]u8 = undefined;
    try testing.expect(m3u.locate("DH0:Music", "Fire.mp3", &small) == null);
}

test "Player's lists: a path relative to the list's drawer, when it lies within" {
    try testing.expectEqualStrings("Fire.mp3", m3u.relative("DH0:Music", "DH0:Music/Fire.mp3").?);
    try testing.expectEqualStrings("Rock/Fire.mp3", m3u.relative("dh0:music", "DH0:Music/Rock/Fire.mp3").?);
    try testing.expectEqualStrings("Fire.mp3", m3u.relative("DH0:", "DH0:Fire.mp3").?);
    try testing.expectEqualStrings("Fire.mp3", m3u.relative("DH0:Music/", "DH0:Music/Fire.mp3").?);
    try testing.expect(m3u.relative("DH0:Music", "DH0:Musical/Fire.mp3") == null);
    try testing.expect(m3u.relative("DH0:Music", "SD0:Fire.mp3") == null);
    try testing.expect(m3u.relative("DH0:Music", "DH0:Music") == null);
}

test "Player's lists: what is written read back the same" {
    const items = [_]m3u.Item{
        .{ .location = "Fire.mp3", .title = "Arcade Fire - Caf\xE9", .seconds = 241 },
        .{ .location = "http://radio.example/live", .title = "A station", .logo = "http://radio.example/l.png" },
        .{ .location = "Plain.ogg" },
    };
    var text: [512]u8 = undefined;
    @memcpy(text[0..m3u.header.len], m3u.header);
    var length: usize = m3u.header.len;
    for (items) |item| {
        const written = m3u.itemLines(item, text[length..]);
        try testing.expect(written <= m3u.itemLength(item));
        length += written;
    }
    try testing.expectEqualStrings("#EXTM3U\n" ++
        "#EXTINF:241,Arcade Fire - Caf\xC3\xA9\n" ++
        "Fire.mp3\n" ++
        "#EXTINF:-1 tvg-logo=\"http://radio.example/l.png\",A station\n" ++
        "http://radio.example/live\n" ++
        "Plain.ogg\n", text[0..length]);
    var reader = m3u.Reader.init(text[0..length]);
    try testing.expect(reader.utf8);
    for (items) |item| {
        const got = reader.next().?;
        var title: [64]u8 = undefined;
        icy.latin1As(got.title, reader.utf8, &title);
        try testing.expectEqualStrings(item.title, std.mem.sliceTo(&title, 0));
        try testing.expectEqualStrings(item.location, got.location);
        try testing.expectEqualStrings(item.logo, got.logo);
        try testing.expectEqual(item.seconds, got.seconds);
    }
    try testing.expect(reader.next() == null);
}

test "Player's lists: the station a station's list stands for" {
    try testing.expect(m3u.namesList("http://radio.example/listen.pls"));
    try testing.expect(m3u.namesList("http://radio.example/live.M3U?sid=1"));
    try testing.expect(!m3u.namesList("http://radio.example/live.mp3"));
    try testing.expect(!m3u.namesList("http://radio.example/stream?file=a.pls"));
    const pls = "[playlist]\nNumberOfEntries=2\nFile1=http://one.example:8000/\nTitle1=One\nFile2=http://two.example/\n";
    try testing.expectEqualStrings("http://one.example:8000/", m3u.firstAddress(pls).?);
    try testing.expectEqualStrings("https://b.example/live", m3u.firstAddress("#EXTM3U\nlocal.mp3\nhttps://b.example/live\n").?);
    try testing.expect(m3u.firstAddress("#EXTM3U\nlocal.mp3\n") == null);
    const hls = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=128000\nhttp://c.example/chunks.m3u8\n";
    try testing.expect(m3u.isHls(hls));
    try testing.expect(!m3u.isHls(pls));
}

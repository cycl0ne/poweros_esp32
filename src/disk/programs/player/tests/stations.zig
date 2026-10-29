// SPDX-License-Identifier: MIT
//! Host tests of the Radio page's lists (stations.zig), on exec alone: the
//! stations kept read from M3U and written back the same, a search's CSV
//! answers put in by how often each was listened to - their tabs and
//! spaces at the ends tidied away - a station found by its address, and
//! nothing left behind.

const std = @import("std");
const kexec = @import("host_rom").exec;
const stations = @import("../stations.zig");

const testing = std.testing;

fn cell(station: *stations.Station, column: usize) []const u8 {
    return std.mem.span(station.cells[column] orelse return "");
}

test "Player's stations: kept ones read from M3U and written back" {
    try kexec.setUp();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    var kept: stations.Stations = undefined;
    kept.init();
    kept.readKept(sys, "#EXTM3U\n# a comment\n" ++
        "#EXTINF:-1 tvg-logo=\"http://a.example/a.png\",Station A\n" ++
        "http://a.example/live\n" ++
        "DH0:Music/song.mp3\n" ++
        "http://b.example/stream/\n");
    // A file's name is no station; one without a name is called by its
    // address's end.
    try testing.expectEqual(@as(usize, 2), kept.count);
    const a = kept.first().?;
    try testing.expectEqualStrings("Station A", cell(a, 0));
    try testing.expectEqualStrings("http://a.example/live", cell(a, 1));
    try testing.expectEqualStrings("http://a.example/a.png", std.mem.span(a.logo().?));
    const b = a.next().?;
    try testing.expectEqualStrings("stream", cell(b, 0));
    try testing.expect(b.logo() == null);
    try testing.expectEqual(b, kept.find("http://b.example/stream/").?);
    try testing.expect(kept.find("http://c.example/") == null);

    const text = kept.keptText(sys).?;
    try testing.expectEqualStrings(stations.kept_header ++
        "#EXTINF:-1 tvg-logo=\"http://a.example/a.png\",Station A\n" ++
        "http://a.example/live\n" ++
        "#EXTINF:-1,stream\n" ++
        "http://b.example/stream/\n", text);
    sys.FreeVec(text.ptr);
    kept.remove(sys, a);
    try testing.expectEqual(@as(usize, 1), kept.count);
    kept.clear(sys);
    try kexec.expectNoLeaks();
}

test "Player's stations: two answers found, the most heard first" {
    try kexec.setUp();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    var found: stations.Stations = undefined;
    found.init();
    const mp3 = "changeuuid,stationuuid,name,url,url_resolved,favicon,tags,country,bitrate,codec,clickcount\n" ++
        "c1,u-1,Jazz One,http://x/1.pls,http://one.example/live,http://one.example/f.png,\"jazz,smooth jazz\",Germany,128,MP3,40\n" ++
        "c2,u-2,Caf\xC3\xA9 Radio,http://two.example/,http://two.example/,,lounge,France,192,MP3,10\n" ++
        "c3,u-3,No address,,,,,,0,MP3,99\n";
    const ogg = "stationuuid,name,url_resolved,clickcount,bitrate,country,tags\n" ++
        "u-4, \tOgg\tStation\t,http://four.example/ogg,25,96, Austria,jazz\n";
    var first_answer: [mp3.len]u8 = mp3.*;
    var second_answer: [ogg.len]u8 = ogg.*;
    try testing.expectEqual(@as(usize, 2), found.readFound(sys, &first_answer));
    try testing.expectEqual(@as(usize, 1), found.readFound(sys, &second_answer));
    const one = found.first().?;
    try testing.expectEqualStrings("Jazz One", cell(one, 0));
    try testing.expectEqualStrings("Germany", cell(one, 1));
    try testing.expectEqualStrings("128", cell(one, 2));
    try testing.expectEqualStrings("jazz, smooth jazz", cell(one, 3));
    try testing.expectEqualStrings("http://one.example/live", std.mem.span(one.url()));
    try testing.expectEqualStrings("http://one.example/f.png", std.mem.span(one.logo().?));
    try testing.expectEqualStrings("u-1", std.mem.sliceTo(&one.uuid, 0));
    const four = one.next().?;
    try testing.expectEqualStrings("Ogg Station", cell(four, 0));
    try testing.expectEqualStrings("Austria", cell(four, 1));
    const two = four.next().?;
    try testing.expectEqualStrings("Caf\xE9 Radio", cell(two, 0));
    try testing.expect(two.logo() == null);
    try testing.expect(two.next() == null);
    found.clear(sys);
    try kexec.expectNoLeaks();
}

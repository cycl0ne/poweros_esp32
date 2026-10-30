// SPDX-License-Identifier: MIT
//! Host tests of the Player's playlist (playlist.zig), on exec alone:
//! which files are sound, a file's name, names compared in any case; the
//! rows of songs added, filled from what their tags say, numbered again
//! after a move, and taken out with nothing left behind. Reading tags and
//! drawers needs audiocodec.library and dos, and is seen in the Player.

const std = @import("std");
const sdk = @import("sdk");
const ac = sdk.audiocodec;
const kexec = @import("host_rom").exec;
const playlist = @import("../playlist.zig");

const testing = std.testing;

fn expectCells(entry: *playlist.Entry, place: []const u8, title: []const u8, artist: []const u8, time: []const u8) !void {
    const wanted = [_][]const u8{ place, title, artist, time };
    for (wanted, entry.cells) |text, cell| try testing.expectEqualStrings(text, std.mem.span(cell.?));
}

fn setText(into: []u8, text: []const u8) void {
    @memcpy(into[0..text.len], text);
    into[text.len] = 0;
}

test "Player's playlist: the endings of sound, a file's name, a station's address, names in any case" {
    try testing.expect(playlist.isSound("Music/Fire.mp3"));
    try testing.expect(playlist.isSound("DH0:a/B.FLAC"));
    try testing.expect(playlist.isSound("x.oga"));
    try testing.expect(playlist.isSound("Books/Chapter.M4A"));
    try testing.expect(playlist.isSound("radio.aac"));
    try testing.expect(playlist.isSound("Films/Sound.AC3"));
    try testing.expect(playlist.isSound("x.eac3"));
    try testing.expect(!playlist.isSound("cover.jpg"));
    try testing.expect(!playlist.isSound("mp3"));
    try testing.expect(!playlist.isSound("Music.mp3/notes"));
    try testing.expect(!playlist.isSound("song.mp"));
    // The file requester's pattern shows the same files.
    for (playlist.endings) |ending| try testing.expect(std.mem.indexOf(u8, playlist.pattern, ending) != null);

    try testing.expectEqualStrings("Fire.mp3", std.mem.span(playlist.fileName("DH0:Music/Fire.mp3")));
    try testing.expectEqualStrings("Fire.mp3", std.mem.span(playlist.fileName("RAM:Fire.mp3")));
    try testing.expectEqualStrings("Fire.mp3", std.mem.span(playlist.fileName("Fire.mp3")));
    // Nothing after the last part: the whole name.
    try testing.expectEqualStrings("Music:", std.mem.span(playlist.fileName("Music:")));
    try testing.expectEqualStrings("SYS:Music/", std.mem.span(playlist.fileName("SYS:Music/")));

    // A station's address, in any case; a file named like one is not.
    try testing.expect(playlist.isUrl("http://ice1.example/groove-128-mp3"));
    try testing.expect(playlist.isUrl("HTTPS://radio.example:8443/live"));
    try testing.expect(!playlist.isUrl("http:"));
    try testing.expect(!playlist.isUrl("httpx://radio.example"));
    try testing.expect(!playlist.isUrl("DH0:http/song.mp3"));
    try testing.expectEqualStrings("groove-128-mp3", std.mem.span(playlist.fileName("http://ice1.example/groove-128-mp3")));

    try testing.expect(playlist.compareNames("abc", "ABD") < 0);
    try testing.expectEqual(@as(i32, 0), playlist.compareNames("Song", "sONG"));
    try testing.expect(playlist.compareNames("b", "A") > 0);
    try testing.expect(playlist.compareNames("a", "ab") < 0);
}

test "Player's playlist: songs added and numbered, filled from their tags, numbered again after a move, taken out" {
    try kexec.setUp();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    var list: playlist.Playlist = undefined;
    list.init();
    const one = list.add(sys, "DH0:Music/One.mp3").?;
    const two = list.add(sys, "DH0:Music/Two.mp3").?;
    const three = list.add(sys, "Three.ogg").?;
    try testing.expectEqual(@as(usize, 3), list.count);
    try testing.expectEqual(@as(usize, 3), list.unread);
    try testing.expectEqualStrings("DH0:Music/Two.mp3", std.mem.span(two.path()));
    // Before its tags are read, a song is its place and its file's name.
    try expectCells(two, "2", "Two.mp3", "", "");

    // What a stream's info says: the title, the artist and the length,
    // minutes and seconds, hours before them from an hour on.
    var info: ac.AudioStreamInfo = .{ .rate = 44100, .frames = 44100 * 225 };
    setText(&info.title, "Fire");
    setText(&info.artist, "Band");
    list.filled(sys, two, &info);
    try expectCells(two, "2", "Fire", "Band", "3:45");
    try testing.expectEqual(@as(usize, 2), list.unread);
    info = .{ .rate = 48000, .frames = 48000 * 3753 };
    list.filled(sys, one, &info);
    // No title in the tags: the file's name stays. Filled again, it is
    // counted once.
    try expectCells(one, "1", "One.mp3", "", "1:02:33");
    list.filled(sys, one, &info);
    try testing.expectEqual(@as(usize, 1), list.unread);

    // The last moved to the front: every place written again, once.
    sys.Remove(&three.row.node);
    sys.AddHead(&list.rows, &three.row.node);
    try testing.expect(list.renumber(sys));
    try expectCells(three, "1", "Three.ogg", "", "");
    try expectCells(one, "2", "One.mp3", "", "1:02:33");
    try expectCells(two, "3", "Fire", "Band", "3:45");
    try testing.expect(!list.renumber(sys));
    try testing.expectEqual(three, list.at(0).?);
    try testing.expectEqual(two, list.at(2).?);
    try testing.expectEqual(@as(?*playlist.Entry, null), list.at(3));
    try testing.expectEqual(@as(usize, 2), list.placeOf(two));

    // Taken out: the one not read yet with it.
    list.remove(sys, three);
    try testing.expectEqual(@as(usize, 2), list.count);
    try testing.expectEqual(@as(usize, 0), list.unread);
    list.clear(sys);
    try testing.expectEqual(@as(usize, 0), list.count);
    try testing.expectEqual(@as(?*playlist.Entry, null), list.first());
    try kexec.expectNoLeaks();
}

test "Player's playlist: written as M3U, from the drawer it is saved in" {
    try kexec.setUp();
    defer kexec.deinit();
    const sys = kexec.SysBase.iface();
    var list: playlist.Playlist = undefined;
    list.init();
    const fire = list.add(sys, "DH0:Music/Fire.mp3").?;
    _ = list.add(sys, "SD0:Other/Rise.flac").?;
    const station = list.add(sys, "http://radio.example/live").?;
    var info: ac.AudioStreamInfo = .{ .rate = 44100, .frames = 44100 * 225 };
    setText(&info.title, "Fire");
    setText(&info.artist, "Band");
    list.filled(sys, fire, &info);
    station.retitle("A station");
    // A song inside the drawer by its name from there, one outside by its
    // whole name; a row that shows its file's name has no #EXTINF.
    const text = list.listText(sys, "DH0:Music").?;
    try testing.expectEqualStrings("#EXTM3U\n" ++
        "#EXTINF:225,Band - Fire\n" ++
        "Fire.mp3\n" ++
        "SD0:Other/Rise.flac\n" ++
        "#EXTINF:-1,A station\n" ++
        "http://radio.example/live\n", text);
    sys.FreeVec(text.ptr);
    list.clear(sys);
    try kexec.expectNoLeaks();
}

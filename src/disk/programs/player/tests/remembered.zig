// SPDX-License-Identifier: MIT
//! Host tests of what the Player remembers (remembered.zig): Player.prefs'
//! line read, checked and written back, and Player.list's songs read a
//! line at a time and written back. The files themselves are read and
//! written by the Player, and seen there.

const std = @import("std");
const sdk = @import("sdk");
const UtilityBase = sdk.interface.utility.UtilityBase;
const kexec = @import("host_rom").exec;
const utility_library = @import("host_rom").utility;
const remembered = @import("../remembered.zig");

const testing = std.testing;

/// utility.library on the host: the lines are read through its
/// NextSetting.
fn utilityUp() !*UtilityBase {
    return @ptrCast(try utility_library.setUp());
}

fn utilityDown(ub: *UtilityBase) !void {
    try utility_library.tearDown(@ptrCast(@alignCast(ub)));
    try kexec.expectNoLeaks();
}

test "Player.prefs: the line read, what it leaves out kept, written back as it was read" {
    const ub = try utilityUp();
    defer kexec.deinit();

    // Nothing kept yet: the Player's own.
    const fresh = remembered.Settings{};
    try testing.expect(fresh.box == null);
    try testing.expect(fresh.remember);
    try testing.expectEqual(@as(u32, 100), fresh.volume);
    try testing.expect(fresh.drawerName() == null);

    const line = "WINDOW=40,30,560,420 PAGE=PLAYLIST LOOK=BARS VOLUME=80 SHUFFLE=YES REPEAT=ONE REMEMBER=NO DRAWER=\"SYS:Music/More\"";
    var settings = remembered.Settings{};
    try testing.expect(remembered.parse(ub, line, &settings) == null);
    try testing.expectEqual(remembered.Box{ .left = 40, .top = 30, .width = 560, .height = 420 }, settings.box.?);
    try testing.expectEqual(@as(u8, 1), settings.page);
    try testing.expectEqual(@as(u8, 2), @intFromEnum(settings.look));
    try testing.expectEqual(@as(u32, 80), settings.volume);
    try testing.expect(settings.shuffle);
    try testing.expectEqual(@as(u8, 2), settings.repeat);
    try testing.expect(!settings.remember);
    try testing.expectEqualStrings("SYS:Music/More", settings.drawerName().?);

    // Written as it was read, word for word.
    var written: [remembered.line_max]u8 = undefined;
    const n = remembered.write(&settings, &written);
    try testing.expectEqualStrings(line, written[0..n]);

    // A word left out keeps what was there; words in any case.
    try testing.expect(remembered.parse(ub, "volume=150 look=wave", &settings) == null);
    try testing.expectEqual(@as(u32, 150), settings.volume);
    try testing.expectEqual(@as(u8, 1), @intFromEnum(settings.look));
    try testing.expectEqual(@as(u8, 1), settings.page);
    try testing.expect(remembered.parse(ub, "page=radio", &settings) == null);
    try testing.expectEqual(@as(u8, 2), settings.page);

    // Without a box or a drawer, neither is written.
    var plain = remembered.Settings{};
    const m = remembered.write(&plain, &written);
    try testing.expectEqualStrings("PAGE=PLAYING LOOK=PLASMA VOLUME=100 SHUFFLE=NO REPEAT=OFF REMEMBER=YES", written[0..m]);
    // A drawer with a quote in it cannot be written, and is left out.
    try testing.expect(plain.setDrawer("Work:\"odd\""));
    const k = remembered.write(&plain, &written);
    try testing.expect(std.mem.indexOf(u8, written[0..k], "DRAWER") == null);

    try utilityDown(ub);
}

test "Player.prefs: words that do not make sense say so" {
    const ub = try utilityUp();
    defer kexec.deinit();
    var bad = remembered.Settings{};
    try testing.expect(remembered.parse(ub, "WINDOW=40,30,560", &bad) != null);
    try testing.expect(remembered.parse(ub, "WINDOW=40,30,0,420", &bad) != null);
    try testing.expect(remembered.parse(ub, "WINDOW=-4,30,560,420", &bad) != null);
    try testing.expect(remembered.parse(ub, "PAGE=STATIONS", &bad) != null);
    try testing.expect(remembered.parse(ub, "LOOK=SCOPE", &bad) != null);
    try testing.expect(remembered.parse(ub, "VOLUME=201", &bad) != null);
    try testing.expect(remembered.parse(ub, "VOLUME=loud", &bad) != null);
    try testing.expect(remembered.parse(ub, "SHUFFLE=MAYBE", &bad) != null);
    try testing.expect(remembered.parse(ub, "REPEAT=TWICE", &bad) != null);
    try testing.expect(remembered.parse(ub, "REMEMBER=1", &bad) != null);
    try testing.expect(remembered.parse(ub, "SPEED=2", &bad) != null);
    try testing.expectEqualStrings(sdk.prefs.Pairs.quote_not_closed, std.mem.span(remembered.parse(ub, "DRAWER=\"SYS:Music", &bad).?));
    // What was wrong changed nothing it did not name.
    try testing.expect(bad.box == null);
    try testing.expectEqual(@as(u32, 100), bad.volume);
    try utilityDown(ub);
}

test "Player.list: the songs read a line at a time, the one shown with its second, written back" {
    const ub = try utilityUp();
    defer kexec.deinit();

    const songs = [_]remembered.Song{
        .{ .path = "SYS:Music/Fire.mp3" },
        .{ .path = "SYS:Music/More/Demo.mp3", .at = 83 },
        .{ .path = "Work:Songs/A Song.flac" },
    };
    var text: [512]u8 = undefined;
    @memcpy(text[0..remembered.list_header.len], remembered.list_header);
    var n: usize = remembered.list_header.len;
    for (songs) |song| {
        try testing.expect(remembered.songLength(song) <= text.len - n);
        n += remembered.songLine(song, text[n..]).?;
    }
    try testing.expectEqualStrings(
        "SONG=\"SYS:Music/Fire.mp3\"\nSONG=\"SYS:Music/More/Demo.mp3\" AT=83\nSONG=\"Work:Songs/A Song.flac\"\n",
        text[remembered.list_header.len..n],
    );

    // Read back past the explanation, each as it was.
    var read = remembered.Songs.init(ub, text[0..n]);
    for (songs) |want| {
        const got = read.next().?;
        try testing.expectEqualStrings(want.path, got.path);
        try testing.expectEqual(want.at, got.at);
    }
    try testing.expect(read.next() == null);
    try testing.expectEqual(@as(u32, 0), read.bad_line);

    // A name with a quote in it has no line.
    var line: [64]u8 = undefined;
    try testing.expect(remembered.songLine(.{ .path = "Work:\"x\".mp3" }, &line) == null);

    try utilityDown(ub);
}

test "Player.list: a line that is not a song is passed over, and the songs around it read" {
    const ub = try utilityUp();
    defer kexec.deinit();
    const text =
        \\SONG="SYS:Music/One.mp3"
        \\SONG="SYS:Music/Two.mp3" AT=seven
        \\
        \\# a comment
        \\TRACK="SYS:Music/Three.mp3"
        \\SONG="SYS:Music/Four.mp3" AT=12 AT=13
        \\AT=5
        \\SONG="SYS:Music/Five.mp3
        \\
    ;
    var read = remembered.Songs.init(ub, text);
    try testing.expectEqualStrings("SYS:Music/One.mp3", read.next().?.path);
    try testing.expect(read.next() == null);
    try testing.expectEqual(@as(u32, 8), read.bad_line);
    try testing.expectEqualStrings(sdk.prefs.Pairs.quote_not_closed, std.mem.span(read.problem.?));

    // The good line after bad ones still comes through.
    var again = remembered.Songs.init(ub, "TRACK=\"x\"\nSONG=\"SYS:Music/Six.mp3\" AT=4\n");
    const six = again.next().?;
    try testing.expectEqualStrings("SYS:Music/Six.mp3", six.path);
    try testing.expectEqual(@as(?u32, 4), six.at);
    try testing.expectEqual(@as(u32, 1), again.bad_line);
    try utilityDown(ub);
}

// SPDX-License-Identifier: MIT
//! Host tests of icy.zig: the metadata taken out of a station's stream
//! however its pieces fall, the title found and taken apart, the
//! Content-Type read, and UTF-8 brought to Latin-1.

const std = @import("std");
const icy = @import("../icy.zig");

const testing = std.testing;

/// A stream of `blocks` stretches of sound, `every` bytes each, the
/// sound's bytes counting up; after each, the block `text`.
fn stream(comptime every: usize, comptime blocks: usize, text: []const u8, into: []u8) usize {
    const sixteens = (text.len + 15) / 16;
    var at: usize = 0;
    var sound: u8 = 0;
    for (0..blocks) |_| {
        for (0..every) |_| {
            into[at] = sound;
            sound +%= 1;
            at += 1;
        }
        into[at] = @intCast(sixteens);
        at += 1;
        @memset(into[at..][0 .. sixteens * 16], 0);
        @memcpy(into[at..][0..text.len], text);
        at += sixteens * 16;
    }
    return at;
}

test "the metadata taken out, the sound together, cut into pieces anywhere" {
    const text = "StreamTitle='Daft Punk - Around the World';StreamUrl='';";
    var whole: [4 * (100 + 1 + 64)]u8 = undefined;
    const length = stream(100, 4, text, &whole);
    var piece_size: usize = 1;
    while (piece_size <= length) : (piece_size += 7) {
        var copy = whole;
        var strip = icy.Strip.init(100);
        var sound: [400]u8 = undefined;
        var sound_length: usize = 0;
        var blocks: usize = 0;
        var at: usize = 0;
        while (at < length) {
            const end = @min(at + piece_size, length);
            const piece = copy[at..end];
            const count = strip.take(piece);
            @memcpy(sound[sound_length..][0..count], piece[0..count]);
            sound_length += count;
            if (strip.takeBlock()) |block| {
                blocks += 1;
                try testing.expectEqualStrings("Daft Punk - Around the World", icy.streamTitle(block).?);
            }
            at = end;
        }
        try testing.expectEqual(@as(usize, 400), sound_length);
        for (sound[0..sound_length], 0..) |byte, i| try testing.expectEqual(@as(u8, @truncate(i)), byte);
        // A block a piece: each taken as it came; several in one piece:
        // the last.
        try testing.expect(blocks >= 1 and blocks <= 4);
        if (piece_size < 100) try testing.expectEqual(@as(usize, 4), blocks);
    }
}

test "an empty block, a stream with none, and a block not taken before the next" {
    var strip = icy.Strip.init(4);
    var bytes = [_]u8{ 1, 2, 3, 4, 0, 5, 6, 7, 8, 0 };
    try testing.expectEqual(@as(usize, 8), strip.take(&bytes));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, bytes[0..8]);
    try testing.expect(strip.takeBlock() == null);

    var plain = icy.Strip.init(0);
    var sound = [_]u8{ 9, 9, 9 };
    try testing.expectEqual(@as(usize, 3), plain.take(&sound));

    // Two blocks in one piece: the second is the one kept.
    var two = icy.Strip.init(1);
    var both: [1 + 1 + 16 + 1 + 1 + 16]u8 = @splat(0);
    both[1] = 1;
    @memcpy(both[2..][0..6], "first;");
    both[18] = 0xAA;
    both[19] = 1;
    @memcpy(both[20..][0..7], "second;");
    try testing.expectEqual(@as(usize, 2), two.take(&both));
    try testing.expect(std.mem.startsWith(u8, two.takeBlock().?, "second;"));
    try testing.expect(two.takeBlock() == null);
}

test "the title found, taken apart, and a block without one" {
    try testing.expectEqualStrings("Guns N' Roses - Paradise City", icy.streamTitle("StreamTitle='Guns N' Roses - Paradise City';StreamUrl='x';\x00\x00").?);
    try testing.expectEqualStrings("", icy.streamTitle("StreamTitle='';").?);
    try testing.expect(icy.streamTitle("StreamUrl='x';") == null);
    try testing.expect(icy.streamTitle("StreamTitle='cut") == null);

    const named = icy.split("Daft Punk - Around the World - Live");
    try testing.expectEqualStrings("Daft Punk", named.artist);
    try testing.expectEqualStrings("Around the World - Live", named.title);
    const plain = icy.split("Station ID");
    try testing.expectEqualStrings("", plain.artist);
    try testing.expectEqualStrings("Station ID", plain.title);
}

test "what a stream is by its Content-Type" {
    try testing.expectEqual(icy.Kind.mp3, icy.kindOf("audio/mpeg"));
    try testing.expectEqual(icy.Kind.mp3, icy.kindOf("Audio/MPEG; charset=x"));
    try testing.expectEqual(icy.Kind.vorbis, icy.kindOf("application/ogg"));
    try testing.expectEqual(icy.Kind.vorbis, icy.kindOf("audio/ogg"));
    try testing.expectEqual(icy.Kind.aac, icy.kindOf("audio/aacp"));
    try testing.expectEqual(icy.Kind.aac, icy.kindOf("audio/aac"));
    try testing.expectEqual(icy.Kind.unknown, icy.kindOf("text/html"));
    try testing.expectEqual(icy.Kind.unknown, icy.kindOf(""));
}

test "UTF-8 brought to Latin-1, Latin-1 kept, cut to fit" {
    var into: [32]u8 = undefined;
    icy.latin1("Bj\xc3\xb6rk \xe2\x80\x93 J\xc3\xb3ga", &into);
    try testing.expectEqualStrings("Bj\xf6rk ? J\xf3ga", std.mem.sliceTo(&into, 0));
    icy.latin1("Bj\xf6rk", &into);
    try testing.expectEqualStrings("Bj\xf6rk", std.mem.sliceTo(&into, 0));
    icy.latin1("plain", &into);
    try testing.expectEqualStrings("plain", std.mem.sliceTo(&into, 0));
    var small: [4]u8 = undefined;
    icy.latin1("\xc3\xa9t\xc3\xa9s", &small);
    try testing.expectEqualStrings("\xe9t\xe9", std.mem.sliceTo(&small, 0));
}

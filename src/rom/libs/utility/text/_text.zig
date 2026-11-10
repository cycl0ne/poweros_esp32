// SPDX-License-Identifier: MPL-2.0
//! What the text calls share: the plain characters typesetting's stand
//! for. UTF-8 is read with the SDK's `utf8`, which every part of the
//! system decodes with.

const std = @import("std");
const utf8 = @import("sdk").utility.utf8;

/// The plain characters a character of typesetting stands for: "" for a
/// mark of no width; null for one that is none of them.
pub fn plain(char: u32) ?[]const u8 {
    return switch (char) {
        0x2018, 0x2019, 0x201A, 0x201B, 0x2032 => "'",
        0x201C, 0x201D, 0x201E, 0x201F, 0x2033 => "\"",
        0x2010...0x2015, 0x2212 => "-",
        0x2026 => "...",
        0x2000...0x200A, 0x202F, 0x205F => " ",
        0x200B...0x200F, 0xFEFF => "",
        else => null,
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

const Step = utf8.Step;
const decode = utf8.decode;

test "decode: characters of every length, and what is no UTF-8" {
    try testing.expectEqual(Step{ .kind = .char, .char = 'A', .length = 1 }, decode("A"));
    try testing.expectEqual(Step{ .kind = .char, .char = 0xE4, .length = 2 }, decode("\xC3\xA4"));
    try testing.expectEqual(Step{ .kind = .char, .char = 0x20AC, .length = 3 }, decode("\xE2\x82\xAC"));
    try testing.expectEqual(Step{ .kind = .char, .char = 0x1F600, .length = 4 }, decode("\xF0\x9F\x98\x80"));
    try testing.expectEqual(Step{ .kind = .char, .char = 0x10FFFF, .length = 4 }, decode("\xF4\x8F\xBF\xBF"));
    // Cut short: right so far.
    try testing.expectEqual(Step.Kind.short, decode("\xE2\x82").kind);
    try testing.expectEqual(@as(usize, 2), decode("\xE2\x82").length);
    try testing.expectEqual(Step.Kind.short, decode("\xF0").kind);
    // Broken: a stray continuation, an overlong form, a surrogate, past
    // U+10FFFF, a lead whose next byte is no continuation.
    for ([_][]const u8{ "\x80", "\xBF", "\xC0\x80", "\xC1\xBF", "\xE0\x80\x80", "\xED\xA0\x80", "\xF0\x80\x80\x80", "\xF4\x90\x80\x80", "\xF5\x80", "\xFF", "\xC3A", "\xE2\x82A" }) |bytes| {
        const step = decode(bytes);
        try testing.expectEqual(Step.Kind.broken, step.kind);
        try testing.expectEqual(@as(usize, 1), step.length);
    }
}

test "utf8.read: what a byte that is no UTF-8 reads as, both ways" {
    // A character reads as itself either way.
    try testing.expectEqual(utf8.Read{ .char = 0x20AC, .length = 3 }, utf8.readAs("\xE2\x82\xACx", true));
    try testing.expectEqual(utf8.Read{ .char = 0x20AC, .length = 3 }, utf8.readAs("\xE2\x82\xACx", false));
    // Read as Latin-1: each bad byte its own character.
    try testing.expectEqual(utf8.Read{ .char = 0xFC, .length = 1, .broken = true }, utf8.readAs("\xFCll", true));
    try testing.expectEqual(utf8.Read{ .char = 0xE2, .length = 1, .broken = true }, utf8.readAs("\xE2\x82x", true));
    // Read as U+FFFD: a broken sequence is one, and the byte that broke it
    // is read again.
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 2, .broken = true }, utf8.readAs("\xE2\x82x", false));
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 1, .broken = true }, utf8.readAs("\x80\x80", false));
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 3, .broken = true }, utf8.readAs("\xE0\x80\x80", false));
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 1, .broken = true }, utf8.readAs("\xC3\x1B[", false));
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 1, .broken = true }, utf8.readAs("\xFF", false));
    // The end of a string cuts a character short.
    try testing.expectEqual(@as(usize, 1), utf8.readZ("\xC3").length);
    try testing.expectEqual(@as(u32, 0xE4), utf8.readZ("\xC3\xA4").char);
}

test "utf8.encode and utf8.valid" {
    var bytes: [4]u8 = undefined;
    for ([_]u32{ 'A', 0xE4, 0x20AC, 0x1F600, 0x10FFFF }) |char| {
        const length = utf8.encode(char, &bytes);
        try testing.expectEqual(utf8.lengthOf(char), length);
        try testing.expect(utf8.valid(bytes[0..length]));
        try testing.expectEqual(utf8.Read{ .char = char, .length = length }, utf8.read(bytes[0..length]));
    }
    // A surrogate and past U+10FFFF are written as U+FFFD.
    try testing.expectEqualSlices(u8, "\xEF\xBF\xBD", bytes[0..utf8.encode(0xD800, &bytes)]);
    try testing.expectEqualSlices(u8, "\xEF\xBF\xBD", bytes[0..utf8.encode(0x110000, &bytes)]);
    try testing.expect(utf8.valid("Caf\xC3\xA9 \xE6\x97\xA5\xE6\x9C\xAC \xF0\x90\x90\x80"));
    try testing.expect(!utf8.valid("a\x80b"));
    try testing.expect(!utf8.valid("\xE2\x82"));
}

test "utf8.cut: never inside a character, anywhere in what is no UTF-8" {
    const text = "a\xC3\xA4\xE2\x82\xAC\xF0\x9F\x98\x80"; // a ä € and an emoji
    const kept = [_]usize{ 0, 1, 1, 3, 3, 3, 6, 6, 6, 6, 10, 10 };
    for (kept, 0..) |want, limit| try testing.expectEqual(want, utf8.cut(text, limit));
    try testing.expectEqual(@as(usize, 1), utf8.cut("a\xB0b", 1)); // Latin-1 °
    try testing.expectEqual(@as(usize, 1), utf8.cut("\xFC\xA4x", 1)); // ü¤ in Latin-1
    try testing.expectEqual(@as(usize, 1), utf8.cut("a\xE2\x82", 2)); // right so far
    try testing.expectEqual(@as(usize, 1), utf8.cut("\xE2\x82x", 1)); // broken off
    try testing.expectEqual(@as(usize, 0), utf8.cut("", 0));
}

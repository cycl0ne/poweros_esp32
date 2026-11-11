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

test "utf8.textOf: UTF-8 as it is, a byte that is no UTF-8 as its character" {
    var into: [8]u8 = undefined;
    const given = "M\xC3\xBCll";
    try testing.expectEqual(@as([*]const u8, given), utf8.textOf(given, &into).?.ptr);
    try testing.expectEqualStrings("Gr\xC3\xBCn", utf8.textOf("Gr\xFCn", &into).?);
    // A byte that is no UTF-8 among characters that are, each read alone.
    try testing.expectEqualStrings("\xC3\xBC\xC3\xA4", utf8.textOf("\xFC\xC3\xA4", &into).?);
    try testing.expectEqual(@as(?[]const u8, null), utf8.textOf("\xFC\xFC\xFC\xFC\xFC", &into));
}

test "utf8.copyCut, fromLatin1, fromForeign: whole characters as fit" {
    var into: [6]u8 = undefined;
    try testing.expectEqualStrings("Grüß", into[0..utf8.copyCut("Grüße", &into)]);
    try testing.expectEqualStrings("Grü", into[0..utf8.copyCut("Grüße", into[0..5])]);
    try testing.expectEqualStrings("Gr\xC3\xBCn", into[0..utf8.fromLatin1("Gr\xFCn", &into)]);
    try testing.expectEqual(@as(usize, 1), utf8.fromLatin1("a\xFC", into[0..2]));
    try testing.expectEqualStrings("€ab", into[0..utf8.fromForeign("€ab", &into)]);
    try testing.expectEqualStrings("\xC3\xA2\xC2\x82", into[0..utf8.fromForeign("\xE2\x82", &into)]);
}

test "utf8.cp1252, fromCp1252, cp1252Length: Windows' Western code page as UTF-8" {
    try testing.expectEqual(@as(u32, 0x20AC), utf8.cp1252(0x80));
    try testing.expectEqual(@as(u32, 0x201C), utf8.cp1252(0x93));
    try testing.expectEqual(@as(u32, 0x81), utf8.cp1252(0x81));
    try testing.expectEqual(@as(u32, 0xFC), utf8.cp1252(0xFC));
    try testing.expectEqual(@as(u32, 'a'), utf8.cp1252('a'));
    const given = "\x93Gr\xFCn\x94 \x80";
    var into: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 15), utf8.cp1252Length(given));
    try testing.expectEqualStrings("“Grün” €", into[0..utf8.fromCp1252(given, &into)]);
    // Only whole characters: the euro sign's three bytes do not fit.
    try testing.expectEqualStrings("“Grün” ", into[0..utf8.fromCp1252(given, into[0..13])]);
}

test "utf8.readLast: walking back reads what walking forward reads" {
    try testing.expectEqual(utf8.Read{ .char = 0xE4, .length = 2 }, utf8.readLast("a\xC3\xA4"));
    try testing.expectEqual(utf8.Read{ .char = 0x1F600, .length = 4 }, utf8.readLast("x\xF0\x9F\x98\x80"));
    try testing.expectEqual(utf8.Read{ .char = 'x', .length = 1 }, utf8.readLast("\xE2\x82x"));
    // Bytes that are no character end with one that reads alone, as the
    // walk forward reads it.
    try testing.expectEqual(utf8.Read{ .char = 0x82, .length = 1, .broken = true }, utf8.readLast("\xE2\x82"));
    try testing.expectEqual(utf8.Read{ .char = 0xA4, .length = 1, .broken = true }, utf8.readLast("\xC3\xA4\xA4"));
    try testing.expectEqual(utf8.Read{ .char = 0xFC, .length = 1, .broken = true }, utf8.readLast("M\xFC"));
    // Forward and back, the same characters.
    const text = "a\xC3\xA4\xE2\x82x\xFC\xF0\x9F\x98\x80\x80";
    var forward: [16]u32 = undefined;
    var count: usize = 0;
    var at: usize = 0;
    while (at < text.len) : (count += 1) forward[count] = utf8.next(text, &at);
    var end: usize = text.len;
    while (end > 0) {
        const found = utf8.readLast(text[0..end]);
        count -= 1;
        try testing.expectEqual(forward[count], found.char);
        end -= found.length;
    }
    try testing.expectEqual(@as(usize, 0), count);
}

test "unicode.base: the letter a letter with marks is written on" {
    const unicode = @import("sdk").utility.unicode;
    try testing.expectEqual(@as(?u32, 'A'), unicode.base(0x0100)); // Ā
    try testing.expectEqual(@as(?u32, 'h'), unicode.base(0x0127)); // ħ, by its name
    try testing.expectEqual(@as(?u32, 'l'), unicode.base(0x0142)); // ł
    try testing.expectEqual(@as(?u32, 0xC5), unicode.base(0x01FA)); // Ǻ is Å
    try testing.expectEqual(@as(?u32, 'A'), unicode.base(0xC5)); // Å is A
    try testing.expectEqual(@as(?u32, 0x0415), unicode.base(0x0401)); // Ё is Е
    try testing.expectEqual(@as(?u32, 0x0413), unicode.base(0x0490)); // Ґ is Г
    try testing.expectEqual(@as(?u32, 0x03B1), unicode.base(0x1F00)); // ἀ is α
    for ([_]u32{ 'A', 'z', 0xDF, 0x03B1, 0x3042, 0x1F600, 0x10FFFF }) |char| try testing.expectEqual(@as(?u32, null), unicode.base(char));
}

test "unicode.width: the cells a character takes" {
    const unicode = @import("sdk").utility.unicode;
    for ([_]u32{ 'A', ' ', 0xE4, 0xAD, 0x20AC, 0x03A9, 0x0416, 0x2500, 0xFFFD, 0x10FFFF }) |char| try testing.expectEqual(@as(u2, 1), unicode.width(char));
    // Marks, format characters and the Hangul vowels: no cell.
    for ([_]u32{ 0x0300, 0x0301, 0x20DD, 0x200B, 0x200D, 0xFE0F, 0x1160, 0xE0001 }) |char| try testing.expectEqual(@as(u2, 0), unicode.width(char));
    // CJK, kana, Hangul syllables, full-width forms, emoji: two.
    for ([_]u32{ 0x4E00, 0x3042, 0xAC00, 0xFF21, 0x1F600, 0x1F44D, 0x231A, 0x20000, 0x2A6E0 }) |char| try testing.expectEqual(@as(u2, 2), unicode.width(char));
}

test "unicode.class: what a character is" {
    const unicode = @import("sdk").utility.unicode;
    const Expect = struct { char: u32, class: unicode.Class };
    const expected = [_]Expect{
        .{ .char = 0, .class = .control },    .{ .char = '\t', .class = .control },
        .{ .char = 0x7F, .class = .control }, .{ .char = 0x85, .class = .control },
        .{ .char = ' ', .class = .space },    .{ .char = 0xA0, .class = .space },
        .{ .char = 0x3000, .class = .space }, .{ .char = 0x2028, .class = .separator },
        .{ .char = 'A', .class = .upper },    .{ .char = 'z', .class = .lower },
        .{ .char = 0xC4, .class = .upper },   .{ .char = 0xDF, .class = .lower },
        .{ .char = 0xD7, .class = .symbol },  .{ .char = 0xAA, .class = .letter },
        .{ .char = 0x0100, .class = .upper }, .{ .char = 0x0101, .class = .lower }, // Ā ā, by turns
        .{ .char = 0x0136, .class = .upper }, .{ .char = 0x0137, .class = .lower },
        .{ .char = 0x0138, .class = .lower },        .{ .char = 0x0139, .class = .upper }, // ĸ, then Ĺ
        .{ .char = 0x01C5, .class = .title },        .{ .char = 0x03A9, .class = .upper },
        .{ .char = 0x03C9, .class = .lower },        .{ .char = 0x0416, .class = .upper },
        .{ .char = 0x3042, .class = .letter },       .{ .char = 0x4E00, .class = .letter },
        .{ .char = 0x9FFF, .class = .letter },       .{ .char = 0xAC00, .class = .letter },
        .{ .char = 0x20000, .class = .letter },      .{ .char = '7', .class = .digit },
        .{ .char = 0x0663, .class = .digit },        .{ .char = 0xB2, .class = .number },
        .{ .char = 0x216B, .class = .number },       .{ .char = '!', .class = .punctuation },
        .{ .char = 0x201C, .class = .punctuation },  .{ .char = 0x20AC, .class = .symbol },
        .{ .char = 0x1F600, .class = .symbol },      .{ .char = 0x0301, .class = .mark },
        .{ .char = 0xAD, .class = .format },         .{ .char = 0x200D, .class = .format },
        .{ .char = 0xE000, .class = .private },      .{ .char = 0x10FFFD, .class = .private },
        .{ .char = 0xD800, .class = .unassigned },   .{ .char = 0x0378, .class = .unassigned },
        .{ .char = 0x10FFFF, .class = .unassigned }, .{ .char = 0x110000, .class = .unassigned },
    };
    for (expected) |each| try testing.expectEqual(each.class, unicode.class(each.char));
}

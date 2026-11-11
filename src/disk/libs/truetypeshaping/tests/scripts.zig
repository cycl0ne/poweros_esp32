// SPDX-License-Identifier: MIT
//! Host tests of what a text's characters are to the shaping: their
//! scripts, the tags a font lists a script under, the characters a text
//! does not show, and the marks.

const std = @import("std");
const tts = @import("sdk").truetypeshaping;
const _scripts = @import("../shape/_scripts.zig");
const _table = @import("../shape/_script_table.zig");
const _buffer = @import("../shape/_buffer.zig");

const testing = std.testing;

/// The four letters of the script `char` is written in.
fn lettersOf(char: u32) []const u8 {
    return &_table.codes[_scripts.scriptOf(char)];
}

test "a character's script" {
    const known = [_]struct { char: u32, letters: *const [4]u8 }{
        .{ .char = 0x0000, .letters = "Zyyy" },
        .{ .char = ' ', .letters = "Zyyy" },
        .{ .char = '1', .letters = "Zyyy" },
        .{ .char = 'A', .letters = "Latn" },
        .{ .char = 'z', .letters = "Latn" },
        .{ .char = '{', .letters = "Zyyy" },
        .{ .char = 0x00D7, .letters = "Zyyy" },
        .{ .char = 0x00E9, .letters = "Latn" },
        .{ .char = 0x0301, .letters = "Zinh" },
        .{ .char = 0x03B1, .letters = "Grek" },
        .{ .char = 0x0430, .letters = "Cyrl" },
        .{ .char = 0x05D0, .letters = "Hebr" },
        .{ .char = 0x0627, .letters = "Arab" },
        .{ .char = 0x0915, .letters = "Deva" },
        .{ .char = 0x0964, .letters = "Zyyy" },
        .{ .char = 0x0E81, .letters = "Laoo" },
        .{ .char = 0x1000, .letters = "Mymr" },
        .{ .char = 0x200D, .letters = "Zinh" },
        .{ .char = 0x3042, .letters = "Hira" },
        .{ .char = 0x30A2, .letters = "Kana" },
        .{ .char = 0x4E00, .letters = "Hani" },
        .{ .char = 0xAC00, .letters = "Hang" },
        .{ .char = 0xD7A3, .letters = "Hang" },
        .{ .char = 0xE000, .letters = "Zyyy" },
        .{ .char = 0xFE0F, .letters = "Zinh" },
        .{ .char = 0x1F600, .letters = "Zyyy" },
        .{ .char = 0x10FFFF, .letters = "Zyyy" },
    };
    for (known) |entry| try testing.expectEqualStrings(entry.letters, lettersOf(entry.char));
}

test "the table is sorted, starts at 0 and names scripts it has" {
    try testing.expectEqual(@as(u32, 0), _table.starts[0] >> 8);
    for (_table.starts[1..], _table.starts[0 .. _table.starts.len - 1]) |entry, before| {
        try testing.expect(entry >> 8 > before >> 8);
        try testing.expect(@as(u8, @truncate(entry)) != @as(u8, @truncate(before)));
    }
    for (_table.starts) |entry| try testing.expect(@as(u8, @truncate(entry)) < _table.codes.len);
    try testing.expectEqualStrings("Zyyy", &_table.codes[_scripts.common]);
    try testing.expectEqualStrings("Zinh", &_table.codes[_scripts.inherited]);
}

/// The tags of the script `char` is written in.
fn tagsAt(char: u32) _scripts.Tags {
    return _scripts.tagsOf(_scripts.scriptOf(char));
}

test "the tags a font lists a script under" {
    try testing.expectEqual(tts.scriptTag("latn"), tagsAt('a').first);
    try testing.expectEqual(@as(u32, 0), tagsAt('a').other);
    try testing.expectEqual(tts.scriptTag("grek"), tagsAt(0x03B1).first);
    try testing.expectEqual(tts.scriptTag("hebr"), tagsAt(0x05D0).first);
    try testing.expectEqual(tts.scriptTag("hani"), tagsAt(0x4E00).first);
    // Spelled otherwise.
    try testing.expectEqual(tts.scriptTag("kana"), tagsAt(0x3042).first);
    try testing.expectEqual(tts.scriptTag("kana"), tagsAt(0x30A2).first);
    try testing.expectEqual(tts.scriptTag("lao "), tagsAt(0x0E81).first);
    try testing.expectEqual(tts.scriptTag("yi  "), tagsAt(0xA000).first);
    try testing.expectEqual(tts.scriptTag("nko "), tagsAt(0x07CA).first);
    try testing.expectEqual(tts.scriptTag("vai "), tagsAt(0xA500).first);
    // Two tags, the newer one first.
    const two = [_]struct { char: u32, first: *const [4]u8, other: *const [4]u8 }{
        .{ .char = 0x0995, .first = "bng2", .other = "beng" },
        .{ .char = 0x0915, .first = "dev2", .other = "deva" },
        .{ .char = 0x0A95, .first = "gjr2", .other = "gujr" },
        .{ .char = 0x0A15, .first = "gur2", .other = "guru" },
        .{ .char = 0x0C95, .first = "knd2", .other = "knda" },
        .{ .char = 0x0D15, .first = "mlm2", .other = "mlym" },
        .{ .char = 0x0B15, .first = "ory2", .other = "orya" },
        .{ .char = 0x0B95, .first = "tml2", .other = "taml" },
        .{ .char = 0x0C15, .first = "tel2", .other = "telu" },
        .{ .char = 0x1000, .first = "mym2", .other = "mymr" },
    };
    for (two) |entry| {
        try testing.expectEqual(tts.scriptTag(entry.first), tagsAt(entry.char).first);
        try testing.expectEqual(tts.scriptTag(entry.other), tagsAt(entry.char).other);
    }
    // No writing system's, and a number the table does not have.
    try testing.expectEqual(tts.scriptTag("DFLT"), tagsAt(' ').first);
    try testing.expectEqual(tts.scriptTag("DFLT"), tagsAt(0x0301).first);
    try testing.expectEqual(tts.scriptTag("DFLT"), _scripts.tagsOf(255).first);
}

test "every script's tag is four letters a font could list" {
    for (_table.codes, 0..) |_, number| {
        const tags = _scripts.tagsOf(@intCast(number));
        for ([_]u32{ tags.first, tags.other }) |tag| {
            if (tag == 0) continue;
            var shift: u5 = 24;
            while (true) : (shift -= 8) {
                const letter: u8 = @truncate(tag >> shift);
                try testing.expect(letter >= 0x20 and letter < 0x7F);
                if (shift == 0) break;
            }
        }
    }
}

test "the characters a text does not show" {
    const plain = _buffer.ITEM_IGNORABLE;
    try testing.expectEqual(@as(u8, 0), _scripts.flagsOf('a'));
    try testing.expectEqual(@as(u8, 0), _scripts.flagsOf(' '));
    try testing.expectEqual(@as(u8, 0), _scripts.flagsOf(0x00A0));
    try testing.expectEqual(@as(u8, 0), _scripts.flagsOf(0x0301));
    try testing.expectEqual(@as(u8, 0), _scripts.flagsOf(0x2010));
    try testing.expectEqual(@as(u8, 0), _scripts.flagsOf(0x1F600));
    try testing.expectEqual(plain, _scripts.flagsOf(0x00AD));
    try testing.expectEqual(plain, _scripts.flagsOf(0x200B));
    try testing.expectEqual(plain, _scripts.flagsOf(0x200E));
    try testing.expectEqual(plain, _scripts.flagsOf(0x2060));
    try testing.expectEqual(plain, _scripts.flagsOf(0xFE0F));
    try testing.expectEqual(plain, _scripts.flagsOf(0xFEFF));
    try testing.expectEqual(plain, _scripts.flagsOf(0xE0100));
    try testing.expectEqual(plain | _buffer.ITEM_NON_JOINER, _scripts.flagsOf(0x200C));
    try testing.expectEqual(plain | _buffer.ITEM_JOINER, _scripts.flagsOf(0x200D));
    try testing.expectEqual(plain, _scripts.flagsOf(0x034F));
    try testing.expectEqual(plain | _buffer.ITEM_HIDDEN, _scripts.flagsOf(0x180B));
    try testing.expectEqual(plain, _scripts.flagsOf(0x180E));
    try testing.expectEqual(plain | _buffer.ITEM_HIDDEN, _scripts.flagsOf(0x180F));
    try testing.expectEqual(plain | _buffer.ITEM_HIDDEN, _scripts.flagsOf(0xE0041));
}

test "the characters that select a form of the one before" {
    try testing.expect(_scripts.selects(0xFE00));
    try testing.expect(_scripts.selects(0xFE0F));
    try testing.expect(_scripts.selects(0xE0100));
    try testing.expect(_scripts.selects(0xE01EF));
    try testing.expect(!_scripts.selects(0xFDFF));
    try testing.expect(!_scripts.selects(0xFE10));
    try testing.expect(!_scripts.selects(0x180B));
    try testing.expect(!_scripts.selects(0x200D));
    try testing.expect(!_scripts.selects('a'));
}

test "the marks, where a font does not sort its glyphs" {
    try testing.expectEqual(_buffer.CLASS_MARK, _scripts.classOf(0x0301));
    try testing.expectEqual(_buffer.CLASS_MARK, _scripts.classOf(0x05B4));
    try testing.expectEqual(_buffer.CLASS_MARK, _scripts.classOf(0x093C));
    try testing.expectEqual(_buffer.CLASS_MARK, _scripts.classOf(0x20D7));
    try testing.expectEqual(_buffer.CLASS_BASE, _scripts.classOf('a'));
    try testing.expectEqual(_buffer.CLASS_BASE, _scripts.classOf(0x00E9));
    try testing.expectEqual(_buffer.CLASS_BASE, _scripts.classOf(0x1F600));
    // A mark that takes room on the line.
    try testing.expectEqual(_buffer.CLASS_BASE, _scripts.classOf(0x093E));
    // One that encloses, and those a text does not show.
    try testing.expectEqual(_buffer.CLASS_BASE, _scripts.classOf(0x20DD));
    try testing.expectEqual(_buffer.CLASS_BASE, _scripts.classOf(0x200D));
    try testing.expectEqual(_buffer.CLASS_BASE, _scripts.classOf(0xFE0F));
}

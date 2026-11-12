// SPDX-License-Identifier: MPL-2.0
//! The tests of the SDK's `utf8` and `unicode`, which every part of the
//! system reads text with, run with the text calls.

const std = @import("std");
const utf8 = @import("sdk").utility.utf8;

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

test "utf8.read: a byte that is no UTF-8 reads as U+FFFD" {
    try testing.expectEqual(utf8.Read{ .char = 0x20AC, .length = 3 }, utf8.read("\xE2\x82\xACx"));
    // A byte alone, a Latin-1 letter among them.
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 1, .broken = true }, utf8.read("\xFCll"));
    // A broken sequence is one, and the byte that broke it is read again.
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 2, .broken = true }, utf8.read("\xE2\x82x"));
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 1, .broken = true }, utf8.read("\x80\x80"));
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 3, .broken = true }, utf8.read("\xE0\x80\x80"));
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 1, .broken = true }, utf8.read("\xC3\x1B["));
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 1, .broken = true }, utf8.read("\xFF"));
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
    try testing.expectEqual(@as(usize, 1), utf8.cut("a\xB0b", 1)); // a stray continuation
    try testing.expectEqual(@as(usize, 1), utf8.cut("\xFC\xA4x", 1)); // a byte that starts nothing
    try testing.expectEqual(@as(usize, 1), utf8.cut("a\xE2\x82", 2)); // right so far
    try testing.expectEqual(@as(usize, 1), utf8.cut("\xE2\x82x", 1)); // broken off
    try testing.expectEqual(@as(usize, 0), utf8.cut("", 0));
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
    // Bytes that are no character end with U+FFFD, as the walk forward
    // reads them: the sequence broken off, or the last byte alone.
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 2, .broken = true }, utf8.readLast("\xE2\x82"));
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 1, .broken = true }, utf8.readLast("\xC3\xA4\xA4"));
    try testing.expectEqual(utf8.Read{ .char = 0xFFFD, .length = 1, .broken = true }, utf8.readLast("M\xFC"));
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

/// The clusters of `text` going forward, each checked from every one
/// of its bytes going back, against the `lengths` of the clusters.
fn expectClusters(text: []const u8, lengths: []const usize) !void {
    const unicode = @import("sdk").utility.unicode;
    var start: usize = 0;
    for (lengths) |length| {
        try testing.expectEqual(start + length, unicode.clusterEnd(text, start));
        for (start..start + length) |at| try testing.expectEqual(start, unicode.clusterStart(text, at));
        start += length;
    }
    try testing.expectEqual(text.len, start);
    try testing.expectEqual(text.len, unicode.clusterEnd(text, text.len));
    try testing.expectEqual(text.len, unicode.clusterStart(text, text.len));
}

test "unicode.part: what a character is in a cluster" {
    const unicode = @import("sdk").utility.unicode;
    const expected = [_]struct { char: u32, part: unicode.Part }{
        .{ .char = 'a', .part = .other },              .{ .char = '\r', .part = .cr },
        .{ .char = '\n', .part = .lf },                .{ .char = 0x07, .part = .control },
        .{ .char = 0x0301, .part = .conjunct_extend }, .{ .char = 0x200C, .part = .extend },
        .{ .char = 0x200D, .part = .joiner },          .{ .char = 0x0915, .part = .consonant },
        .{ .char = 0x093C, .part = .conjunct_extend }, .{ .char = 0x093F, .part = .spacing },
        .{ .char = 0x094D, .part = .linker },          .{ .char = 0x0600, .part = .prepend },
        .{ .char = 0x1100, .part = .lead },            .{ .char = 0x1161, .part = .vowel },
        .{ .char = 0x11A8, .part = .trail },           .{ .char = 0xAC00, .part = .syllable },
        .{ .char = 0xAC01, .part = .syllable_trail },  .{ .char = 0xAC1B, .part = .syllable_trail },
        .{ .char = 0xAC1C, .part = .syllable },        .{ .char = 0xD7A3, .part = .syllable_trail },
        .{ .char = 0xD7A4, .part = .other },           .{ .char = 0x1F1E9, .part = .regional },
        .{ .char = 0x1F600, .part = .pictographic },   .{ .char = 0x1F3FB, .part = .conjunct_extend },
        .{ .char = 0x00A9, .part = .pictographic },    .{ .char = 0x110000, .part = .other },
    };
    for (expected) |each| try testing.expectEqual(each.part, unicode.part(each.char));
}

test "unicode.clusterEnd, clusterStart: letters with their marks, conjuncts, flags, joined pictographs" {
    try expectClusters("", &.{});
    try expectClusters("Go", &.{ 1, 1 });
    // A letter and a mark on it; a line's end of two characters.
    try expectClusters("e\u{0301}a", &.{ 3, 1 });
    try expectClusters("a\r\nb\n\r", &.{ 1, 2, 1, 1, 1 });
    // kshatriya and hindi: a virama joins its consonants, and the vowel
    // sign stays with them.
    try expectClusters("क्षत्रिय", &.{ 9, 12, 3 });
    try expectClusters("हिन्दी", &.{ 6, 12 });
    try expectClusters("मुँह", &.{ 9, 3 });
    // A nukta inside a conjunct, and a joiner; a non-joiner behind the
    // virama parts the two, as a virama with no consonant behind it
    // ends its cluster.
    try expectClusters("फ़्ल", &.{12});
    try expectClusters("क्\u{200D}ष", &.{12});
    try expectClusters("क्\u{200C}ष", &.{ 9, 3 });
    try expectClusters("क् a", &.{ 6, 1, 1 });
    // Hangul written as its parts, and a syllable with a trail behind.
    try expectClusters("\u{1100}\u{1161}\u{11A8}\u{1100}", &.{ 9, 3 });
    try expectClusters("\u{AC00}\u{11A8}\u{AC01}\u{11A8}\u{1161}", &.{ 6, 6, 3 });
    // Regional indicators by twos, whatever number of them.
    try expectClusters("\u{1F1E9}\u{1F1EA}\u{1F1EE}\u{1F1F3}\u{1F1EB}", &.{ 8, 8, 4 });
    try expectClusters("a\u{1F1E9}\u{1F1EA}\u{1F1EE}", &.{ 1, 8, 4 });
    // A family of three, a skin tone, a picture asked for by a selector;
    // a joiner behind a letter joins no pictograph.
    try expectClusters("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}!", &.{ 18, 1 });
    try expectClusters("\u{1F44B}\u{1F3FD}\u{2764}\u{FE0F}", &.{ 8, 6 });
    try expectClusters("a\u{200D}\u{1F600}", &.{ 4, 4 });
    // Bytes that are no UTF-8 are a character each.
    try expectClusters("a\xFFb\xE0\xA4", &.{ 1, 1, 1, 2 });
}

test "unicode.clusterEnd, clusterStart: every line of Unicode's GraphemeBreakTest.txt" {
    const test_options = @import("test_options");
    if (test_options.unicode_dir.len == 0) return error.SkipZigTest;
    var path_buffer: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/GraphemeBreakTest.txt", .{test_options.unicode_dir});
    const listing = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(listing);

    var checked: usize = 0;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        // "÷ 0020 × 0308 ÷ 0020 ÷": a cluster ends at each ÷.
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        var text: [128]u8 = undefined;
        var length: usize = 0;
        var lengths: [32]usize = undefined;
        var clusters: usize = 0;
        var start: usize = 0;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        while (words.next()) |word| {
            if (std.mem.eql(u8, word, "×")) continue;
            if (std.mem.eql(u8, word, "÷")) {
                if (length == start) continue;
                lengths[clusters] = length - start;
                clusters += 1;
                start = length;
                continue;
            }
            length += utf8.encode(try std.fmt.parseInt(u21, word, 16), text[length..][0..4]);
        }
        expectClusters(text[0..length], lengths[0..clusters]) catch |err| {
            std.debug.print("GraphemeBreakTest.txt: {s}\n", .{line});
            return err;
        };
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 1093), checked);
}

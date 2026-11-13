// SPDX-License-Identifier: MIT
//! Host tests of a text shaped, on tables built in the test: the
//! characters read and made glyphs, the text cut by script, the
//! characters a text does not show, the features a text is shaped with
//! and how a caller changes them, marks, the `kern` table, both
//! directions, and the errors.
//!
//! The font of these tests has a glyph of each character's own number
//! (harness.zig), so the tables name the letter "f" as the glyph 'f'.

const std = @import("std");
const tts = @import("sdk").truetypeshaping;
const layout = @import("layout.zig");
const subtables = @import("subtables.zig");
const harness = @import("harness.zig");

const File = layout.File;
const shapeText = harness.shapeText;
const testing = std.testing;

/// What a text became, checked: its glyphs and their clusters.
fn expectShaped(run: *const harness.Run, glyphs: []const u32, clusters: []const u32) !void {
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectGlyphs(glyphs);
    try run.expectClusters(clusters);
}

/// A `GSUB` of the script `DFLT` with the one feature `tag`, whose
/// lookups are all of `lookups`.
fn oneFeature(file: *File, tag: *const [4]u8, lookups: []const layout.Lookup) void {
    var numbers: [8]u16 = undefined;
    for (lookups, 0..) |_, index| numbers[index] = @intCast(index);
    layout.table(file, &.{.{ .tag = tag, .lookups = numbers[0..lookups.len] }}, lookups);
}

test "each character its glyph, each cluster the place of its first byte" {
    const run = shapeText(.{}, "a\u{E9}\u{20AC}\u{1F600}!", .{ .glyphs = &.{.{ 0x1F600, 500 }} });
    try expectShaped(&run, &.{ 'a', 0xE9, 0x20AC, 500, '!' }, &.{ 0, 1, 3, 6, 10 });
    try run.expectAdvances(&.{ 1000, 1000, 1000, 1000, 1000 });
    try run.expectOffsets(&.{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } });
}

test "a character the font lacks is the glyph 0" {
    const run = shapeText(.{}, "a\u{1F600}b", .{});
    try expectShaped(&run, &.{ 'a', 0, 'b' }, &.{ 0, 1, 5 });
}

test "a byte that is no UTF-8 reads as U+FFFD" {
    var run = shapeText(.{}, "a\xFFb", .{});
    try expectShaped(&run, &.{ 'a', 0xFFFD, 'b' }, &.{ 0, 1, 2 });
    // A character cut short at the text's end.
    run = shapeText(.{}, "a\xE2\x82", .{});
    try testing.expectEqual(tts.TTS_OK, run.result);
    try testing.expectEqual(@as(u32, 'a'), run.glyphs[0].glyph);
    for (run.glyphs[1..run.count]) |glyph| try testing.expectEqual(@as(u32, 0xFFFD), glyph.glyph);
}

test "a text of no bytes is no glyphs" {
    const run = shapeText(.{}, "", .{});
    try testing.expectEqual(tts.TTS_OK, run.result);
    try testing.expectEqual(@as(u32, 0), run.count);
}

test "a text is cut by script, a shared character going with the stretch before" {
    var latin: File = .{};
    subtables.singleDelta(&latin, &.{ ' ', 'a' }, 0x100);
    var greek: File = .{};
    subtables.singleDelta(&greek, &.{ ' ', 0x3B1 }, 0x200);
    var shared: File = .{};
    subtables.singleDelta(&shared, &.{ ' ', '1' }, 0x300);
    var table: File = .{};
    layout.tableOf(&table, &.{
        .{ .tag = "DFLT", .languages = &.{.{ .features = &.{2} }} },
        .{ .tag = "grek", .languages = &.{.{ .features = &.{1} }} },
        .{ .tag = "latn", .languages = &.{.{ .features = &.{0} }} },
    }, &.{
        .{ .tag = "ccmp", .lookups = &.{0} },
        .{ .tag = "ccmp", .lookups = &.{1} },
        .{ .tag = "ccmp", .lookups = &.{2} },
    }, &.{
        .{ .kind = 1, .subtables = &.{latin.written()} },
        .{ .kind = 1, .subtables = &.{greek.written()} },
        .{ .kind = 1, .subtables = &.{shared.written()} },
    });
    const tables: harness.Tables = .{ .gsub = table.written() };

    // The space is Latin's; the Greek letter starts a stretch.
    var run = shapeText(tables, "a \u{3B1}", .{});
    try expectShaped(&run, &.{ 'a' + 0x100, ' ' + 0x100, 0x3B1 + 0x200 }, &.{ 0, 1, 2 });
    // And the one behind the Greek letter is Greek's, as its mark is.
    // The font has no glyph for the two as one character.
    run = shapeText(tables, "\u{3B1}\u{301} a", .{ .glyphs = &.{.{ 0x3AC, 0 }} });
    try expectShaped(&run, &.{ 0x3B1 + 0x200, 0x301, ' ' + 0x200, 'a' + 0x100 }, &.{ 0, 2, 4, 5 });
    // What a text starts with goes with its first stretch.
    run = shapeText(tables, " a", .{});
    try expectShaped(&run, &.{ ' ' + 0x100, 'a' + 0x100 }, &.{ 0, 1 });
    // Shared characters alone are shaped by `DFLT`.
    run = shapeText(tables, " 1", .{});
    try expectShaped(&run, &.{ ' ' + 0x300, '1' + 0x300 }, &.{ 0, 1 });
    // A script the table does not list, too.
    run = shapeText(tables, "\u{5D0} ", .{});
    try expectShaped(&run, &.{ 0x5D0, ' ' + 0x300 }, &.{ 0, 2 });
}

test "a script of two tags is looked for under the newer one first" {
    var newer: File = .{};
    subtables.singleDelta(&newer, &.{0x915}, 1);
    var older: File = .{};
    subtables.singleDelta(&older, &.{0x915}, 2);
    const features = [_]layout.Feature{ .{ .tag = "ccmp", .lookups = &.{0} }, .{ .tag = "ccmp", .lookups = &.{1} } };
    const lookups = [_]layout.Lookup{
        .{ .kind = 1, .subtables = &.{newer.written()} },
        .{ .kind = 1, .subtables = &.{older.written()} },
    };
    var both: File = .{};
    layout.tableOf(&both, &.{
        .{ .tag = "dev2", .languages = &.{.{ .features = &.{0} }} },
        .{ .tag = "deva", .languages = &.{.{ .features = &.{1} }} },
    }, &features, &lookups);
    var run = shapeText(.{ .gsub = both.written() }, "\u{915}", .{});
    try expectShaped(&run, &.{0x916}, &.{0});

    var old_only: File = .{};
    layout.tableOf(&old_only, &.{
        .{ .tag = "DFLT", .languages = &.{.{ .features = &.{0} }} },
        .{ .tag = "deva", .languages = &.{.{ .features = &.{1} }} },
    }, &features, &lookups);
    run = shapeText(.{ .gsub = old_only.written() }, "\u{915}", .{});
    try expectShaped(&run, &.{0x917}, &.{0});
}

test "a script whose tag is spelled otherwise" {
    var lookup: File = .{};
    subtables.singleDelta(&lookup, &.{ 0x0E81, 0x3042 }, 1);
    var table: File = .{};
    layout.tableOf(&table, &.{
        .{ .tag = "kana", .languages = &.{.{ .features = &.{0} }} },
        .{ .tag = "lao ", .languages = &.{.{ .features = &.{0} }} },
    }, &.{.{ .tag = "ccmp", .lookups = &.{0} }}, &.{.{ .kind = 1, .subtables = &.{lookup.written()} }});
    const run = shapeText(.{ .gsub = table.written() }, "\u{3042}\u{E81}", .{});
    try expectShaped(&run, &.{ 0x3043, 0x0E82 }, &.{ 0, 3 });
}

test "a character and its selector are the one glyph the font has for the two" {
    const options: harness.TextOptions = .{ .variants = &.{ .{ 'a', 0xFE00, 300 }, .{ 0x4E00, 0xE0100, 301 } } };
    var run = shapeText(.{}, "a\u{FE00}b", options);
    try expectShaped(&run, &.{ 300, 'b' }, &.{ 0, 4 });
    run = shapeText(.{}, "\u{4E00}\u{E0100}\u{4E00}", options);
    try expectShaped(&run, &.{ 301, 0x4E00 }, &.{ 0, 7 });
    // A selector the font has nothing for is not shown.
    run = shapeText(.{}, "b\u{FE00}a\u{FE01}", options);
    try expectShaped(&run, &.{ 'b', 'a' }, &.{ 0, 4 });
    // Nor is one with nothing before it.
    run = shapeText(.{}, "\u{FE00}a", options);
    try expectShaped(&run, &.{'a'}, &.{0});
}

test "the characters a text does not show are taken out" {
    var run = shapeText(.{}, "a\u{AD}b\u{200B}\u{200D}c", .{});
    try expectShaped(&run, &.{ 'a', 'b', 'c' }, &.{ 0, 3, 10 });
    // One a text starts with leaves its bytes to the glyph behind it.
    run = shapeText(.{}, "\u{AD}a", .{});
    try expectShaped(&run, &.{'a'}, &.{0});
    run = shapeText(.{}, "\u{AD}\u{200B}", .{});
    try testing.expectEqual(tts.TTS_OK, run.result);
    try testing.expectEqual(@as(u32, 0), run.count);
    // Read from right to left, the glyph drawn before it is the one
    // behind it in the text, and has its bytes then.
    run = shapeText(.{}, "a\u{AD}b", .{ .backward = true });
    try expectShaped(&run, &.{ 'b', 'a' }, &.{ 1, 0 });
    run = shapeText(.{}, "a\u{AD}\u{200B}b\u{200D}", .{ .backward = true });
    try expectShaped(&run, &.{ 'b', 'a' }, &.{ 1, 0 });
}

test "one a lookup made something of stays" {
    var lookup: File = .{};
    subtables.singleDelta(&lookup, &.{0x200D}, 1);
    var table: File = .{};
    oneFeature(&table, "ccmp", &.{.{ .kind = 1, .subtables = &.{lookup.written()} }});
    const run = shapeText(.{ .gsub = table.written() }, "a\u{200D}b\u{200C}", .{});
    try expectShaped(&run, &.{ 'a', 0x200E, 'b' }, &.{ 0, 1, 4 });
}

test "a ligature forms across what a text does not show, but for the non-joiner and the hidden ones" {
    var lookup: File = .{};
    subtables.ligature(&lookup, &.{'f'}, &.{&.{.{ .glyph = 400, .rest = &.{'i'} }}});
    var table: File = .{};
    oneFeature(&table, "liga", &.{.{ .kind = 4, .subtables = &.{lookup.written()} }});
    const tables: harness.Tables = .{ .gsub = table.written() };

    var run = shapeText(tables, "fi", .{});
    try expectShaped(&run, &.{400}, &.{0});
    run = shapeText(tables, "f\u{AD}i", .{});
    try expectShaped(&run, &.{400}, &.{0});
    run = shapeText(tables, "f\u{200D}i", .{});
    try expectShaped(&run, &.{400}, &.{0});
    run = shapeText(tables, "f\u{200C}i", .{});
    try expectShaped(&run, &.{ 'f', 'i' }, &.{ 0, 4 });
    run = shapeText(tables, "f\u{34F}i", .{});
    try expectShaped(&run, &.{400}, &.{0});
    run = shapeText(tables, "f\u{180B}i", .{});
    try expectShaped(&run, &.{ 'f', 'i' }, &.{ 0, 4 });
    run = shapeText(tables, "f\u{E0041}i", .{});
    try expectShaped(&run, &.{ 'f', 'i' }, &.{ 0, 5 });
}

test "what a lookup looks at before and behind reaches across the non-joiner, not across a hidden one" {
    var chain: File = .{};
    subtables.chain3(&chain, &.{&.{'w'}}, &.{&.{'x'}}, &.{&.{'y'}}, &.{.{ .at = 0, .lookup = 1 }});
    var single: File = .{};
    subtables.singleDelta(&single, &.{'x'}, 0x100);
    var table: File = .{};
    layout.table(&table, &.{.{ .tag = "calt", .lookups = &.{0} }}, &.{
        .{ .kind = 6, .subtables = &.{chain.written()} },
        .{ .kind = 1, .subtables = &.{single.written()} },
    });
    const tables: harness.Tables = .{ .gsub = table.written() };

    var run = shapeText(tables, "wxy", .{});
    try expectShaped(&run, &.{ 'w', 'x' + 0x100, 'y' }, &.{ 0, 1, 2 });
    run = shapeText(tables, "w\u{200C}x\u{200C}y", .{});
    try expectShaped(&run, &.{ 'w', 'x' + 0x100, 'y' }, &.{ 0, 4, 8 });
    run = shapeText(tables, "w\u{AD}x\u{200D}y", .{});
    try expectShaped(&run, &.{ 'w', 'x' + 0x100, 'y' }, &.{ 0, 3, 7 });
    run = shapeText(tables, "w\u{34F}x\u{34F}y", .{});
    try expectShaped(&run, &.{ 'w', 'x' + 0x100, 'y' }, &.{ 0, 3, 6 });
    run = shapeText(tables, "wx\u{180B}y", .{});
    try expectShaped(&run, &.{ 'w', 'x', 'y' }, &.{ 0, 1, 5 });
    run = shapeText(tables, "w\u{180B}xy", .{});
    try expectShaped(&run, &.{ 'w', 'x', 'y' }, &.{ 0, 4, 5 });
}

test "a mark's advance is 0, and without GPOS it moves back by it" {
    // A font without the "é".
    const options: harness.TextOptions = .{ .advances = &.{.{ 0x301, 200 }}, .glyphs = &.{.{ 0xE9, 0 }} };
    var run = shapeText(.{}, "e\u{301}x", options);
    try expectShaped(&run, &.{ 'e', 0x301, 'x' }, &.{ 0, 1, 3 });
    try run.expectAdvances(&.{ 1000, 0, 1000 });
    try run.expectOffsets(&.{ .{ 0, 0 }, .{ -200, 0 }, .{ 0, 0 } });

    // Read from right to left it stays where it is.
    var leftward = options;
    leftward.backward = true;
    run = shapeText(.{}, "e\u{301}x", leftward);
    try expectShaped(&run, &.{ 'x', 0x301, 'e' }, &.{ 3, 1, 0 });
    try run.expectAdvances(&.{ 1000, 0, 1000 });
    try run.expectOffsets(&.{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } });

    // And with a GPOS, which is then the one to place it.
    var lookup: File = .{};
    subtables.positionAll(&lookup, &.{'q'}, subtables.X_ADVANCE, &.{10});
    var table: File = .{};
    oneFeature(&table, "kern", &.{.{ .kind = 1, .subtables = &.{lookup.written()} }});
    run = shapeText(.{ .gpos = table.written() }, "e\u{301}x", options);
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectAdvances(&.{ 1000, 0, 1000 });
    try run.expectOffsets(&.{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } });
}

test "what is a mark is GDEF's to say where it sorts the glyphs" {
    const options: harness.TextOptions = .{ .advances = &.{.{ 0x301, 200 }}, .glyphs = &.{.{ 0xE9, 0 }} };
    // The accent is of no kind, the "x" a mark.
    var sorted: File = .{};
    layout.gdef(&sorted, .{ .kinds = &.{ .{ .glyph = 'e', .class = 1 }, .{ .glyph = 'x', .class = 3 } } });
    var run = shapeText(.{ .gdef = sorted.written() }, "e\u{301}x", options);
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectAdvances(&.{ 1000, 200, 0 });
    try run.expectOffsets(&.{ .{ 0, 0 }, .{ 0, 0 }, .{ -1000, 0 } });
}

test "the kern table sets pairs as they are drawn" {
    // A font without the "Á".
    const options: harness.TextOptions = .{
        .kerning = &.{ .{ 'A', 'V', -80 }, .{ 'V', 'A', -50 } },
        .glyphs = &.{.{ 0xC1, 0 }},
    };
    var run = shapeText(.{}, "AVA", options);
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectAdvances(&.{ 920, 950, 1000 });
    try run.expectOffsets(&.{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } });

    // Read from right to left the "V" is the left one.
    var leftward = options;
    leftward.backward = true;
    run = shapeText(.{}, "AV", leftward);
    try expectShaped(&run, &.{ 'V', 'A' }, &.{ 1, 0 });
    try run.expectAdvances(&.{ 950, 1000 });

    // A mark between the two is stepped over.
    run = shapeText(.{}, "A\u{301}V", options);
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectAdvances(&.{ 920, 0, 1000 });
}

test "the kern table is not asked where GPOS kerns, or the caller switched kerning off" {
    const options: harness.TextOptions = .{ .kerning = &.{.{ 'A', 'V', -80 }} };
    var pair: File = .{};
    subtables.pairs(&pair, &.{'A'}, subtables.X_ADVANCE, 0, &.{&.{.{ .second = 'V', .values = &.{-30} }}});
    const lookups = [_]layout.Lookup{.{ .kind = 2, .subtables = &.{pair.written()} }};

    var kerning: File = .{};
    oneFeature(&kerning, "kern", &lookups);
    var run = shapeText(.{ .gpos = kerning.written() }, "AV", options);
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectAdvances(&.{ 970, 1000 });

    // A GPOS of other features leaves the pairs to the kern table.
    var other: File = .{};
    oneFeature(&other, "cpsp", &lookups);
    run = shapeText(.{ .gpos = other.written() }, "AV", options);
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectAdvances(&.{ 920, 1000 });

    var off = options;
    off.features = &.{.{ .tag = tts.featureTag("kern"), .value = 0 }};
    run = shapeText(.{}, "AV", off);
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectAdvances(&.{ 1000, 1000 });

    // Off for the second pair only.
    var partly = options;
    partly.features = &.{.{ .tag = tts.featureTag("kern"), .value = 0, .first = 2, .last = 3 }};
    run = shapeText(.{}, "AVAV", partly);
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectAdvances(&.{ 920, 1000, 1000, 1000 });
}

test "what rvrn makes is there for every other feature, and what a language requires is applied once" {
    var second: File = .{};
    subtables.singleDelta(&second, &.{'b'}, 1);
    var first: File = .{};
    subtables.singleDelta(&first, &.{'a'}, 1);
    var needed: File = .{};
    subtables.singleDelta(&needed, &.{ 'x', 'y' }, 1);
    var table: File = .{};
    layout.tableOf(&table, &.{.{ .tag = "DFLT", .languages = &.{.{ .required = 1, .features = &.{ 0, 2 } }} }}, &.{
        .{ .tag = "ccmp", .lookups = &.{0} },
        .{ .tag = "rqd ", .lookups = &.{2} },
        .{ .tag = "rvrn", .lookups = &.{1} },
    }, &.{
        .{ .kind = 1, .subtables = &.{second.written()} },
        .{ .kind = 1, .subtables = &.{first.written()} },
        .{ .kind = 1, .subtables = &.{needed.written()} },
    });
    const tables: harness.Tables = .{ .gsub = table.written() };

    // A run of glyphs goes through the lookups in the table's order.
    const features = [_]tts.Feature{ .{ .tag = tts.featureTag("ccmp") }, .{ .tag = tts.featureTag("rvrn") } };
    const glyphs = harness.shape(tables, &.{'a'}, .{ .features = &features });
    try testing.expectEqual(tts.TTS_OK, glyphs.result);
    try glyphs.expectGlyphs(&.{'b'});

    var run = shapeText(tables, "a", .{});
    try expectShaped(&run, &.{'c'}, &.{0});
    run = shapeText(tables, "x", .{});
    try expectShaped(&run, &.{'y'}, &.{0});
}

/// A table of the script `DFLT` with a feature for each of `tags`, the
/// feature of number n holding the one lookup n, which `write` writes
/// for the glyph 'a' + n.
fn tableOfTags(table: *File, comptime tags: []const *const [4]u8, kind: u16, write: *const fn (file: *File, glyph: u16) void) void {
    var room: [tags.len]File = undefined;
    var lists: [tags.len][1][]const u8 = undefined;
    var lookups: [tags.len]layout.Lookup = undefined;
    var features: [tags.len]layout.Feature = undefined;
    const numbers = comptime made: {
        var list: [tags.len][1]u16 = undefined;
        for (&list, 0..) |*entry, index| entry[0] = index;
        break :made list;
    };
    for (tags, 0..) |tag, index| {
        room[index] = .{};
        write(&room[index], @intCast('a' + index));
        lists[index][0] = room[index].written();
        lookups[index] = .{ .kind = kind, .subtables = &lists[index] };
        features[index] = .{ .tag = tag, .lookups = &numbers[index] };
    }
    layout.table(table, &features, &lookups);
}

fn writeReplaced(file: *File, glyph: u16) void {
    subtables.singleDelta(file, &.{glyph}, 0x100);
}

fn writeWidened(file: *File, glyph: u16) void {
    subtables.positionAll(file, &.{glyph}, subtables.X_ADVANCE, &.{10});
}

const replacing_tags = [_]*const [4]u8{ "calt", "ccmp", "clig", "dlig", "liga", "locl", "ltra", "ltrm", "rclt", "rlig", "rtla", "rtlm", "rvrn", "smcp" };
const placing_tags = [_]*const [4]u8{ "abvm", "blwm", "cpsp", "curs", "dist", "kern", "mark", "mkmk" };

test "the features a text is shaped with" {
    var gsub: File = .{};
    tableOfTags(&gsub, &replacing_tags, 1, writeReplaced);
    var gpos: File = .{};
    tableOfTags(&gpos, &placing_tags, 1, writeWidened);
    const tables: harness.Tables = .{ .gsub = gsub.written(), .gpos = gpos.written() };
    const text = "abcdefghijklmn";
    const up = 0x100;

    // Not `dlig` and `smcp`, nor the two of the other direction; and of
    // GPOS's not `cpsp`.
    var run = shapeText(tables, text, .{});
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectGlyphs(&.{ 'a' + up, 'b' + up, 'c' + up, 'd', 'e' + up, 'f' + up, 'g' + up, 'h' + up, 'i' + up, 'j' + up, 'k', 'l', 'm' + up, 'n' });
    run = shapeText(tables, text, .{ .backward = true });
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectGlyphs(&.{ 'n', 'm' + up, 'l' + up, 'k' + up, 'j' + up, 'i' + up, 'h', 'g', 'f' + up, 'e' + up, 'd', 'c' + up, 'b' + up, 'a' + up });

    run = shapeText(.{ .gpos = gpos.written() }, "abcdefgh", .{});
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectAdvances(&.{ 1010, 1010, 1000, 1010, 1010, 1010, 1010, 1010 });
}

test "a caller's entry leaves one of them out, and adds another" {
    var gsub: File = .{};
    tableOfTags(&gsub, &replacing_tags, 1, writeReplaced);
    const tables: harness.Tables = .{ .gsub = gsub.written() };
    const up = 0x100;
    const run = shapeText(tables, "cdemn", .{ .features = &.{
        .{ .tag = tts.featureTag("liga"), .value = 0 },
        .{ .tag = tts.featureTag("rvrn"), .value = 0 },
        .{ .tag = tts.featureTag("dlig") },
    } });
    try expectShaped(&run, &.{ 'c' + up, 'd' + up, 'e', 'm', 'n' }, &.{ 0, 1, 2, 3, 4 });
}

test "a caller's entry holds for the bytes it names" {
    var lookup: File = .{};
    subtables.ligature(&lookup, &.{'f'}, &.{&.{.{ .glyph = 400, .rest = &.{'i'} }}});
    var small: File = .{};
    subtables.singleDelta(&small, &.{'a'}, 0x100);
    var table: File = .{};
    layout.table(&table, &.{ .{ .tag = "liga", .lookups = &.{0} }, .{ .tag = "smcp", .lookups = &.{1} } }, &.{
        .{ .kind = 4, .subtables = &.{lookup.written()} },
        .{ .kind = 1, .subtables = &.{small.written()} },
    });
    const tables: harness.Tables = .{ .gsub = table.written() };

    // No ligature for the first two bytes; the others keep theirs.
    var run = shapeText(tables, "fifi", .{ .features = &.{.{ .tag = tts.featureTag("liga"), .value = 0, .first = 0, .last = 1 }} });
    try expectShaped(&run, &.{ 'f', 'i', 400 }, &.{ 0, 1, 2 });
    // The second "a" is at the byte 5.
    run = shapeText(tables, "\u{E9}a\u{E9}a", .{ .features = &.{.{ .tag = tts.featureTag("smcp"), .first = 3, .last = 5 }} });
    try expectShaped(&run, &.{ 0xE9, 'a', 0xE9, 'a' + 0x100 }, &.{ 0, 2, 3, 5 });
}

test "a text read from right to left is answered turned around as a whole" {
    var latin: File = .{};
    subtables.ligature(&latin, &.{'a'}, &.{&.{.{ .glyph = 400, .rest = &.{'b'} }}});
    var table: File = .{};
    layout.tableOf(&table, &.{.{ .tag = "latn", .languages = &.{.{ .features = &.{0} }} }}, &.{.{ .tag = "liga", .lookups = &.{0} }}, &.{
        .{ .kind = 4, .subtables = &.{latin.written()} },
    });
    var run = shapeText(.{}, "ab \u{3B1}\u{3B2}", .{ .backward = true });
    try expectShaped(&run, &.{ 0x3B2, 0x3B1, ' ', 'b', 'a' }, &.{ 5, 3, 2, 1, 0 });
    run = shapeText(.{ .gsub = table.written() }, "ab \u{3B1}\u{3B2}ab", .{ .backward = true });
    try expectShaped(&run, &.{ 400, 0x3B2, 0x3B1, ' ', 400 }, &.{ 7, 5, 3, 2, 0 });
    run = shapeText(.{ .gsub = table.written() }, "ab \u{3B1}\u{3B2}ab", .{});
    try expectShaped(&run, &.{ 400, ' ', 0x3B1, 0x3B2, 400 }, &.{ 0, 2, 3, 5, 7 });
}

test "a text of more glyphs than there is room for says how many" {
    var run = shapeText(.{}, "abc", .{ .room = 2 });
    try testing.expectEqual(tts.TTSERR_ROOM, run.result);
    try testing.expectEqual(@as(u32, 3), run.count);
    run = shapeText(.{}, "ab\u{3B1}\u{3B2}", .{ .room = 0 });
    try testing.expectEqual(tts.TTSERR_ROOM, run.result);
    try testing.expectEqual(@as(u32, 4), run.count);
    run = shapeText(.{}, "ab\u{3B1}\u{3B2}", .{ .room = 3, .backward = true });
    try testing.expectEqual(tts.TTSERR_ROOM, run.result);
    try testing.expectEqual(@as(u32, 4), run.count);
    run = shapeText(.{}, "abc", .{ .room = 3 });
    try expectShaped(&run, &.{ 'a', 'b', 'c' }, &.{ 0, 1, 2 });
    // The glyphs are those the font draws the text with: a character
    // it lacks taken apart is three of them.
    const lacking: []const [2]u32 = &.{ .{ 0x1EAD, 0 }, .{ 0x1EA1, 0 }, .{ 0xE2, 0 } };
    run = shapeText(.{}, "\u{1EAD}", .{ .room = 2, .glyphs = lacking });
    try testing.expectEqual(tts.TTSERR_ROOM, run.result);
    try testing.expectEqual(@as(u32, 3), run.count);
}

test "a text taken apart into more characters than it had" {
    // 16 characters the font lacks, each of them three it has: more
    // than the room a stretch starts with.
    const lacking: []const [2]u32 = &.{ .{ 0x1EAD, 0 }, .{ 0x1EA1, 0 }, .{ 0xE2, 0 } };
    const text = "\u{1EAD}" ** 16;
    var run = shapeText(.{}, text, .{ .glyphs = lacking });
    try testing.expectEqual(tts.TTS_OK, run.result);
    try testing.expectEqual(@as(u32, 48), run.count);
    for (run.glyphs[0..run.count], 0..) |glyph, index| {
        const expected: u32 = switch (index % 3) {
            0 => 'a',
            1 => 0x323,
            else => 0x302,
        };
        try testing.expectEqual(expected, glyph.glyph);
        try testing.expectEqual(@as(u32, @intCast(index / 3 * 3)), glyph.cluster);
    }
    // And without the memory for it at any block.
    var blocks: u32 = 0;
    while (blocks < 64) : (blocks += 1) {
        run = shapeText(.{}, text, .{ .glyphs = lacking, .blocks = blocks });
        if (run.result == tts.TTS_OK) break;
        try testing.expectEqual(tts.TTSERR_NOMEM, run.result);
        try testing.expectEqual(@as(u32, 0xDEAD), run.count);
    }
    // The features, the stretch's characters and the room they grew
    // to, its buffer and its masks.
    try testing.expect(blocks > 4 and blocks < 64);
}

test "without the memory the call says so, and leaves the count" {
    var lookup: File = .{};
    subtables.ligature(&lookup, &.{'f'}, &.{&.{.{ .glyph = 400, .rest = &.{'i'} }}});
    var table: File = .{};
    oneFeature(&table, "liga", &.{.{ .kind = 4, .subtables = &.{lookup.written()} }});
    const tables: harness.Tables = .{ .gsub = table.written(), .gpos = table.written() };
    var blocks: u32 = 0;
    while (blocks < 64) : (blocks += 1) {
        const run = shapeText(tables, "fi \u{3B1}fi", .{ .blocks = blocks });
        if (run.result == tts.TTS_OK) {
            try run.expectGlyphs(&.{ 400, ' ', 0x3B1, 400 });
            break;
        }
        try testing.expectEqual(tts.TTSERR_NOMEM, run.result);
        try testing.expectEqual(@as(u32, 0xDEAD), run.count);
    }
    // The list of features, and for each stretch its buffer, its masks
    // and a table's lookups.
    try testing.expect(blocks > 4 and blocks < 64);
}

test "the digits around a fraction slash are a fraction" {
    // The lookups in the order they are applied: the fraction's first,
    // so the other two find what it made.
    var whole: File = .{};
    subtables.singleDelta(&whole, &.{ '1', '2', '3', '4', 0x2044 }, 0x1000);
    var numerators: File = .{};
    subtables.singleDelta(&numerators, &.{ '1' + 0x1000, '2' + 0x1000, '3' + 0x1000, '4' + 0x1000 }, 0x100);
    var denominators: File = .{};
    subtables.singleDelta(&denominators, &.{ '1' + 0x1000, '2' + 0x1000, '3' + 0x1000, '4' + 0x1000 }, 0x200);
    var table: File = .{};
    layout.table(&table, &.{
        .{ .tag = "dnom", .lookups = &.{2} },
        .{ .tag = "frac", .lookups = &.{0} },
        .{ .tag = "numr", .lookups = &.{1} },
    }, &.{
        .{ .kind = 1, .subtables = &.{whole.written()} },
        .{ .kind = 1, .subtables = &.{numerators.written()} },
        .{ .kind = 1, .subtables = &.{denominators.written()} },
    });
    const tables: harness.Tables = .{ .gsub = table.written() };
    const n = 0x100;
    const d = 0x200;
    const f = 0x1000;

    // The digits before the slash, the slash, the digits behind it; a
    // digit apart from them is as it was. The slash is three bytes.
    var run = shapeText(tables, "a1\u{2044}23 4", .{});
    try expectShaped(&run, &.{ 'a', '1' + n + f, 0x2044 + f, '2' + d + f, '3' + d + f, ' ', '4' }, &.{ 0, 1, 2, 5, 6, 7, 8 });
    // The plain slash makes none, nor does a fraction slash by itself.
    run = shapeText(tables, "1/2 \u{2044}", .{});
    try expectShaped(&run, &.{ '1', '/', '2', ' ', 0x2044 }, &.{ 0, 1, 2, 3, 4 });
    // One side alone is that side.
    run = shapeText(tables, "\u{2044}2", .{});
    try expectShaped(&run, &.{ 0x2044 + f, '2' + d + f }, &.{ 0, 3 });
    // Many fractions take no more bits than one.
    run = shapeText(tables, "1\u{2044}2 " ** 16, .{});
    try testing.expectEqual(tts.TTS_OK, run.result);
    try testing.expectEqual(@as(u32, 64), run.count);
    try testing.expectEqual(@as(u32, '2' + d + f), run.glyphs[62].glyph);
    // A caller's entry for the whole text is the caller's.
    run = shapeText(tables, "1\u{2044}2", .{ .features = &.{.{ .tag = tts.featureTag("frac"), .value = 0 }} });
    try expectShaped(&run, &.{ '1', 0x2044, '2' }, &.{ 0, 1, 4 });
}

test "more features with a part of the text than there are bits for" {
    var features: [32]tts.Feature = undefined;
    for (&features, 0..) |*feature, index| {
        feature.* = .{ .tag = tts.featureTag("ss01") + @as(u32, @intCast(index)), .first = 0, .last = 0 };
    }
    var run = shapeText(.{}, "ab", .{ .features = features[0..31] });
    try expectShaped(&run, &.{ 'a', 'b' }, &.{ 0, 1 });
    run = shapeText(.{}, "ab", .{ .features = &features });
    try testing.expectEqual(tts.TTSERR_FEATURES, run.result);
    try testing.expectEqual(@as(u32, 0xDEAD), run.count);
}

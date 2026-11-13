// SPDX-License-Identifier: MIT
//! Host tests of the forms a syllable's consonants take, on a `GSUB`
//! built in the test: a ra before the base, a ra behind it, a consonant
//! below the base and one behind it, half forms, the vowel sign that
//! starts a word, and the joiners between a consonant and the next.
//!
//! The table has a rule for each form, and the form is a glyph of its
//! own, so what a text became says which rule acted and where the glyph
//! went. The same rules are listed under the script's newer tag and
//! under its older one: under the older tag the first halant behind the
//! base is moved behind the syllable's last consonant, so a rule that
//! begins with that halant finds nothing, and the consonants keep their
//! glyphs with the halant behind them.
//!
//! The font of these tests has a glyph of each character's own number
//! (harness.zig). The glyphs and clusters expected are libharfbuzz's for
//! a font with these rules.

const std = @import("std");
const tts = @import("sdk").truetypeshaping;
const layout = @import("layout.zig");
const subtables = @import("subtables.zig");
const harness = @import("harness.zig");
const _scripts = @import("../shape/_scripts.zig");

const File = layout.File;
const testing = std.testing;

const KA = 0x915;
const TA = 0x924;
const NA = 0x928;
const YA = 0x92F;
const RA = 0x930;
const LA = 0x932;
const VA = 0x935;
const SIGN_I = 0x93F;
const HALANT = 0x94D;

// The forms: glyphs no text of these tests holds.
const REPH = 0x966;
const RA_BEHIND = 0x967;
const LA_BELOW = 0x968;
const VA_ABOVE = 0x969;
const KA_HALF = 0x96A;
const NA_HALF = 0x96B;
const YA_BEHIND = 0x96C;
const SIGN_I_FIRST = 0x96D;
const KA_YA = 0x96E;
const CIRCLE = 0x25CC;

/// A `GSUB` of the rules, under `DFLT` and under the script's tag `tag`.
fn rules(file: *File, tag: *const [4]u8) void {
    var reph: File = .{};
    subtables.ligature(&reph, &.{RA}, &.{&.{.{ .glyph = REPH, .rest = &.{HALANT} }}});
    var behind_ra: File = .{};
    subtables.ligature(&behind_ra, &.{HALANT}, &.{&.{.{ .glyph = RA_BEHIND, .rest = &.{RA} }}});
    var below: File = .{};
    subtables.ligature(&below, &.{HALANT}, &.{&.{.{ .glyph = LA_BELOW, .rest = &.{LA} }}});
    var above: File = .{};
    subtables.ligature(&above, &.{HALANT}, &.{&.{.{ .glyph = VA_ABOVE, .rest = &.{VA} }}});
    var half: File = .{};
    subtables.ligature(&half, &.{ KA, NA }, &.{
        &.{.{ .glyph = KA_HALF, .rest = &.{HALANT} }},
        &.{.{ .glyph = NA_HALF, .rest = &.{HALANT} }},
    });
    var behind: File = .{};
    subtables.ligature(&behind, &.{HALANT}, &.{&.{.{ .glyph = YA_BEHIND, .rest = &.{YA} }}});
    var first: File = .{};
    subtables.singleList(&first, &.{SIGN_I}, &.{SIGN_I_FIRST});
    var joined: File = .{};
    subtables.ligature(&joined, &.{KA_HALF}, &.{&.{.{ .glyph = KA_YA, .rest = &.{YA_BEHIND} }}});

    const features = [_]layout.Feature{
        .{ .tag = "abvf", .lookups = &.{3} },
        .{ .tag = "blwf", .lookups = &.{2} },
        .{ .tag = "half", .lookups = &.{4} },
        .{ .tag = "init", .lookups = &.{6} },
        .{ .tag = "pref", .lookups = &.{1} },
        .{ .tag = "pres", .lookups = &.{7} },
        .{ .tag = "pstf", .lookups = &.{5} },
        .{ .tag = "rphf", .lookups = &.{0} },
    };
    const lookups = [_]layout.Lookup{
        .{ .kind = 4, .subtables = &.{reph.written()} },
        .{ .kind = 4, .subtables = &.{behind_ra.written()} },
        .{ .kind = 4, .subtables = &.{below.written()} },
        .{ .kind = 4, .subtables = &.{above.written()} },
        .{ .kind = 4, .subtables = &.{half.written()} },
        .{ .kind = 4, .subtables = &.{behind.written()} },
        .{ .kind = 1, .subtables = &.{first.written()} },
        .{ .kind = 4, .subtables = &.{joined.written()} },
    };
    const all = [_]u16{ 0, 1, 2, 3, 4, 5, 6, 7 };
    layout.tableOf(file, &.{
        .{ .tag = "DFLT", .languages = &.{.{ .features = &all }} },
        .{ .tag = tag, .languages = &.{.{ .features = &all }} },
    }, &features, &lookups);
}

/// A text and what it becomes.
const Word = struct {
    text: []const u8,
    glyphs: []const u32,
    clusters: []const u32,
};

/// Each of `words` shaped by itself with the rules under `tag`. The
/// font lacks the letter "a".
fn expectWords(tag: *const [4]u8, words: []const Word) !void {
    var table: File = .{};
    rules(&table, tag);
    for (words) |word| {
        const run = harness.shapeText(.{ .gsub = table.written() }, word.text, .{ .glyphs = &.{.{ 'a', 0 }} });
        try testing.expectEqual(tts.TTS_OK, run.result);
        try run.expectGlyphs(word.glyphs);
        try run.expectClusters(word.clusters);
    }
}

test "the forms of a syllable's consonants, the script under its newer tag" {
    try expectWords("dev2", &.{
        // A ra before the base goes behind it.
        .{ .text = "\u{930}\u{94D}\u{915}", .glyphs = &.{ KA, REPH }, .clusters = &.{ 0, 0 } },
        // A ra behind the base goes before it.
        .{ .text = "\u{915}\u{94D}\u{930}", .glyphs = &.{ RA_BEHIND, KA }, .clusters = &.{ 0, 0 } },
        .{ .text = "\u{915}\u{94D}\u{932}", .glyphs = &.{ KA, LA_BELOW }, .clusters = &.{ 0, 3 } },
        .{ .text = "\u{924}\u{94D}\u{92F}\u{93F}", .glyphs = &.{ SIGN_I_FIRST, TA, YA_BEHIND }, .clusters = &.{ 0, 0, 0 } },
        .{ .text = "\u{915}\u{94D}\u{924}", .glyphs = &.{ KA_HALF, TA }, .clusters = &.{ 0, 6 } },
        .{ .text = "\u{928}\u{94D}\u{924}\u{93F}", .glyphs = &.{ SIGN_I_FIRST, NA_HALF, TA }, .clusters = &.{ 0, 0, 0 } },
        .{ .text = "\u{915}\u{93F}", .glyphs = &.{ SIGN_I_FIRST, KA }, .clusters = &.{ 0, 0 } },
        // The sign of a syllable within a word keeps its glyph.
        .{ .text = "\u{924}\u{915}\u{93F}", .glyphs = &.{ TA, SIGN_I, KA }, .clusters = &.{ 0, 3, 3 } },
        // A sign with no letter stands on the dotted circle.
        .{ .text = "a\u{93F}\u{915}", .glyphs = &.{ 0, SIGN_I, CIRCLE, KA }, .clusters = &.{ 0, 1, 1, 4 } },
        .{
            .text = "\u{930}\u{94D}\u{915}\u{94D}\u{92F}\u{93F}",
            .glyphs = &.{ SIGN_I_FIRST, KA, YA_BEHIND, REPH },
            .clusters = &.{ 0, 0, 0, 0 },
        },
        .{ .text = "\u{915}\u{94D}\u{930}\u{93F}", .glyphs = &.{ SIGN_I_FIRST, RA_BEHIND, KA }, .clusters = &.{ 0, 0, 0 } },
        .{ .text = "\u{915}\u{94D}\u{932}\u{94D}\u{92F}", .glyphs = &.{ KA, LA_BELOW, YA_BEHIND }, .clusters = &.{ 0, 3, 9 } },
        .{
            .text = "\u{924}\u{94D}\u{932}\u{94D}\u{930}\u{93F}",
            .glyphs = &.{ SIGN_I_FIRST, RA_BEHIND, TA, LA_BELOW },
            .clusters = &.{ 0, 0, 0, 0 },
        },
        // A joiner asks for the half form, a non-joiner for the halant.
        .{ .text = "\u{915}\u{94D}\u{200D}\u{924}", .glyphs = &.{ KA_HALF, TA }, .clusters = &.{ 0, 9 } },
        .{ .text = "\u{915}\u{94D}\u{200C}\u{924}", .glyphs = &.{ KA, HALANT, TA }, .clusters = &.{ 0, 3, 9 } },
    });
}

test "the script under its latest tag is shaped as under the newer one" {
    try expectWords("dev3", &.{
        .{ .text = "\u{930}\u{94D}\u{915}", .glyphs = &.{ KA, REPH }, .clusters = &.{ 0, 0 } },
        .{ .text = "\u{915}\u{94D}\u{930}", .glyphs = &.{ RA_BEHIND, KA }, .clusters = &.{ 0, 0 } },
        .{ .text = "\u{915}\u{94D}\u{924}", .glyphs = &.{ KA_HALF, TA }, .clusters = &.{ 0, 6 } },
        .{ .text = "\u{915}\u{93F}", .glyphs = &.{ SIGN_I_FIRST, KA }, .clusters = &.{ 0, 0 } },
    });
    try testing.expectEqual(tts.scriptTag("dev3"), _scripts.newest(tts.scriptTag("dev2")));
    try testing.expectEqual(@as(u32, 0), _scripts.newest(tts.scriptTag("deva")));
    try testing.expectEqual(@as(u32, 0), _scripts.newest(tts.scriptTag("latn")));
}

test "a sign without its letter stands on the font's dotted circle" {
    try expectWords("dev2", &.{
        // At a text's start the sign before the base takes its first form.
        .{ .text = "\u{93F}", .glyphs = &.{ SIGN_I_FIRST, CIRCLE }, .clusters = &.{ 0, 0 } },
        .{ .text = "\u{94D}\u{915}", .glyphs = &.{ CIRCLE, HALANT, KA }, .clusters = &.{ 0, 0, 3 } },
        // An accent of the Vedas with no letter around it is the script's.
        .{ .text = "\u{952}", .glyphs = &.{ CIRCLE, 0x952 }, .clusters = &.{ 0, 0 } },
        // A vowel letter and a sign that would make it another letter are
        // kept apart, and so are a ra with its halant and the letter i.
        .{ .text = "\u{909}\u{941}", .glyphs = &.{ 0x909, CIRCLE, 0x941 }, .clusters = &.{ 0, 3, 3 } },
        .{ .text = "\u{909}\u{93E}", .glyphs = &.{ 0x909, 0x93E }, .clusters = &.{ 0, 3 } },
    });
    // A font without the circle draws the text as it is written.
    var table: File = .{};
    rules(&table, "dev2");
    const run = harness.shapeText(.{ .gsub = table.written() }, "\u{93F}\u{915}\u{909}\u{941}", .{ .glyphs = &.{.{ CIRCLE, 0 }} });
    try testing.expectEqual(tts.TTS_OK, run.result);
    try run.expectGlyphs(&.{ SIGN_I_FIRST, KA, 0x909, 0x941 });
}

test "the forms of a syllable's consonants, the script under its older tag" {
    try expectWords("deva", &.{
        .{ .text = "\u{930}\u{94D}\u{915}", .glyphs = &.{ KA, REPH }, .clusters = &.{ 0, 0 } },
        // The halant went behind the last consonant: no rule finds it.
        .{ .text = "\u{915}\u{94D}\u{930}", .glyphs = &.{ KA, RA, HALANT }, .clusters = &.{ 0, 0, 0 } },
        .{ .text = "\u{915}\u{94D}\u{932}", .glyphs = &.{ KA, LA, HALANT }, .clusters = &.{ 0, 0, 0 } },
        .{
            .text = "\u{924}\u{94D}\u{92F}\u{93F}",
            .glyphs = &.{ SIGN_I_FIRST, TA, YA, HALANT },
            .clusters = &.{ 0, 0, 0, 0 },
        },
        .{ .text = "\u{915}\u{94D}\u{924}", .glyphs = &.{ KA_HALF, TA }, .clusters = &.{ 0, 6 } },
        .{ .text = "\u{928}\u{94D}\u{924}\u{93F}", .glyphs = &.{ SIGN_I_FIRST, NA_HALF, TA }, .clusters = &.{ 0, 0, 0 } },
        .{ .text = "\u{915}\u{93F}", .glyphs = &.{ SIGN_I_FIRST, KA }, .clusters = &.{ 0, 0 } },
        .{ .text = "\u{924}\u{915}\u{93F}", .glyphs = &.{ TA, SIGN_I, KA }, .clusters = &.{ 0, 3, 3 } },
        // A sign with no letter stands on the dotted circle.
        .{ .text = "a\u{93F}\u{915}", .glyphs = &.{ 0, SIGN_I, CIRCLE, KA }, .clusters = &.{ 0, 1, 1, 4 } },
        .{
            .text = "\u{930}\u{94D}\u{915}\u{94D}\u{92F}\u{93F}",
            .glyphs = &.{ SIGN_I_FIRST, KA, YA, HALANT, REPH },
            .clusters = &.{ 0, 0, 0, 0, 0 },
        },
        .{
            .text = "\u{915}\u{94D}\u{930}\u{93F}",
            .glyphs = &.{ SIGN_I_FIRST, KA, RA, HALANT },
            .clusters = &.{ 0, 0, 0, 0 },
        },
        // The second halant stands before the ya: its rule finds it.
        .{
            .text = "\u{915}\u{94D}\u{932}\u{94D}\u{92F}",
            .glyphs = &.{ KA, LA, YA_BEHIND, HALANT },
            .clusters = &.{ 0, 0, 0, 0 },
        },
        .{
            .text = "\u{924}\u{94D}\u{932}\u{94D}\u{930}\u{93F}",
            .glyphs = &.{ SIGN_I_FIRST, RA_BEHIND, TA, LA, HALANT },
            .clusters = &.{ 0, 0, 0, 0, 0 },
        },
        .{ .text = "\u{915}\u{94D}\u{200D}\u{924}", .glyphs = &.{ KA_HALF, TA }, .clusters = &.{ 0, 9 } },
        .{ .text = "\u{915}\u{94D}\u{200C}\u{924}", .glyphs = &.{ KA, HALANT, TA }, .clusters = &.{ 0, 0, 9 } },
    });
}

// SPDX-License-Identifier: MIT
//! Host tests of a text shaped with a font made of a rule, against what
//! HarfBuzz shapes the same text to with the same font.
//!
//! The font is the one of `harness.zig`: no tables, a glyph of its own
//! number for each character up to U+FFFF, an advance by the glyph's
//! number. A case says which characters its font lacks, so that the
//! same text is shaped with a font that has a character with its marks
//! as one, one that has the parts, and one that has neither - which is
//! what decides how a text is made the characters a font draws it
//! with: taken apart, its marks put in order, put together. The cases
//! are those `scripts/shape-text-reference.py` wrote down
//! (`text_reference/made.zig`): some chosen by hand, each named for
//! what it shows, and some drawn by lot.
//!
//! Every case that differs is printed, the glyphs shaped in one line and
//! those expected in the next, each as glyph/cluster/advance/right/up -
//! the form `scripts/shape-text-reference.py --show made` prints.

const std = @import("std");
const tts = @import("sdk").truetypeshaping;
const reference = @import("text_reference.zig");
const harness = @import("harness.zig");

const testing = std.testing;

/// Whether the text of `case`, shaped with its font, gives the glyphs
/// written down for it. One that does not is printed.
fn sameAsWritten(case: *const reference.Made) !bool {
    const run = harness.shapeText(.{}, case.text, .{
        .backward = case.backward,
        .em = case.em,
        .glyphs = case.characters,
        .variants = case.variants,
        .varied = true,
    });
    try testing.expectEqual(tts.TTS_OK, run.result);

    const shaped = run.glyphs[0..run.count];
    var same = shaped.len == case.glyphs.len;
    if (same) {
        for (shaped, case.glyphs) |glyph, written| {
            if (glyph.glyph == written[0] and glyph.cluster == written[1] and glyph.advance == written[2] and
                glyph.x_offset == written[3] and glyph.y_offset == written[4]) continue;
            same = false;
            break;
        }
    }
    if (same) return true;
    std.debug.print("\"{s}\" is shaped to\n ", .{case.name});
    for (shaped) |glyph| {
        std.debug.print(" {d}/{d}/{d}/{d}/{d}", .{ glyph.glyph, glyph.cluster, glyph.advance, glyph.x_offset, glyph.y_offset });
    }
    std.debug.print("\nand not to\n ", .{});
    for (case.glyphs) |written| {
        std.debug.print(" {d}/{d}/{d}/{d}/{d}", .{ written[0], written[1], written[2], written[3], written[4] });
    }
    std.debug.print("\n", .{});
    return false;
}

test "truetypeshaping: texts in a font made of a rule" {
    var differing: u32 = 0;
    for (reference.made) |*case| {
        if (!try sameAsWritten(case)) differing += 1;
    }
    if (differing != 0) return error.ShapedDiffers;
}

test "truetypeshaping: the made font's texts are there" {
    // Those chosen by hand and those drawn.
    try testing.expect(reference.made.len > 200);
    try testing.expectEqualStrings("a letter and a mark the font has as one", reference.made[0].name);
}

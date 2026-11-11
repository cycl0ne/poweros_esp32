// SPDX-License-Identifier: MIT
//! What the host tests expect of the layout tables of the fonts
//! `scripts/fetch-fonts.sh` fetches: the form of the values
//! `scripts/shape-reference.py` writes, the files it wrote, and the fonts
//! themselves read for a test.
//!
//! The script reads each font's `GDEF`, `GSUB` and `GPOS` with fontTools
//! and applies the lookups to runs of glyphs with an applier of its own,
//! written on fontTools' objects: nothing of it reads a table's bytes. A
//! test shapes the same runs with ShapeGlyphs and compares (`fonts.zig`),
//! so a table read wrongly shows as a run shaped differently. The files
//! are committed: the tests need the fonts, and neither Python nor
//! fontTools.
//!
//! The runs of a font are, in this order:
//!
//! - every glyph of the font, `every` to a run, in the order of their
//!   numbers (the last run has what is left);
//! - the runs the font's file writes out, a line each, a glyph four hex
//!   digits: sequences the font's lookups have rules for, ligatures with
//!   marks among their glyphs, marks on marks, and mixtures of them.
//!
//! Each glyph of a run goes in as its own cluster, numbered from 0.
//!
//! A case is a script, a language and a list of features, each of them
//! applied to the whole run, and a direction. Every run is shaped for
//! it, and the case is written as the SHA-256 of what came out: for each
//! run the number of its glyphs, then for each glyph its number, its
//! cluster, its advance and its two offsets, each as four bytes, the
//! lowest first. Beside it stands how many of the runs came out other
//! than they went in, so that a case that does nothing is seen as one.

const std = @import("std");
const fonts = @import("../../truetype/tests/reference.zig");

/// How many glyphs stand in a run of every glyph.
pub const every = 8;

/// One script, language, feature list and direction, and what the font's
/// runs are shaped to under it.
pub const Case = struct {
    /// The script's and the language's tags, each four characters, or
    /// empty for the default.
    script: []const u8,
    language: []const u8,
    /// The features' tags, four characters each, one after another.
    features: []const u8,
    /// Whether the run is laid out from right to left.
    backward: bool,
    /// How many runs come out other than they went in.
    changed: u32,
    /// All the runs shaped, hashed as the file's head says.
    sha256: []const u8,
};

/// One font's runs and cases.
pub const Font = struct {
    /// The file, under the directory the fonts are fetched into, and the
    /// SHA-256 it must have for the values here to be its.
    file: []const u8,
    sha256: []const u8,
    /// How many glyphs it has.
    glyph_count: u32,
    /// The runs written out, a line each.
    runs: []const u8,
    cases: []const Case,
};

pub const go_regular = &@import("reference/go_regular.zig").font;
pub const liberation_sans_regular = &@import("reference/liberation_sans_regular.zig").font;
pub const noto_sans_devanagari_regular = &@import("reference/noto_sans_devanagari_regular.zig").font;
pub const noto_color_emoji = &@import("reference/noto_color_emoji.zig").font;

/// Every font there are values for.
pub const all = [_]*const Font{
    go_regular,
    liberation_sans_regular,
    noto_sans_devanagari_regular,
    noto_color_emoji,
};

/// Numbers being hashed as the script hashes them.
pub const Digest = fonts.Digest;

/// A fetched font's bytes, for the caller to free with the testing
/// allocator.
///
/// `error.SkipZigTest` when the fonts are not fetched or this one is not
/// among them: the test that asked is skipped. `error.FontIsNotTheOnePinned`
/// when the file is not the one the values were read from - its pin was
/// changed and `scripts/shape-reference.py` not run again.
pub fn read(font: *const Font) ![]u8 {
    for (fonts.fonts) |known| {
        if (!std.mem.eql(u8, known.file, font.file)) continue;
        if (!std.mem.eql(u8, known.sha256, font.sha256)) return error.FontIsNotTheOnePinned;
        return fonts.read(known);
    }
    return error.NoSuchFont;
}

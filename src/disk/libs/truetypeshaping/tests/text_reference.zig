// SPDX-License-Identifier: MIT
//! What the host tests expect of texts shaped with the fonts
//! `scripts/fetch-fonts.sh` fetches: the form of the values
//! `scripts/shape-text-reference.py` writes, the files it wrote, and the
//! fonts themselves read for a test.
//!
//! The script hands each text to HarfBuzz, with the font and what the
//! case says of direction, language and features, and writes down the
//! glyphs that come out. A test shapes the same texts with ShapeText and
//! compares glyph by glyph (`text_fonts.zig`). The files are committed:
//! the tests need the fonts, and neither Python nor HarfBuzz.
//!
//! The texts are chosen among those the two shape by the same rules: of
//! one script each, without marks in a font that has outlines for them
//! and no table that places them, and without anything a script is
//! rearranged for. What the script's head says of it holds for a case
//! added.
//!
//! Besides the fetched fonts there is one made of a rule (`Made`), which
//! needs no file: a font is said by the characters it lacks, so that a
//! text is shaped with a font that has a character, its parts, or
//! neither (`text_made.zig`).

const std = @import("std");
const fonts = @import("../../truetype/tests/reference.zig");

/// A feature a case asks for besides the ones a text is shaped with.
pub const Feature = struct {
    /// Its tag, four characters.
    tag: []const u8,
    value: u32 = 1,
    /// The bytes of the text it holds for, the last one counted in.
    first: u32 = 0,
    last: u32 = 0xFFFF_FFFF,
};

/// One text and what it is shaped to.
pub const Case = struct {
    name: []const u8,
    /// The text, in UTF-8.
    text: []const u8,
    /// Whether it is read from right to left.
    backward: bool = false,
    /// The language's tag, four characters, or empty for the default.
    language: []const u8 = "",
    features: []const Feature = &.{},
    /// The glyphs as they are drawn, each as its number, its cluster, its
    /// advance and its offsets to the right and upward.
    glyphs: []const [5]i32,
};

/// One font's texts.
pub const Font = struct {
    /// The file, under the directory the fonts are fetched into, and the
    /// SHA-256 it must have for the values here to be its.
    file: []const u8,
    sha256: []const u8,
    cases: []const Case,
};

/// One text of a font made of a rule, and what it is shaped to.
///
/// The font has no tables. Each character up to U+FFFF has the glyph of
/// its own number, and no character beyond; a glyph's advance is 400 and
/// ten times what its number leaves over 37.
pub const Made = struct {
    name: []const u8,
    /// The text, in UTF-8.
    text: []const u8,
    /// Whether it is read from right to left.
    backward: bool = false,
    /// How many units an em has.
    em: u32 = 1000,
    /// The characters it is otherwise with: `.{ character, glyph }`, the
    /// glyph 0 for one the font lacks.
    characters: []const [2]u32 = &.{},
    /// A character and a selector the font has a glyph for:
    /// `.{ character, selector, glyph }`.
    variants: []const [3]u32 = &.{},
    /// The glyphs as they are drawn, each as its number, its cluster, its
    /// advance and its offsets to the right and upward.
    glyphs: []const [5]i32,
};

/// The made font's texts.
pub const made = @import("text_reference/made.zig").cases;

pub const go_regular = &@import("text_reference/go_regular.zig").font;
pub const liberation_sans_regular = &@import("text_reference/liberation_sans_regular.zig").font;
pub const noto_sans_devanagari_regular = &@import("text_reference/noto_sans_devanagari_regular.zig").font;
pub const noto_color_emoji = &@import("text_reference/noto_color_emoji.zig").font;

/// Every font there are texts for.
pub const all = [_]*const Font{
    go_regular,
    liberation_sans_regular,
    noto_sans_devanagari_regular,
    noto_color_emoji,
};

/// A fetched font's bytes, for the caller to free with the testing
/// allocator.
///
/// `error.SkipZigTest` when the fonts are not fetched or this one is not
/// among them: the test that asked is skipped. `error.FontIsNotTheOnePinned`
/// when the file is not the one the values were made with - its pin was
/// changed and `scripts/shape-text-reference.py` not run again.
pub fn read(font: *const Font) ![]u8 {
    for (fonts.fonts) |known| {
        if (!std.mem.eql(u8, known.file, font.file)) continue;
        if (!std.mem.eql(u8, known.sha256, font.sha256)) return error.FontIsNotTheOnePinned;
        return fonts.read(known);
    }
    return error.NoSuchFont;
}

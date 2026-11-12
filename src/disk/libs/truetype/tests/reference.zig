// SPDX-License-Identifier: MIT
//! What the host tests expect of the fonts `scripts/fetch-fonts.sh`
//! fetches: the form of the values `scripts/font-reference.py` writes, the
//! files it wrote, and the fonts themselves read for a test.
//!
//! The script reads each font with fontTools and writes what it finds as
//! a Zig file under `reference/`, headed by the font's file name and its
//! SHA-256. A test reads the same file with truetype.library and compares
//! (`fonts.zig`). The files are committed: the tests need the fonts, and
//! neither Python nor fontTools. A font of a collection has a file of its
//! own, which says the font's place in the collection.
//!
//! What a font's table says is fontTools' reading. How a glyph of cubic
//! curves looks rendered is libfreetype's: the glyph's outline in the
//! font's units, without hints, scaled to a line of so many rows from
//! the ascender to the descender and put where the library puts it, the
//! point at a pixel's left edge and the ascender at a row's top.
//!
//! A list too long to write out - every character of a map, every glyph's
//! measures - is written as how many entries it has and the SHA-256 of
//! them all, each entry its numbers as four bytes, the lowest first. The
//! test puts the library's answers together in the same order and hashes
//! them the same way, so a digest that differs is a reading that differs.
//! A few entries are written out beside it, and compared first: a
//! difference is then seen as a value.
//!
//! - A character map: (code, glyph) for every character with a glyph
//!   other than 0, by code.
//! - The variation sequences: (selector, code, glyph) for every sequence
//!   drawn with a glyph other than 0, by selector and then code; the
//!   glyph is the sequence's own, or the character's where the font says
//!   the sequence looks as the character does.
//! - The glyphs' measures: (advance, left side bearing, x min, y min,
//!   x max, y max) for every glyph, by its number - or for every
//!   `glyph_step`th, from glyph 0; a glyph of no outline has a box of 0,
//!   and one of cubic curves the box of its points, the control points
//!   among them.
//! - The outlines of a font of cubic curves: for each of the same glyphs
//!   how many verbs and how many points it has, then each verb's number -
//!   a move 0, a line 1, a curve 2, a close 3 - and its points' x and y.
//!   A contour of one point is none.

const std = @import("std");
const test_options = @import("test_options");

const testing = std.testing;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// A character and its glyph.
pub const Pair = struct {
    code: u32,
    glyph: u32,
};

/// One subtable of the character map, in the place the table lists it.
pub const Subtable = struct {
    platform: u16,
    encoding: u16,
    format: u16,
    /// Its characters, counted and hashed as a character map is. 0 and
    /// empty for the subtable of variation sequences (format 14), whose
    /// sequences are the font's `sequence_count` and `sequences_sha256`.
    count: u32,
    sha256: []const u8,
};

/// A character, the variation selector after it, and the glyph the two
/// are drawn with.
pub const Sequence = struct {
    selector: u32,
    code: u32,
    glyph: u32,
};

/// One of the font's names, by its number in the `name` table.
pub const Name = struct {
    id: u32,
    /// The name in UTF-8: its American English record of the Windows
    /// platform. Empty for a name the font gives in a Macintosh encoding
    /// only, which the library does not read.
    text: []const u8,
};

/// One entry of the font's table directory.
pub const Entry = struct {
    tag: *const [4]u8,
    /// Where the table starts in the file, and how long it is.
    at: u32,
    len: u32,
};

/// One glyph of cubic curves written out.
pub const Shape = struct {
    glyph: u32,
    /// A letter a verb: M a move, L a line, C a curve, Z a close.
    verbs: []const u8,
    /// The verbs' points in their order, x and y in the font's units: one
    /// of a move or a line, three of a curve.
    points: []const [2]i32,
};

/// One glyph as libfreetype renders it for a line `picture_rows` tall.
pub const Picture = struct {
    glyph: u32,
    /// Where its box of ink is: pixels right of the point, and rows below
    /// the line's top.
    left: i32,
    top: i32,
    width: u32,
    /// The box row by row from the top, a hex digit a pixel: its coverage
    /// in fifteenths, rounded.
    rows: []const []const u8,
};

/// One font, as fontTools reads it.
pub const Font = struct {
    /// The file, under the directory the fonts are fetched into, and what
    /// it must be for the values here to be its: its SHA-256 and length.
    file: []const u8,
    sha256: []const u8,
    size: u32,
    /// Which font of the file it is, how many the file holds, and where
    /// in the file this one's table directory is.
    index: u32,
    font_count: u32,
    directory: u32,
    /// Whether it has `glyf` and `loca`: glyphs of lines and curves.
    outlines: bool,
    /// Whether it has `CFF ` instead: glyphs of lines and cubic curves.
    cubic: bool,
    /// Every which glyph's measures and outline are hashed: 1 for all.
    glyph_step: u32,
    /// `maxp`, `head` and `hhea`.
    glyph_count: u32,
    units_per_em: u32,
    ascender: i32,
    descender: i32,
    line_gap: i32,
    /// `OS/2`: the heights from its version 2 on, 0 before that.
    x_height: i32,
    cap_height: i32,
    /// `post`.
    underline_position: i32,
    underline_thickness: i32,
    /// `OS/2`.
    strikeout_position: i32,
    strikeout_thickness: i32,
    /// `head`'s style bits.
    bold: bool,
    italic: bool,
    /// The glyphs' measures, hashed: of every `glyph_step`th glyph.
    metrics_sha256: []const u8,
    /// The same glyphs' outlines, hashed, and a few written out; empty
    /// for a font that is not of cubic curves.
    outlines_sha256: []const u8,
    shapes: []const Shape,
    /// libfreetype's rendering for a line `ink_rows` tall: the sum of the
    /// coverage of all pixels, each 0 to 255, of glyph 0, `ink_step`,
    /// twice that and so on. Empty for a font not rendered.
    ink_rows: u32,
    ink_step: u32,
    inks: []const u32,
    /// A few glyphs pixel by pixel, for a line `picture_rows` tall.
    picture_rows: u32,
    pictures: []const Picture,
    /// The table directory, in the file's order.
    tables: []const Entry,
    /// The character map's subtables, in the table's order.
    subtables: []const Subtable,
    /// The map fontTools reads characters by, counted and hashed, and a
    /// few of its characters.
    best_count: u32,
    best_sha256: []const u8,
    pairs: []const Pair,
    /// The variation selectors the font has sequences for, in order; the
    /// sequences counted and hashed, and a few of them.
    selectors: []const u32,
    sequence_count: u32,
    sequences_sha256: []const u8,
    sequences: []const Sequence,
    /// Every name the `name` table has a record of, by its number.
    names: []const Name,
};

pub const go_regular = &@import("reference/go_regular.zig").font;
pub const liberation_sans_regular = &@import("reference/liberation_sans_regular.zig").font;
pub const noto_sans_devanagari_regular = &@import("reference/noto_sans_devanagari_regular.zig").font;
pub const noto_color_emoji = &@import("reference/noto_color_emoji.zig").font;
pub const source_sans_3_regular = &@import("reference/source_sans_3_regular.zig").font;
pub const noto_sans_cjk_jp_regular = &@import("reference/noto_sans_cjk_jp_regular.zig").font;
pub const noto_sans_cjk_sc_regular = &@import("reference/noto_sans_cjk_sc_regular.zig").font;

/// Every font there are values for.
pub const fonts = [_]*const Font{
    go_regular,
    liberation_sans_regular,
    noto_sans_devanagari_regular,
    noto_color_emoji,
    source_sans_3_regular,
    noto_sans_cjk_jp_regular,
    noto_sans_cjk_sc_regular,
};

/// Numbers being hashed as the script hashes them.
pub const Digest = struct {
    sha: Sha256 = Sha256.init(.{}),

    /// One number of an entry: four bytes, the lowest first.
    pub fn add(digest: *Digest, value: u32) void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        digest.sha.update(&bytes);
    }

    /// The same of a signed one.
    pub fn addSigned(digest: *Digest, value: i32) void {
        digest.add(@bitCast(value));
    }

    /// The digest of what was added, in hex as the files have it.
    pub fn hex(digest: *Digest) [Sha256.digest_length * 2]u8 {
        return std.fmt.bytesToHex(digest.sha.finalResult(), .lower);
    }
};

/// The SHA-256 of `bytes`, in hex.
pub fn sha256Of(bytes: []const u8) [Sha256.digest_length * 2]u8 {
    var sum: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &sum, .{});
    return std.fmt.bytesToHex(sum, .lower);
}

/// A fetched font's bytes, for the caller to free with the testing
/// allocator.
///
/// `error.SkipZigTest` when the fonts are not fetched or this one is not
/// among them: the test that asked is skipped. `error.FontIsNotTheOnePinned`
/// when the file is not the one the values were read from - its pin was
/// changed and `scripts/font-reference.py` not run again.
pub fn read(font: *const Font) ![]u8 {
    if (test_options.fonts_dir.len == 0) return error.SkipZigTest;
    var path_buffer: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ test_options.fonts_dir, font.file });
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    errdefer testing.allocator.free(bytes);
    if (bytes.len != font.size or !std.mem.eql(u8, &sha256Of(bytes), font.sha256)) return error.FontIsNotTheOnePinned;
    return bytes;
}

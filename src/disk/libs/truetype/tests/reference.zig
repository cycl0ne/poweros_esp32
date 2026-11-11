// SPDX-License-Identifier: MIT
//! What the host tests expect of the fonts `scripts/fetch-fonts.sh`
//! fetches: the form of the values `scripts/font-reference.py` writes, the
//! files it wrote, and the fonts themselves read for a test.
//!
//! The script reads each font with fontTools and writes what it finds as
//! a Zig file under `reference/`, headed by the font's file name and its
//! SHA-256. A test reads the same file with truetype.library and compares
//! (`fonts.zig`). The files are committed: the tests need the fonts, and
//! neither Python nor fontTools.
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
//!   x max, y max) for every glyph, by its number; a glyph of no outline
//!   has a box of 0.

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

/// One font, as fontTools reads it.
pub const Font = struct {
    /// The file, under the directory the fonts are fetched into, and what
    /// it must be for the values here to be its: its SHA-256 and length.
    file: []const u8,
    sha256: []const u8,
    size: u32,
    /// Whether it has `glyf` and `loca`: glyphs of lines and curves.
    outlines: bool,
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
    /// Every glyph's measures, hashed; there are `glyph_count` of them.
    metrics_sha256: []const u8,
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

/// Every font there are values for.
pub const fonts = [_]*const Font{
    go_regular,
    liberation_sans_regular,
    noto_sans_devanagari_regular,
    noto_color_emoji,
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

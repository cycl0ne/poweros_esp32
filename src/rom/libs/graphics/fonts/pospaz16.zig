// SPDX-License-Identifier: MPL-2.0
//! The system font at 8 by 16: the 8 by 8 font with every row drawn
//! twice, made by the compiler from `pospaz8.zig`.
//!
//! 8 pixels wide and 16 tall, with the baseline 13 rows down - the size
//! for a panel whose pixels are square, where the 8 by 8 font reads as
//! half height. Being made from the other, the two never disagree about a
//! glyph: a fix to one is a fix to both.
//!
//! The same characters as `pospaz8.zig`, and the same box for anything
//! else.

const eight = @import("pospaz8.zig");

pub const FONT_HEIGHT = 16;

/// A glyph: the character it is for, and its rows.
pub const Glyph = struct {
    code: u32,
    rows: [FONT_HEIGHT]u16,
};

/// The glyphs, sorted by code.
pub const glyphs: [eight.glyphs.len]Glyph = blk: {
    @setEvalBranchQuota(10_000);
    var doubled: [eight.glyphs.len]Glyph = undefined;
    for (eight.glyphs, 0..) |glyph, index| doubled[index] = .{ .code = glyph.code, .rows = twice(glyph.rows) };
    break :blk doubled;
};

/// What stands in for a character the font has no glyph for.
pub const missing = twice(eight.missing);

/// The 8 rows of `rows`, each drawn twice.
fn twice(rows: [eight.FONT_HEIGHT]u16) [FONT_HEIGHT]u16 {
    var doubled: [FONT_HEIGHT]u16 = undefined;
    for (rows, 0..) |row, at| {
        doubled[2 * at] = row;
        doubled[2 * at + 1] = row;
    }
    return doubled;
}

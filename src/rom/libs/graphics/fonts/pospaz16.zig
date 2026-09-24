// SPDX-License-Identifier: MPL-2.0
//! The system font at 8 by 16: the 8 by 8 font with every row drawn
//! twice, made by the compiler from `pospaz8.zig`.
//!
//! 8 pixels wide and 16 tall, with the baseline 13 rows down - the size
//! for a panel whose pixels are square, where the 8 by 8 font reads as
//! half height. Being made from the other, the two never disagree about a
//! glyph: a fix to one is a fix to both.
//!
//! Characters 32 to 255, and one more at the end that stands in for
//! anything outside that, as in `pospaz8.zig`.

const eight = @import("pospaz8.zig");

pub const FONT_HEIGHT = 16;

pub const font_data: [eight.font_data.len][FONT_HEIGHT]u16 = blk: {
    @setEvalBranchQuota(10_000);
    var doubled: [eight.font_data.len][FONT_HEIGHT]u16 = undefined;
    for (eight.font_data, 0..) |glyph, index| {
        for (glyph, 0..) |row, at| {
            doubled[index][2 * at] = row;
            doubled[index][2 * at + 1] = row;
        }
    }
    break :blk doubled;
};

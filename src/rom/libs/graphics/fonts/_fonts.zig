// SPDX-License-Identifier: MPL-2.0
//! The fonts in this ROM, as images.
//!
//! `pospaz8.zig` and `pospaz16.zig` keep the glyphs as they are drawn,
//! a `u16` a row with a picture above each, which is the form a wrong bit
//! can be seen in. The library draws from `FontImage`s, so each is made
//! into one here, at compile time: every glyph's box cropped to its ink,
//! its rows a byte or two each, codes 32 to 255 and the stand-in as 256,
//! which is also the default character.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;

const pospaz8 = @import("pospaz8.zig");
const pospaz16 = @import("pospaz16.zig");

/// Pospaz at 8 rows: 8 wide, the baseline 6 down.
pub const pospaz8_image: [fontimage.imageSize(specOf(8, 6, &pospaz8.font_data))]u8 align(4) =
    fontimage.build(specOf(8, 6, &pospaz8.font_data));

/// Pospaz at 16 rows: the 8 with every row twice, the baseline 13 down.
pub const pospaz16_image: [fontimage.imageSize(specOf(16, 13, &pospaz16.font_data))]u8 align(4) =
    fontimage.build(specOf(16, 13, &pospaz16.font_data));

/// The first code the glyphs are for.
const first_code = 32;

/// A font of `glyphs` rows `height` tall, a u16 each, as `build` takes it.
fn specOf(comptime height: u16, comptime baseline: u16, comptime glyphs: []const [height]u16) fontimage.Spec {
    @setEvalBranchQuota(1_000_000);
    var specs: [glyphs.len]fontimage.GlyphSpec = undefined;
    for (glyphs, 0..) |rows, i| specs[i] = cropped(height, rows, first_code + i);
    const done = specs;
    return .{
        .height = height,
        .baseline = baseline,
        .x_size = 8,
        .flags = graphics.FPF_DESIGNED,
        .default_char = first_code + glyphs.len - 1,
        .glyphs = &done,
    };
}

/// One glyph's rows cut down to the box its ink fills.
fn cropped(comptime height: u16, comptime rows: [height]u16, comptime code: u32) fontimage.GlyphSpec {
    var ink: u16 = 0;
    var top: u16 = height;
    var bottom: u16 = 0;
    for (rows, 0..) |bits, row| {
        ink |= bits;
        if (bits != 0) {
            if (row < top) top = row;
            bottom = row + 1;
        }
    }
    if (ink == 0) return .{ .code = code, .advance = 8 };
    const left: u16 = @clz(ink);
    const width: u16 = 16 - left - @ctz(ink);
    const pitch = fontimage.pitchOf(.mono1, width);
    var pixels: [(bottom - top) * pitch]u8 = @splat(0);
    for (top..bottom) |row| {
        const bits: u16 = rows[row] << @intCast(left);
        for (0..pitch) |b| pixels[(row - top) * pitch + b] = @truncate(bits >> @intCast(8 - 8 * b));
    }
    const done = pixels;
    return .{
        .code = code,
        .advance = 8,
        .left = @intCast(left),
        .top = @intCast(top),
        .width = width,
        .rows = bottom - top,
        .pixels = &done,
    };
}

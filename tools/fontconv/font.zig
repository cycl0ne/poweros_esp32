// SPDX-License-Identifier: MPL-2.0
//! A font as fontconv holds it between reading and writing, and what is
//! done to it on the way: cropping, coverage from a larger drawing, a
//! shadow, and the image it becomes.
//!
//! Every pixel here is a byte - 0 or 1 for ink, 0 to 15 for coverage, a
//! palette index for colour - so reading, cropping and turning one kind
//! into another never deal in bits. Only `encode` packs them into the
//! kind's own form.

const std = @import("std");
const sdk = @import("sdk");
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const Allocator = std.mem.Allocator;

/// One character: its box, where the box sits, and its pixels, a byte
/// each, `rows` rows of `width`.
pub const Glyph = struct {
    code: u32,
    advance: i32,
    /// Columns from the point to the box.
    left: i32 = 0,
    /// Rows from the top of the line to the box.
    top: i32 = 0,
    width: u32 = 0,
    rows: u32 = 0,
    pixels: []u8 = &.{},

    fn at(glyph: *const Glyph, x: i32, y: i32) u8 {
        if (x < 0 or y < 0 or x >= glyph.width or y >= glyph.rows) return 0;
        return glyph.pixels[@as(usize, @intCast(y)) * glyph.width + @as(usize, @intCast(x))];
    }
};

/// A font of one size.
pub const Font = struct {
    height: u32,
    baseline: u32,
    x_size: u32,
    style: graphics.FontStyle = graphics.FS_NORMAL,
    flags: graphics.FontFlags = graphics.FPF_DESIGNED,
    kind: fontimage.Kind = .mono1,
    bold_smear: u8 = 1,
    default_char: u32,
    palette: []const u32 = &.{},
    pen_index: u32 = fontimage.NO_PEN,
    /// Sorted by code, no code twice.
    glyphs: []Glyph,
};

/// Sort the glyphs by code and cut each box down to its ink.
///
/// INPUTS:
/// - `font` - the font, changed in place.
pub fn tidy(font: *Font) void {
    std.mem.sort(Glyph, font.glyphs, {}, struct {
        fn less(_: void, a: Glyph, b: Glyph) bool {
            return a.code < b.code;
        }
    }.less);
    for (font.glyphs) |*glyph| crop(glyph);
}

/// A glyph's box cut down to the pixels that are not 0.
fn crop(glyph: *Glyph) void {
    var min_x: u32 = glyph.width;
    var max_x: u32 = 0;
    var min_y: u32 = glyph.rows;
    var max_y: u32 = 0;
    for (0..glyph.rows) |y| for (0..glyph.width) |x| {
        if (glyph.pixels[y * glyph.width + x] == 0) continue;
        min_x = @min(min_x, @as(u32, @intCast(x)));
        max_x = @max(max_x, @as(u32, @intCast(x)) + 1);
        min_y = @min(min_y, @as(u32, @intCast(y)));
        max_y = @max(max_y, @as(u32, @intCast(y)) + 1);
    };
    if (max_x == 0) {
        glyph.width = 0;
        glyph.rows = 0;
        glyph.pixels = glyph.pixels[0..0];
        return;
    }
    const width = max_x - min_x;
    const rows = max_y - min_y;
    // In place: every row moves up and left, never past one not yet read.
    for (0..rows) |y| for (0..width) |x| {
        glyph.pixels[y * width + x] = glyph.pixels[(y + min_y) * glyph.width + x + min_x];
    };
    glyph.left += @intCast(min_x);
    glyph.top += @intCast(min_y);
    glyph.width = width;
    glyph.rows = rows;
    glyph.pixels = glyph.pixels[0 .. width * rows];
}

/// Whether the advances differ, so the font is proportional.
fn proportional(font: *const Font) bool {
    for (font.glyphs) |glyph| {
        if (glyph.code == font.default_char) continue;
        if (glyph.advance != font.x_size) return true;
    }
    return false;
}

/// The image of `font`, allocated from `gpa`: what a size file holds.
/// The glyphs must be tidy.
///
/// INPUTS:
/// - `gpa` - where the image is allocated.
/// - `font` - the font.
pub fn encode(gpa: Allocator, font: *const Font) ![]align(4) u8 {
    var range_count: u32 = 0;
    var data_size: u32 = 0;
    for (font.glyphs, 0..) |glyph, i| {
        if (i == 0 or glyph.code != font.glyphs[i - 1].code + 1) range_count += 1;
        data_size += fontimage.pitchOf(font.kind, glyph.width) * glyph.rows;
    }
    const ranges_at: u32 = @sizeOf(fontimage.FontImage);
    const glyphs_at = ranges_at + range_count * @sizeOf(fontimage.Range);
    const palette_at = glyphs_at + @as(u32, @intCast(font.glyphs.len)) * @sizeOf(fontimage.Glyph);
    const data_at = palette_at + @as(u32, @intCast(font.palette.len)) * 4;
    const size = data_at + ((data_size + 3) & ~@as(u32, 3));

    const out = try gpa.alignedAlloc(u8, .@"4", size);
    @memset(out, 0);
    const ranges: [*]fontimage.Range = @ptrCast(@alignCast(out.ptr + ranges_at));
    const glyphs: [*]fontimage.Glyph = @ptrCast(@alignCast(out.ptr + glyphs_at));
    const palette: [*]u32 = @ptrCast(@alignCast(out.ptr + palette_at));

    var max_width: u32 = 0;
    var range_index: u32 = 0;
    var data: u32 = 0;
    for (font.glyphs, 0..) |glyph, i| {
        if (i == 0 or glyph.code != font.glyphs[i - 1].code + 1) {
            ranges[range_index] = .{ .first = glyph.code, .last = glyph.code, .glyph = @intCast(i) };
            range_index += 1;
        } else {
            ranges[range_index - 1].last = glyph.code;
        }
        const pitch = fontimage.pitchOf(font.kind, glyph.width);
        glyphs[i] = .{
            .data = data,
            .width = @intCast(glyph.width),
            .rows = @intCast(glyph.rows),
            .top = @intCast(glyph.top),
            .left = @intCast(glyph.left),
            .advance = @intCast(glyph.advance),
            .pitch = @intCast(pitch),
        };
        pack(font.kind, glyph, out[data_at + data ..][0 .. pitch * glyph.rows], pitch);
        data += pitch * glyph.rows;
        max_width = @max(max_width, glyph.width);
    }
    for (font.palette, 0..) |entry, i| palette[i] = entry;

    const header: *fontimage.FontImage = @ptrCast(out.ptr);
    header.* = .{
        .size = size,
        .height = @intCast(font.height),
        .baseline = @intCast(font.baseline),
        .x_size = @intCast(font.x_size),
        .max_width = @intCast(max_width),
        .style = font.style,
        .flags = font.flags | if (proportional(font)) graphics.FPF_PROPORTIONAL else 0,
        .kind = font.kind,
        .bold_smear = font.bold_smear,
        .default_char = font.default_char,
        .range_count = range_count,
        .ranges = ranges_at,
        .glyph_count = @intCast(font.glyphs.len),
        .glyphs = glyphs_at,
        .palette_count = @intCast(font.palette.len),
        .palette = if (font.palette.len != 0) palette_at else 0,
        .pen_index = font.pen_index,
        .data_size = data_size,
        .data = data_at,
    };
    header.checksum = fontimage.checksumOf(out.ptr, size);
    return out;
}

/// A glyph's pixels into the kind's own form.
fn pack(kind: fontimage.Kind, glyph: Glyph, out: []u8, pitch: u32) void {
    for (0..glyph.rows) |y| for (0..glyph.width) |x| {
        const value = glyph.pixels[y * glyph.width + x];
        const row = out[y * pitch ..];
        switch (kind) {
            .mono1 => if (value != 0) {
                row[x / 8] |= @as(u8, 0x80) >> @intCast(x % 8);
            },
            .alpha4 => row[x / 2] |= if (x % 2 == 0) value << 4 else value & 0x0F,
            else => row[x] = value,
        }
    };
}

/// The font `source`, drawn `factor` times as large, made into one of
/// coverage at its own size: each pixel the share of its `factor` by
/// `factor` square that is ink, in fifteenths.
///
/// INPUTS:
/// - `gpa` - where the new glyphs are allocated.
/// - `source` - a font of ink, tidy.
/// - `factor` - how much larger it is drawn: 2 or 4.
pub fn coverage(gpa: Allocator, source: *const Font, factor: u32) !Font {
    const glyphs = try gpa.alloc(Glyph, source.glyphs.len);
    const f: i32 = @intCast(factor);
    for (source.glyphs, glyphs) |from, *to| {
        const left = @divFloor(from.left, f);
        const top = @divFloor(from.top, f);
        const right = @divFloor(from.left + @as(i32, @intCast(from.width)) + f - 1, f);
        const bottom = @divFloor(from.top + @as(i32, @intCast(from.rows)) + f - 1, f);
        const width: u32 = @intCast(right - left);
        const rows: u32 = @intCast(bottom - top);
        const pixels = try gpa.alloc(u8, width * rows);
        for (0..rows) |y| for (0..width) |x| {
            var lit: u32 = 0;
            for (0..factor) |sy| for (0..factor) |sx| {
                const px = (left + @as(i32, @intCast(x))) * f + @as(i32, @intCast(sx)) - from.left;
                const py = (top + @as(i32, @intCast(y))) * f + @as(i32, @intCast(sy)) - from.top;
                if (from.at(px, py) != 0) lit += 1;
            };
            pixels[y * width + x] = @intCast((lit * 15 + factor * factor / 2) / (factor * factor));
        };
        to.* = .{
            .code = from.code,
            .advance = @divFloor(from.advance + @divFloor(f, 2), f),
            .left = left,
            .top = top,
            .width = width,
            .rows = rows,
            .pixels = pixels,
        };
    }
    var font = source.*;
    font.glyphs = glyphs;
    font.kind = .alpha4;
    font.height = (source.height + factor / 2) / factor;
    font.baseline = (source.baseline + factor / 2) / factor;
    font.x_size = (source.x_size + factor / 2) / factor;
    tidy(&font);
    return font;
}

/// The palette of a shadowed font: nothing, the pen, and black at half
/// strength.
pub const shadow_palette = [_]u32{ 0x0000_0000, 0xFFFF_FFFF, 0x8000_0000 };

/// The font `source` with a shadow one pixel down and right of every
/// letter, as a colour font: the letter in the pen, the shadow a
/// translucent black that darkens whatever it falls on.
///
/// INPUTS:
/// - `gpa` - where the new glyphs are allocated.
/// - `source` - a font of ink, tidy.
pub fn shadowed(gpa: Allocator, source: *const Font) !Font {
    const glyphs = try gpa.alloc(Glyph, source.glyphs.len);
    for (source.glyphs, glyphs) |from, *to| {
        const width = if (from.width == 0) 0 else from.width + 1;
        const rows = if (from.rows == 0) 0 else from.rows + 1;
        const pixels = try gpa.alloc(u8, width * rows);
        for (0..rows) |y| for (0..width) |x| {
            const xi: i32 = @intCast(x);
            const yi: i32 = @intCast(y);
            pixels[y * width + x] = if (from.at(xi, yi) != 0) 1 else if (from.at(xi - 1, yi - 1) != 0) 2 else 0;
        };
        to.* = from;
        to.width = width;
        to.rows = rows;
        to.pixels = pixels;
    }
    var font = source.*;
    font.glyphs = glyphs;
    font.kind = .indexed8;
    font.palette = &shadow_palette;
    font.pen_index = 1;
    // The shadow of the lowest row falls one row below it.
    font.height = source.height + 1;
    return font;
}

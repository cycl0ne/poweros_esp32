// SPDX-License-Identifier: MIT
//! NewScaledDiskFont: a font of another height, made from one there is.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const TextFont = graphics.TextFont;
const TextAttr = graphics.TextAttr;
const FontImage = fontimage.FontImage;
const Glyph = fontimage.Glyph;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const _font = @import("_font.zig");

/// A font of another height, made from one there is.
///
/// SYNOPSIS:
/// ```zig
/// fn NewScaledDiskFont(dfb: *DiskfontBase, font: *TextFont, text_attr: *const TextAttr) ?*TextFont
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `font` - the font to scale from: any kind, ink, coverage or colour.
/// - `text_attr` - the height wanted (`y_size`); the rest is not used.
///
/// RESULT:
/// The new font, on no list and open to nobody, or null for a height of
/// 0 or no memory.
///
/// BEHAVIOR:
/// Every glyph is scaled by the ratio of the heights, across as much as
/// down, so a fixed-width font stays fixed-width and letters keep their
/// shape. Each pixel of the new glyph takes the value of the pixel of the
/// old one under its middle - nearest, not blended, so ink stays ink,
/// coverage keeps its steps and a colour font's pixels stay palette
/// entries. The boxes, the advances, the width and the baseline scale
/// with them, rounded. Glyphs several characters share are scaled once.
///
/// The new font has the old one's name, styles and palette, and is not
/// `FPF_DESIGNED`: it was made, not drawn.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's: one allocation, freed with `FreeVec(font)` - after
/// `RemFont` if the caller put it on graphics' list with `AddFont`.
/// `font` is only read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenDiskFont`, `graphics.library/AddFont`
///
/// EXAMPLES:
/// ```zig
/// const big = dfb.NewScaledDiskFont(font, &.{ .name = "", .y_size = 48 }) orelse return;
/// defer sys.FreeVec(big);
/// ```
pub fn NewScaledDiskFont(dfb: *DiskfontBase, font: *TextFont, text_attr: *const TextAttr) ?*TextFont {
    const from = font.image;
    const to_height: i32 = text_attr.y_size;
    const from_height: i32 = from.height;
    if (to_height == 0) return null;
    const scale = Scale{ .to = to_height, .from = from_height };

    const from_glyphs = fontimage.glyphsOf(from);
    const ranges = fontimage.rangesOf(from);
    const palette = fontimage.paletteOf(from);

    // The layout, and each glyph's new box, in a first pass.
    var data: u32 = 0;
    for (from_glyphs, 0..) |*glyph, i| {
        if (sharedWith(from_glyphs, i) == null) data += pitchedSize(from.kind, scale.box(glyph));
    }
    const ranges_at: u32 = @sizeOf(FontImage);
    const glyphs_at = ranges_at + @as(u32, @intCast(ranges.len)) * @sizeOf(fontimage.Range);
    const palette_at = glyphs_at + @as(u32, @intCast(from_glyphs.len)) * @sizeOf(Glyph);
    const data_at = palette_at + @as(u32, @intCast(palette.len)) * 4;
    const size = data_at + ((data + 3) & ~@as(u32, 3));

    const record = _font.newRecord(dfb, font.node.name orelse "", size) orelse return null;
    const block = _font.imageArea(record);
    @memset(block[0..size], 0);
    const out_ranges: [*]fontimage.Range = @ptrCast(@alignCast(block + ranges_at));
    const out_glyphs: [*]Glyph = @ptrCast(@alignCast(block + glyphs_at));
    const out_palette: [*]u32 = @ptrCast(@alignCast(block + palette_at));
    for (ranges, 0..) |range, i| out_ranges[i] = range;
    for (palette, 0..) |entry, i| out_palette[i] = entry;

    var at: u32 = 0;
    var max_width: u16 = 0;
    for (from_glyphs, 0..) |*glyph, i| {
        const box = scale.box(glyph);
        const pitch = fontimage.pitchOf(from.kind, box.width);
        out_glyphs[i] = .{
            .width = @intCast(box.width),
            .rows = @intCast(box.rows),
            .top = @intCast(box.top),
            .left = @intCast(box.left),
            .advance = @intCast(scale.of(glyph.advance)),
            .pitch = @intCast(pitch),
        };
        max_width = @max(max_width, out_glyphs[i].width);
        if (sharedWith(from_glyphs, i)) |first| {
            out_glyphs[i].data = out_glyphs[first].data;
            continue;
        }
        out_glyphs[i].data = at;
        const source = fontimage.pixelsOf(from, glyph);
        const dest = block + data_at + at;
        for (0..box.rows) |y| for (0..box.width) |x| {
            const sx = scale.back(box.left + @as(i32, @intCast(x)), glyph.left, glyph.width);
            const sy = scale.back(box.top + @as(i32, @intCast(y)), glyph.top, glyph.rows);
            const value = get(from.kind, source + sy * glyph.pitch, sx);
            put(from.kind, dest + y * pitch, @intCast(x), value);
        };
        at += pitch * box.rows;
    }

    const header: *FontImage = @ptrCast(block);
    header.* = from.*;
    header.header_size = @sizeOf(FontImage);
    header.size = size;
    header.height = @intCast(to_height);
    header.baseline = @intCast(scale.of(from.baseline));
    header.x_size = @intCast(@max(scale.of(from.x_size), 1));
    header.max_width = max_width;
    header.flags = from.flags & ~graphics.FPF_DESIGNED;
    header.ranges = ranges_at;
    header.glyphs = glyphs_at;
    header.palette = if (palette.len != 0) palette_at else 0;
    header.data_size = data;
    header.data = data_at;
    header.checksum = 0;
    header.checksum = fontimage.checksumOf(block, size);
    return &record.font;
}

/// The ratio of two heights, and positions put through it.
const Scale = struct {
    to: i32,
    from: i32,

    /// A position or length scaled, rounded to the nearest.
    fn of(scale: Scale, value: i32) i32 {
        return @divFloor(2 * value * scale.to + scale.from, 2 * scale.from);
    }

    /// The pixel of the old box under the middle of new pixel `at`, whose
    /// box starts at `start` and is `span` long.
    fn back(scale: Scale, at: i32, start: i32, span: u32) u32 {
        const from = @divFloor((2 * at + 1) * scale.from, 2 * scale.to) - start;
        return @intCast(@min(@max(from, 0), @as(i32, @intCast(span)) - 1));
    }

    /// A glyph's box scaled: its edges scaled, at least a pixel each way
    /// for a glyph that has ink.
    fn box(scale: Scale, glyph: *const Glyph) Box {
        if (glyph.width == 0 or glyph.rows == 0) return .{};
        const left = scale.of(glyph.left);
        const top = scale.of(glyph.top);
        const right = @max(scale.of(@as(i32, glyph.left) + glyph.width), left + 1);
        const bottom = @max(scale.of(@as(i32, glyph.top) + glyph.rows), top + 1);
        return .{ .left = left, .top = top, .width = @intCast(right - left), .rows = @intCast(bottom - top) };
    }
};

const Box = struct {
    left: i32 = 0,
    top: i32 = 0,
    width: u32 = 0,
    rows: u32 = 0,
};

fn pitchedSize(kind: fontimage.Kind, box: Box) u32 {
    return fontimage.pitchOf(kind, box.width) * box.rows;
}

/// The first glyph before `i` whose pixels `i` shares, if any.
fn sharedWith(glyphs: []const Glyph, i: usize) ?usize {
    const glyph = glyphs[i];
    if (glyph.width == 0) return null;
    for (glyphs[0..i], 0..) |earlier, j| {
        if (earlier.data == glyph.data and earlier.width == glyph.width and
            earlier.rows == glyph.rows and earlier.pitch == glyph.pitch) return j;
    }
    return null;
}

/// Pixel `x` of a row, as the kind stores it.
fn get(kind: fontimage.Kind, row: [*]const u8, x: u32) u8 {
    return switch (kind) {
        .mono1 => row[x / 8] >> @intCast(7 - x % 8) & 1,
        .alpha4 => if (x % 2 == 0) row[x / 2] >> 4 else row[x / 2] & 0x0F,
        else => row[x],
    };
}

/// Pixel `x` of a row set, as the kind stores it. The row starts zeroed.
fn put(kind: fontimage.Kind, row: [*]u8, x: u32, value: u8) void {
    switch (kind) {
        .mono1 => if (value != 0) {
            row[x / 8] |= @as(u8, 0x80) >> @intCast(x % 8);
        },
        .alpha4 => row[x / 2] |= if (x % 2 == 0) value << 4 else value,
        else => row[x] = value,
    }
}

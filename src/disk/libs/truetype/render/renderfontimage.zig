// SPDX-License-Identifier: MIT
//! RenderFontImage: one size of an outline, as a font image.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const truetype = sdk.truetype;
const FontImage = fontimage.FontImage;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");
const _render = @import("_render.zig");

/// One size of an outline, as a font image.
///
/// SYNOPSIS:
/// ```zig
/// fn RenderFontImage(tb: *TrueTypeBase, outline: *truetype.Outline, rows: u32, first: u32, last: u32) ?*FontImage
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `rows` - how tall a line is: the font's ascender to its descender
///   is scaled to this.
/// - `first`, `last` - the codes to render: 32 and 255 for the text a
///   string of bytes can be.
///
/// RESULT:
/// A font image of coverage (`alpha4`), sound and ready for `AddFont`:
/// the codes asked for and the font's missing glyph as the default
/// character, `last + 1`. Null for a height of 0, `last` below `first`, or
/// no memory.
///
/// BEHAVIOR:
/// Every glyph is its outline scaled so that the line is `rows` tall and
/// the baseline sits the ascender's share of it down, the curves made
/// lines within a third of a pixel, and each pixel given how much of it
/// the outline covers, in fifteenths. The advances are rounded to whole
/// pixels. A code the font has no glyph for is its missing glyph. The
/// font is `FPF_DESIGNED` - drawn at its size from the outline, not
/// scaled from another size - and `FPF_PROPORTIONAL` when its advances
/// differ.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is a few hundred glyphs.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The image is the caller's, one allocation, freed with `FreeVec`.
///
/// BUGS:
/// No hinting: stems at small sizes may fall between pixels and show as
/// two half-covered columns.
///
/// SEE ALSO:
/// `OpenOutline`, `graphics.library/AddFont`, `diskfont.library/OpenDiskFont`
///
/// EXAMPLES:
/// ```zig
/// const image = tb.RenderFontImage(outline, 24, 32, 255) orelse return;
/// defer sys.FreeVec(image);
/// ```
pub fn RenderFontImage(tb: *TrueTypeBase, outline: *truetype.Outline, rows: u32, first: u32, last: u32) ?*FontImage {
    const sys = tb.sys_base;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    if (rows == 0 or last < first or last - first > 0xFFFF) return null;
    const count = last - first + 2;
    const units: f32 = @floatFromInt(font.ascender - font.descender);
    const scale = _render.Scale{
        .factor = @as(f32, @floatFromInt(rows)) / units,
        .ascender = @floatFromInt(font.ascender),
    };

    var work = _render.Work.init(sys) orelse return null;
    defer work.deinit(sys);
    const glyphs_memory = sys.AllocVec(count * @sizeOf(_render.Rendered), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    defer sys.FreeVec(glyphs_memory);
    const glyphs: [*]_render.Rendered = @ptrCast(@alignCast(glyphs_memory));
    var made: u32 = 0;
    defer for (glyphs[0..made]) |g| if (g.pixels) |p| sys.FreeVec(p);

    var data_size: u32 = 0;
    while (made < count) : (made += 1) {
        // The last is the missing glyph, the default character.
        const glyph = if (made == count - 1) 0 else _outline.glyphIndex(font, first + made);
        glyphs[made] = _render.renderGlyph(sys, font, glyph, scale, &work) orelse return null;
        data_size += fontimage.pitchOf(.alpha4, glyphs[made].width) * glyphs[made].rows;
    }

    const ranges_at: u32 = @sizeOf(FontImage);
    const glyphs_at = ranges_at + @sizeOf(fontimage.Range);
    const data_at = glyphs_at + count * @sizeOf(fontimage.Glyph);
    const size = data_at + ((data_size + 3) & ~@as(u32, 3));
    const memory = sys.AllocVec(size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const block: [*]align(4) u8 = @ptrCast(@alignCast(memory));
    const range: *fontimage.Range = @ptrCast(@alignCast(block + ranges_at));
    range.* = .{ .first = first, .last = last + 1, .glyph = 0 };
    const table: [*]fontimage.Glyph = @ptrCast(@alignCast(block + glyphs_at));

    var at: u32 = 0;
    var max_width: u32 = 0;
    var proportional = false;
    for (glyphs[0..count], 0..) |g, i| {
        const pitch = fontimage.pitchOf(.alpha4, g.width);
        table[i] = .{
            .data = at,
            .width = @intCast(g.width),
            .rows = @intCast(g.rows),
            .top = @intCast(g.top),
            .left = @intCast(g.left),
            .advance = @intCast(g.advance),
            .pitch = @intCast(pitch),
        };
        if (g.pixels) |pixels| {
            const out = block + data_at + at;
            for (0..g.rows) |y| for (0..g.width) |x| {
                const value = pixels[y * g.width + x];
                out[y * pitch + x / 2] |= if (x % 2 == 0) value << 4 else value;
            };
        }
        at += pitch * g.rows;
        max_width = @max(max_width, g.width);
        if (i < count - 1 and g.advance != glyphs[0].advance) proportional = true;
    }

    const zero = if ('0' >= first and '0' <= last) glyphs['0' - first].advance else glyphs[0].advance;
    const header: *FontImage = @ptrCast(block);
    header.* = .{
        .size = size,
        .height = @intCast(rows),
        .baseline = @intFromFloat(@floor(scale.ascender * scale.factor + 0.5)),
        .x_size = @intCast(@max(zero, 1)),
        .max_width = @intCast(max_width),
        .flags = graphics.FPF_DESIGNED | if (proportional) graphics.FPF_PROPORTIONAL else 0,
        .kind = .alpha4,
        .default_char = last + 1,
        .range_count = 1,
        .ranges = ranges_at,
        .glyph_count = count,
        .glyphs = glyphs_at,
        .data_size = data_size,
        .data = data_at,
    };
    header.checksum = fontimage.checksumOf(block, size);
    return header;
}

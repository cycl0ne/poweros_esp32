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
/// fn RenderFontImage(tb: *TrueTypeBase, outline: *truetype.Outline, rows: u32, ranges: [*]const truetype.CodeRange, count: u32) ?*FontImage
/// ```
///
/// SINCE: 1.0, ranges since 1.3. LVO -24.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `rows` - how tall a line is: the font's ascender to its descender
///   is scaled to this.
/// - `ranges` - the characters to render, as code points: `count` ranges,
///   sorted, none overlapping another.
/// - `count` - how many ranges.
///
/// RESULT:
/// A font image of coverage (`alpha4`), sound and ready for `AddFont`:
/// every character of the ranges the font has a glyph for, and the
/// font's missing glyph as the default character, under
/// `fontimage.MISSING`. Null for a height of 0, ranges out of order or
/// past the last code point, or no memory.
///
/// BEHAVIOR:
/// A character the font's character map gives no glyph is left out, so
/// that graphics draws it as its base letter where the image has that
/// (`Ā` as `A`) and as the missing glyph otherwise; the image's own
/// ranges are the runs of characters it has.
///
/// Every glyph is its outline scaled so that the line is `rows` tall and
/// the baseline sits the ascender's share of it down, the curves made
/// lines within a third of a pixel, and each pixel given how much of it
/// the outline covers, in fifteenths. The advances are rounded to whole
/// pixels. The font is `FPF_DESIGNED` - drawn at its size from the
/// outline, not scaled from another size - and `FPF_PROPORTIONAL` when
/// its advances differ. Its styles are the ones the file says it is drawn
/// in (`truetype.styleOf`): a bold face renders as `FSF_BOLD`, so graphics
/// draws no bold over it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is a glyph rendered for each character the
///   font has in the ranges: hundreds for a European font's scripts.
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
/// const latin1 = [_]truetype.CodeRange{ .{ .first = 0x20, .last = 0x7E }, .{ .first = 0xA0, .last = 0xFF } };
/// const image = tb.RenderFontImage(outline, 24, &latin1, latin1.len) orelse return;
/// defer sys.FreeVec(image);
/// ```
pub fn RenderFontImage(tb: *TrueTypeBase, outline: *truetype.Outline, rows: u32, ranges: [*]const truetype.CodeRange, count: u32) ?*FontImage {
    const sys = tb.sys_base;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    if (rows == 0) return null;
    const asked = ranges[0..count];

    // What the font has of the ranges, and in how many runs.
    var have: u32 = 0;
    var runs: u32 = 0;
    var next: u64 = 0;
    for (asked) |range| {
        if (range.first < next or range.last < range.first or range.last > fontimage.MISSING - 1) return null;
        next = @as(u64, range.last) + 1;
        var in_run = false;
        var code = range.first;
        while (true) : (code += 1) {
            const found = _outline.glyphIndex(font, code) != 0;
            if (found) {
                have += 1;
                if (!in_run) runs += 1;
            }
            in_run = found;
            if (code == range.last) break;
        }
    }
    // The missing glyph after them all, a run of its own.
    const glyph_count = have + 1;
    const range_count = runs + 1;

    const units: f32 = @floatFromInt(font.ascender - font.descender);
    const scale = _render.Scale{
        .factor = @as(f32, @floatFromInt(rows)) / units,
        .ascender = @floatFromInt(font.ascender),
    };

    var work = _render.Work.init(sys) orelse return null;
    defer work.deinit(sys);
    const glyphs_memory = sys.AllocVec(glyph_count * @sizeOf(_render.Rendered), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    defer sys.FreeVec(glyphs_memory);
    const glyphs: [*]_render.Rendered = @ptrCast(@alignCast(glyphs_memory));
    var made: u32 = 0;
    defer for (glyphs[0..made]) |g| if (g.pixels) |p| sys.FreeVec(p);

    var data_size: u32 = 0;
    for (asked) |range| {
        var code = range.first;
        while (true) : (code += 1) {
            const glyph = _outline.glyphIndex(font, code);
            if (glyph != 0) {
                glyphs[made] = _render.renderGlyph(sys, font, glyph, scale, &work) orelse return null;
                data_size += fontimage.pitchOf(.alpha4, glyphs[made].width) * glyphs[made].rows;
                made += 1;
            }
            if (code == range.last) break;
        }
    }
    glyphs[made] = _render.renderGlyph(sys, font, 0, scale, &work) orelse return null;
    data_size += fontimage.pitchOf(.alpha4, glyphs[made].width) * glyphs[made].rows;
    made += 1;

    const ranges_at: u32 = @sizeOf(FontImage);
    const glyphs_at = ranges_at + range_count * @sizeOf(fontimage.Range);
    const data_at = glyphs_at + glyph_count * @sizeOf(fontimage.Glyph);
    const size = data_at + ((data_size + 3) & ~@as(u32, 3));
    const memory = sys.AllocVec(size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const block: [*]align(4) u8 = @ptrCast(@alignCast(memory));

    // The image's ranges: the runs of characters the font has, then the
    // missing glyph.
    const runs_out: [*]fontimage.Range = @ptrCast(@alignCast(block + ranges_at));
    var run_at: u32 = 0;
    var index: u32 = 0;
    var zero_at: ?u32 = null;
    for (asked) |range| {
        var code = range.first;
        while (true) : (code += 1) {
            if (_outline.glyphIndex(font, code) != 0) {
                if (run_at != 0 and runs_out[run_at - 1].last + 1 == code) {
                    runs_out[run_at - 1].last = code;
                } else {
                    runs_out[run_at] = .{ .first = code, .last = code, .glyph = index };
                    run_at += 1;
                }
                if (code == '0') zero_at = index;
                index += 1;
            }
            if (code == range.last) break;
        }
    }
    runs_out[run_at] = .{ .first = fontimage.MISSING, .last = fontimage.MISSING, .glyph = index };
    const table: [*]fontimage.Glyph = @ptrCast(@alignCast(block + glyphs_at));

    var at: u32 = 0;
    var max_width: u32 = 0;
    var proportional = false;
    for (glyphs[0..glyph_count], 0..) |g, i| {
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
        if (i < glyph_count - 1 and g.advance != glyphs[0].advance) proportional = true;
    }

    const zero = glyphs[zero_at orelse 0].advance;
    const header: *FontImage = @ptrCast(block);
    header.* = .{
        .size = size,
        .height = @intCast(rows),
        .baseline = @intFromFloat(@floor(scale.ascender * scale.factor + 0.5)),
        .x_size = @intCast(@max(zero, 1)),
        .max_width = @intCast(max_width),
        .style = font.style,
        .flags = graphics.FPF_DESIGNED | if (proportional) graphics.FPF_PROPORTIONAL else 0,
        .kind = .alpha4,
        .default_char = fontimage.MISSING,
        .range_count = range_count,
        .ranges = ranges_at,
        .glyph_count = glyph_count,
        .glyphs = glyphs_at,
        .data_size = data_size,
        .data = data_at,
    };
    header.checksum = fontimage.checksumOf(block, size);
    return header;
}

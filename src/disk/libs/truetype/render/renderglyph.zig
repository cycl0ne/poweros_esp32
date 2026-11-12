// SPDX-License-Identifier: MIT
//! RenderGlyph: one glyph of an outline, by its number, as a font image
//! has a glyph.

const sdk = @import("sdk");
const fontimage = sdk.graphics.fontimage;
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");
const _render = @import("_render.zig");

/// One glyph of an outline, by its number, as a font image has a glyph.
///
/// SYNOPSIS:
/// ```zig
/// fn RenderGlyph(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, rows: u32, image: *truetype.GlyphImage) i32
/// ```
///
/// SINCE: 1.5, fonts of cubic curves since 1.6. LVO -64.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `glyph` - the glyph's number: from `GlyphIndex`, `GlyphVariant`, or
///   a shaped run.
/// - `rows` - how tall a line is, 1 to 4096: the font's ascender to its
///   descender is scaled to this.
/// - `image` - the caller's bytes for the pixels and how many there are;
///   the rest of it is set.
///
/// RESULT:
/// - `TRUETYPE_OK` - the glyph is in `image`: its box and advance in
///   `glyph`, `size` bytes of pixels written. A glyph with no ink - a
///   space - has a box of nothing, no bytes, and its advance.
/// - `TRUETYPEERR_ROOM` - the pixels did not fit: `size` says how many
///   bytes they take and `glyph` is set, and nothing is written.
/// - `TRUETYPEERR_GLYPH` - no glyph of that number, or a font without
///   outlines.
/// - `TRUETYPEERR_ROWS` - a height of 0 or more than 4096.
/// - `TRUETYPEERR_NOMEM` - no memory to render it in.
///
/// With every answer but the first two, `size` is 0 and `glyph` is a
/// glyph of nothing.
///
/// BEHAVIOR:
/// The glyph is rendered as `RenderFontImage` renders the glyphs of a
/// font image `rows` tall, and comes out the same byte for byte: its
/// outline scaled so that the line is `rows` tall, each pixel given how
/// much of it the outline covers, in fifteenths. `image.kind` says what
/// the bytes are - `alpha4`, two pixels a byte, the left one in the high
/// four bits - and `image.glyph` is a font image's glyph: the box of its
/// ink, `left` columns from the point and `top` rows down from the top
/// of the line, the bytes from one row to the next, and the advance in
/// whole pixels. Its `data` is 0.
///
/// A glyph the file is damaged in - its data cut short, a program of
/// cubic curves that cannot be run, its outline further than sixteen
/// lines from where it is drawn - is one of no ink, with its advance; an
/// advance is 32767 pixels at most.
///
/// A glyph of cubic curves is rendered whatever its size: one of more
/// points than `FontMetrics` counts on is read into the room it needs.
///
/// The outline is only read, and what the call works in is its own: any
/// number of tasks render from one outline at once.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `image` and its bytes are the caller's. The call allocates the room
/// it renders in and gives it back before it returns.
///
/// NOTES:
/// An answer of `TRUETYPEERR_ROOM` has cost the rendering: a caller that
/// keeps room for the glyphs it mostly draws, and asks again with more
/// for the few that are larger, renders those twice.
///
/// BUGS:
/// No hinting: stems at small sizes may fall between pixels and show as
/// two half-covered columns.
///
/// SEE ALSO:
/// `RenderFontImage`, `GlyphIndex`, `GlyphMetrics`,
/// `truetypeshaping.library/ShapeText`
///
/// EXAMPLES:
/// ```zig
/// var bytes: [1024]u8 = undefined;
/// var image = sdk.truetype.GlyphImage{ .pixels = &bytes, .room = bytes.len };
/// if (tb.RenderGlyph(outline, glyph, 24, &image) == sdk.truetype.TRUETYPE_OK) {
///     // image.glyph.width by image.glyph.rows pixels in bytes[0..image.size].
/// }
/// ```
pub fn RenderGlyph(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, rows: u32, image: *truetype.GlyphImage) i32 {
    const sys = tb.sys_base;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    image.size = 0;
    image.kind = .alpha4;
    image.glyph = .{};
    if (rows == 0 or rows > _render.most_rows) return truetype.TRUETYPEERR_ROWS;
    if (glyph >= font.glyph_count or !_outline.hasOutlines(font)) return truetype.TRUETYPEERR_GLYPH;

    var work = _render.Work.init(sys, font) orelse return truetype.TRUETYPEERR_NOMEM;
    defer work.deinit(sys);
    const rendered = _render.renderGlyph(sys, font, glyph, _render.scaleOf(font, rows), &work) orelse
        return truetype.TRUETYPEERR_NOMEM;
    defer if (rendered.pixels) |pixels| sys.FreeVec(pixels);

    const pitch = fontimage.pitchOf(.alpha4, rendered.width);
    image.glyph = .{
        .width = @intCast(rendered.width),
        .rows = @intCast(rendered.rows),
        .top = @intCast(rendered.top),
        .left = @intCast(rendered.left),
        .advance = @intCast(rendered.advance),
        .pitch = @intCast(pitch),
    };
    image.size = pitch * rendered.rows;
    if (image.size > image.room) return truetype.TRUETYPEERR_ROOM;
    _render.pack(&rendered, image.pixels, pitch);
    return truetype.TRUETYPE_OK;
}

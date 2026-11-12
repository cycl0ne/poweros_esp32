// SPDX-License-Identifier: MIT
//! GlyphMetrics: a glyph's advance, left side bearing and box.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");

/// A glyph's advance, left side bearing and box.
///
/// SYNOPSIS:
/// ```zig
/// fn GlyphMetrics(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, metrics: *truetype.GlyphMetrics) bool
/// ```
///
/// SINCE: 1.2, fonts of cubic curves since 1.6, fonts of pictures since
/// 1.7. LVO -36.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `glyph` - the glyph's number, from `GlyphIndex`.
/// - `metrics` - where they go.
///
/// RESULT:
/// True, and `metrics` filled in, in the font's units, y up; false - and
/// `metrics` all 0 - for a number past the font's glyphs.
///
/// BEHAVIOR:
/// The advance and the left side bearing are the font's horizontal
/// metrics (`hmtx`); the box is the one the glyph's data gives, which
/// holds its points on the curve and off it. A glyph of no outline, a
/// space, has a box of 0s and its advance.
///
/// A glyph of cubic curves has no box in its data: its program is run
/// and the box is the one of its points, the curves' control points
/// among them, widened to whole units. A glyph whose program is damaged
/// has a box of 0s and its advance.
///
/// A glyph that is a picture has the box of its largest picture: the
/// picture's measures in its strike's pixels, brought to the font's
/// units by the strike's pixels an em and widened to whole units. Its
/// advance and left side bearing are the font's horizontal metrics, as
/// any glyph's. A glyph no strike has a picture of has a box of 0s.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `metrics` is the caller's.
///
/// BUGS:
/// No vertical metrics: text set down the page is not read.
///
/// SEE ALSO:
/// `GlyphIndex`, `FontMetrics`, `GlyphSegments`
///
/// EXAMPLES:
/// ```zig
/// var m: sdk.truetype.GlyphMetrics = .{};
/// if (tb.GlyphMetrics(outline, glyph, &m)) x += m.advance;
/// ```
pub fn GlyphMetrics(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, metrics: *truetype.GlyphMetrics) bool {
    _ = tb;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    metrics.* = .{};
    if (glyph >= font.glyph_count) return false;
    const box = _outline.boxOf(font, glyph);
    metrics.* = .{
        .advance = _outline.advanceOf(font, glyph),
        .left_bearing = _outline.leftBearingOf(font, glyph),
        .x_min = box[0],
        .y_min = box[1],
        .x_max = box[2],
        .y_max = box[3],
    };
    return true;
}

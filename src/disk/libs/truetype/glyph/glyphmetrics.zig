// SPDX-License-Identifier: MIT
//! GlyphMetrics: a glyph's advance, left side bearing and box.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");
const _render = @import("../render/_render.zig");

/// A glyph's advance, left side bearing and box.
///
/// SYNOPSIS:
/// ```zig
/// fn GlyphMetrics(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, metrics: *truetype.GlyphMetrics) bool
/// ```
///
/// SINCE: 1.2, fonts of cubic curves since 1.6, fonts of pictures since
/// 1.7, variable fonts since 1.8, those of cubic curves since 1.9.
/// LVO -36.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `glyph` - the glyph's number, from `GlyphIndex`.
/// - `metrics` - where they go.
///
/// RESULT:
/// True, and `metrics` filled in, in the font's units, y up; false - and
/// `metrics` all 0 - for a number past the font's glyphs, and for a
/// glyph of a variable font away from its default when there is not the
/// memory to read it.
///
/// BEHAVIOR:
/// The advance and the left side bearing are the font's horizontal
/// metrics (`hmtx`); the box is the one the glyph's data gives, which
/// holds its points on the curve and off it, counted from the glyph's
/// left side point - so its left is the left side bearing, also in a
/// font whose data has the box elsewhere - as `GlyphSegments` and
/// `RenderGlyph` draw the glyph. A glyph of no outline, a space, has a
/// box of 0s and its advance.
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
/// A `glyf` glyph of a variable font away from its default has the
/// measures of that instance. The box its data gives is the default's,
/// so the glyph is read with its deltas, in memory taken and given back
/// within the call, and the box is the one of its points there, the
/// curves' control points among them, widened to whole units. The
/// advance is `GlyphAdvance`'s. The box is counted from the glyph's
/// origin there - its left side point as the deltas move it, rounded -
/// and the left side bearing is its left. A glyph whose deltas are damaged
/// has a box of 0s and its advance.
///
/// A glyph of cubic curves of a variable font away from its default
/// (`CFF2`) has its deltas in its program, so its box is that
/// instance's as it is at the default: the program is run, and no
/// memory is taken. Its origin is where its program starts from, at
/// every instance, and its left side bearing is the left of its box
/// there, 0 for a glyph of no outline.
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
/// NOTES:
/// A caller that wants the advance only asks `GlyphAdvance`, which
/// takes no memory at any instance.
///
/// BUGS:
/// No vertical metrics: text set down the page is not read.
///
/// SEE ALSO:
/// `GlyphIndex`, `GlyphAdvance`, `FontMetrics`, `GlyphSegments`
///
/// EXAMPLES:
/// ```zig
/// var m: sdk.truetype.GlyphMetrics = .{};
/// if (tb.GlyphMetrics(outline, glyph, &m)) x += m.advance;
/// ```
pub fn GlyphMetrics(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, metrics: *truetype.GlyphMetrics) bool {
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    metrics.* = .{};
    if (glyph >= font.glyph_count) return false;
    if (_outline.isVaried(font)) return varied(tb, font, glyph, metrics);
    const box = _outline.boxOf(font, glyph);
    // The table's bearing is the default's: away from it a glyph of
    // cubic curves, drawn from its origin, has its box's left.
    const blended = _outline.isCubic(font) and font.vary.varied;
    metrics.* = .{
        .advance = _outline.advanceOf(font, glyph),
        .left_bearing = if (blended) box[0] else _outline.leftBearingOf(font, glyph),
        .x_min = box[0],
        .y_min = box[1],
        .x_max = box[2],
        .y_max = box[3],
    };
    return true;
}

/// The measures of a glyph whose points have deltas: read with them,
/// its box is its points'. False without the memory to read it.
fn varied(tb: *TrueTypeBase, font: *const _outline.Font, glyph: u32, metrics: *truetype.GlyphMetrics) bool {
    const sys = tb.sys_base;
    var work = _render.Work.init(sys, font) orelse return false;
    defer work.deinit(sys);
    metrics.advance = _outline.advanceOf(font, glyph);
    const c = &work.contours;
    const identity = [6]f32{ 1, 0, 0, 1, 0, 0 };
    const read = _outline.contours(font, glyph, c, identity, 0);
    if (!read or c.point_count == 0) return true;
    var x_min = c.points[0].x;
    var y_min = c.points[0].y;
    var x_max = x_min;
    var y_max = y_min;
    for (c.points[1..c.point_count]) |p| {
        x_min = @min(x_min, p.x);
        y_min = @min(y_min, p.y);
        x_max = @max(x_max, p.x);
        y_max = @max(y_max, p.y);
    }
    metrics.x_min = @intFromFloat(@floor(x_min));
    metrics.y_min = @intFromFloat(@floor(y_min));
    metrics.x_max = @intFromFloat(@ceil(x_max));
    metrics.y_max = @intFromFloat(@ceil(y_max));
    // The contours are read from the glyph's origin already.
    metrics.left_bearing = metrics.x_min;
    return true;
}

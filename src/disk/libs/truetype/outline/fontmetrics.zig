// SPDX-License-Identifier: MIT
//! FontMetrics: a font's measures.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("_outline.zig");
const _segments = @import("../glyph/_segments.zig");

/// A font's measures.
///
/// SYNOPSIS:
/// ```zig
/// fn FontMetrics(tb: *TrueTypeBase, outline: *truetype.Outline, metrics: *truetype.FontMetrics) void
/// ```
///
/// SINCE: 1.2. LVO -44.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `metrics` - where they go.
///
/// RESULT:
/// Nothing; `metrics` is filled in, in the font's units, y up.
///
/// BEHAVIOR:
/// The units per em and the number of glyphs; the ascender, descender
/// and line gap of the horizontal header (`hhea`), which is what
/// `RenderFontImage` sets its lines by; the x and capital heights and
/// the strike-out of `OS/2`, the underline of `post`, each 0 where the
/// font does not give it; the most verbs and points `GlyphSegments`
/// gives for a glyph of the font, from what `maxp` says the largest
/// glyph is (or as for 1024 points and 128 contours, when it does not
/// say); and the styles the file says it is drawn in.
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
/// A font whose `maxp` says less than its largest glyph has is not
/// read so far: that glyph's `GlyphSegments` answers
/// `TRUETYPEERR_GLYPH`.
///
/// SEE ALSO:
/// `GlyphMetrics`, `GlyphSegments`, `OpenOutline`
///
/// EXAMPLES:
/// ```zig
/// var fm: sdk.truetype.FontMetrics = .{};
/// tb.FontMetrics(outline, &fm);
/// const scale = size / @as(f32, @floatFromInt(fm.units_per_em));
/// ```
pub fn FontMetrics(tb: *TrueTypeBase, outline: *truetype.Outline, metrics: *truetype.FontMetrics) void {
    _ = tb;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    const most = _segments.mostOf(font);
    metrics.* = .{
        .units_per_em = font.units_per_em,
        .glyph_count = font.glyph_count,
        .ascender = font.ascender,
        .descender = font.descender,
        .line_gap = font.line_gap,
        .x_height = font.x_height,
        .cap_height = font.cap_height,
        .underline_position = font.underline_position,
        .underline_thickness = font.underline_thickness,
        .strikeout_position = font.strikeout_position,
        .strikeout_thickness = font.strikeout_thickness,
        .most_verbs = most[0],
        .most_points = most[1],
        .style = font.style,
    };
}

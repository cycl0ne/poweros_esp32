// SPDX-License-Identifier: MIT
//! GlyphSegments: a glyph's outline as lines and curves.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");
const _segments = @import("_segments.zig");

/// A glyph's outline as lines and curves.
///
/// SYNOPSIS:
/// ```zig
/// fn GlyphSegments(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, segments: *truetype.Segments) i32
/// ```
///
/// SINCE: 1.2. LVO -40.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `glyph` - the glyph's number, from `GlyphIndex`.
/// - `segments` - the caller's arrays of verbs and points, and how many
///   each holds; the counts are set.
///
/// RESULT:
/// - `TRUETYPE_OK` - the outline is in the arrays, `verb_count` verbs
///   and `point_count` points; none for a glyph of no outline, a space.
/// - `TRUETYPEERR_ROOM` - it did not fit: the counts say how many it
///   needs, and what is in the arrays is not to be used.
/// - `TRUETYPEERR_GLYPH` - no glyph of that number, or its data is
///   damaged; the counts are 0.
/// - `TRUETYPEERR_NOMEM` - no memory to read it in.
///
/// BEHAVIOR:
/// The verbs are vector.library's - `SEG_MOVE`, `SEG_LINE`, `SEG_QUAD`,
/// `SEG_CLOSE` - and the points `vector.Point`s, so the arrays go to
/// `AddSegments` as they are. They are in the font's units, y up, from
/// the glyph's origin on the baseline: a program drawing them scales by
/// its size over `FontMetrics`' units per em and turns y over. Each
/// contour is closed, and filled by the non-zero rule its contours are
/// drawn for. A composite glyph is its parts, each moved and scaled as
/// the font says, in one outline.
///
/// `FontMetrics`' `most_verbs` and `most_points` are long enough for any
/// glyph of the font.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The arrays are the caller's. The call allocates room to read the
/// glyph in, and gives it back before it returns.
///
/// BUGS:
/// No hinting: the outline is as it was drawn, for any size. A part of a
/// composite placed by matching its points to another's is left where it
/// was drawn.
///
/// SEE ALSO:
/// `GlyphIndex`, `GlyphMetrics`, `FontMetrics`,
/// `vector.library/AddSegments`
///
/// EXAMPLES:
/// ```zig
/// var s = sdk.truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = verbs.len, .point_room = points.len };
/// if (tb.GlyphSegments(outline, glyph, &s) == sdk.truetype.TRUETYPE_OK) {
///     _ = vb.AddSegments(path, s.verbs, s.verb_count, s.points, s.point_count);
/// }
/// ```
pub fn GlyphSegments(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, segments: *truetype.Segments) i32 {
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    return _segments.glyphSegments(tb.sys_base, font, glyph, segments);
}

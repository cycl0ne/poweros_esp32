// SPDX-License-Identifier: MIT
//! GlyphPaints: the steps that draw a glyph of colour layers, read by
//! `_colr.zig`.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");
const _colr = @import("_colr.zig");
const Font = _outline.Font;

/// The steps that draw a glyph of colour layers.
///
/// SYNOPSIS:
/// ```zig
/// fn GlyphPaints(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, steps: ?[*]truetype.PaintStep, room: u32) u32
/// ```
///
/// SINCE: 1.17. LVO -92.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `glyph` - the glyph's number, from `GlyphIndex`.
/// - `steps` - where the steps go, or null to count them.
/// - `room` - how many steps `steps` holds.
///
/// RESULT:
/// How many steps draw the glyph, whatever `room` is: the first `room`
/// of them are in `steps`. 0 for a glyph the font does not draw in
/// colour, and for one whose drawing cannot be read.
///
/// BEHAVIOR:
/// The font's `COLR` table draws a glyph in layers of colour, from the
/// first palette of its `CPAL` table. The steps are that drawing, in
/// the font's units, y up, from the glyph's point (`STEP_*`): outlines
/// of glyphs filled with a colour or a gradient, inside clips of other
/// outlines and of boxes, through transforms, on layers put down in one
/// of Porter and Duff's ways or a blend.
///
/// - A glyph of the table's first version is its layers, each glyph
///   filled with its colour (`STEP_FILL_GLYPH`).
/// - One of its second version is its graph of paints, inside the clip
///   box the table gives it. A glyph holding a colour or a gradient,
///   through transforms or not, is the glyph filled with it; one
///   holding more is its outline as a clip around the rest.
/// - A composite is a layer of its backdrop, and on it a layer of its
///   source put down in its mode (`STEP_PUSH_LAYER`).
/// - A gradient comes as a program draws one: its stops sorted, from 0
///   to 1 along it, and a linear one from one point to another
///   (`BRUSH_*`), each followed by its stops (`STEP_STOP`). A colour
///   the palette lacks, and the number 0xFFFF, is the text's own
///   (`STEPF_FOREGROUND`).
/// - A variable font's paints are its instance's: each value plus the
///   delta the table's store gives it at the outline's place.
///
/// A step's transform, clip and layer each end with a pop of their own,
/// in the order they were pushed, the last first.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `steps` is the caller's.
///
/// NOTES:
/// The caller asks twice: with no `steps` for the count, then with room
/// for that many. A font has a glyph's outline too, for a program that
/// does not draw in colour. A program draws a glyph by the first of
/// `GlyphPaints`, `GlyphDocument` and `GlyphPicture` that has it.
///
/// BUGS:
/// A graph deeper than 64 paints, or of more than 16384, is read as no
/// drawing, as is one that goes round in a circle.
///
/// SEE ALSO:
/// `GlyphDocument`, `GlyphPicture`, `GlyphSegments`
///
/// EXAMPLES:
/// ```zig
/// const count = tb.GlyphPaints(outline, glyph, null, 0);
/// if (count != 0) {
///     const steps: [*]truetype.PaintStep = @ptrCast(@alignCast(sys.AllocVec(count * @sizeOf(truetype.PaintStep), exec.MEMF_ANY) orelse return));
///     defer sys.FreeVec(steps);
///     _ = tb.GlyphPaints(outline, glyph, steps, count);
/// }
/// ```
pub fn GlyphPaints(_: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, steps: ?[*]truetype.PaintStep, room: u32) u32 {
    const font: *const Font = @ptrCast(@alignCast(outline));
    if (glyph >= font.glyph_count) return 0;
    return _colr.stepsOf(font, glyph, steps, room);
}

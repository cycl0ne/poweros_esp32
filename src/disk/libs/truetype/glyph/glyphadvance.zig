// SPDX-License-Identifier: MIT
//! GlyphAdvance: how far a glyph moves the point.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");

/// How far a glyph moves the point.
///
/// SYNOPSIS:
/// ```zig
/// fn GlyphAdvance(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32) i32
/// ```
///
/// SINCE: 1.8, variable fonts of cubic curves since 1.9. LVO -80.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `glyph` - the glyph's number, from `GlyphIndex`.
///
/// RESULT:
/// The glyph's advance in the font's units, never less than 0; 0 for a
/// number past the font's glyphs.
///
/// BEHAVIOR:
/// The advance is the font's horizontal metrics' (`hmtx`), the one
/// `GlyphMetrics` gives. For a variable font away from its default it
/// is that instance's: the advance plus what the font's `HVAR` table
/// says it changes by there, rounded to a whole unit; or, in a font
/// without that table, the distance between the glyph's two sides as
/// its deltas in `gvar` move them, rounded. A font of cubic curves
/// without `HVAR` has nothing that moves its advances: they are the
/// same at every instance.
///
/// The call reads no outline and takes no memory, which the box of a
/// glyph away from the default does. It is the one to ask when a line
/// of text is measured.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// BUGS:
/// No vertical advance: text set down the page is not read.
///
/// SEE ALSO:
/// `GlyphMetrics`, `GlyphIndex`, `Kerning`
///
/// EXAMPLES:
/// ```zig
/// var width: i32 = 0;
/// for (text) |code| width += tb.GlyphAdvance(outline, tb.GlyphIndex(outline, code));
/// ```
pub fn GlyphAdvance(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32) i32 {
    _ = tb;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    if (glyph >= font.glyph_count) return 0;
    return _outline.advanceOf(font, glyph);
}

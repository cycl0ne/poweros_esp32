// SPDX-License-Identifier: MIT
//! Kerning: how much further apart two glyphs are drawn side by side.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");

/// How much further apart two glyphs are drawn side by side.
///
/// SYNOPSIS:
/// ```zig
/// fn Kerning(tb: *TrueTypeBase, outline: *truetype.Outline, left: u32, right: u32) i32
/// ```
///
/// SINCE: 1.2. LVO -48.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `left` - the glyph drawn first, from `GlyphIndex`.
/// - `right` - the one after it.
///
/// RESULT:
/// The font's units added to `left`'s advance before `right` is drawn:
/// negative to draw them closer, as "AV" is. 0 for a pair the font does
/// not move.
///
/// BEHAVIOR:
/// The pairs of the font's `kern` table: those of its subtables of
/// format 0 for horizontal text, summed - one that says it overrides
/// taking the place of what came before it.
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
/// Only the `kern` table is read, not OpenType's `GPOS`: a font that
/// keeps its kerning only there is drawn without it. Apple's version of
/// the table is not read either.
///
/// SEE ALSO:
/// `GlyphIndex`, `GlyphMetrics`
///
/// EXAMPLES:
/// ```zig
/// x += m.advance + tb.Kerning(outline, glyph, next);
/// ```
pub fn Kerning(tb: *TrueTypeBase, outline: *truetype.Outline, left: u32, right: u32) i32 {
    _ = tb;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    return _outline.kerningOf(font, left, right);
}

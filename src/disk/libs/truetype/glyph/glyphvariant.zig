// SPDX-License-Identifier: MIT
//! GlyphVariant: the glyph a character and a variation selector are.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");

/// The glyph a character and a variation selector are.
///
/// SYNOPSIS:
/// ```zig
/// fn GlyphVariant(tb: *TrueTypeBase, outline: *truetype.Outline, code: u32, selector: u32) u32
/// ```
///
/// SINCE: 1.4. LVO -52.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `code` - the character, a Unicode code point.
/// - `selector` - the variation selector that follows it: U+FE00 to
///   U+FE0F, U+E0100 to U+E01EF, or U+180B to U+180D.
///
/// RESULT:
/// The number of the glyph the two are drawn as; 0 when the font has no
/// such sequence, and the character is then drawn as `GlyphIndex` says,
/// the selector left out.
///
/// BEHAVIOR:
/// Looked up in the font's variation sequences (the character map's
/// format 14). A sequence the font has a glyph of its own for answers
/// that glyph: U+FE0F after a symbol its picture in colour, U+FE0E its
/// form as text, a selector after an ideograph one of its registered
/// shapes. A sequence the font lists as drawn the way the character is
/// without a selector answers the character's own glyph.
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
/// None known.
///
/// SEE ALSO:
/// `GlyphIndex`, `GlyphMetrics`
///
/// EXAMPLES:
/// ```zig
/// // A heart, asked for in colour.
/// var glyph = tb.GlyphVariant(outline, 0x2764, 0xFE0F);
/// if (glyph == 0) glyph = tb.GlyphIndex(outline, 0x2764);
/// ```
pub fn GlyphVariant(tb: *TrueTypeBase, outline: *truetype.Outline, code: u32, selector: u32) u32 {
    _ = tb;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    return _outline.glyphVariant(font, code, selector);
}

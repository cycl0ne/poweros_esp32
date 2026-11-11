// SPDX-License-Identifier: MIT
//! GlyphIndex: the glyph a character is.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");

/// The glyph a character is.
///
/// SYNOPSIS:
/// ```zig
/// fn GlyphIndex(tb: *TrueTypeBase, outline: *truetype.Outline, code: u32) u32
/// ```
///
/// SINCE: 1.2, every format of character map since 1.4. LVO -32.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `code` - the character, a Unicode code point.
///
/// RESULT:
/// The glyph's number, for `GlyphSegments`, `GlyphMetrics` and
/// `Kerning`; 0 - the missing glyph, which a font draws as a box or
/// nothing - when the font has none for it.
///
/// BEHAVIOR:
/// Looked up in the character map `OpenOutline` chose: the font's
/// Unicode one that reaches furthest (formats 12, 13, 10, 4, 6 and 0, in
/// that order; one of the basic plane has no glyph past U+FFFF), or a
/// symbol font's own, whose characters are where the font puts them. A
/// glyph the map names and the font does not have answers 0.
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
/// One character is one glyph: a font's substitutions - ligatures, the
/// forms of a script's letters by where they are in a word - are not
/// made. A character map of format 2 or 8 is not read.
///
/// SEE ALSO:
/// `GlyphVariant`, `GlyphSegments`, `GlyphMetrics`, `Kerning`
///
/// EXAMPLES:
/// ```zig
/// const glyph = tb.GlyphIndex(outline, 'A');
/// ```
pub fn GlyphIndex(tb: *TrueTypeBase, outline: *truetype.Outline, code: u32) u32 {
    _ = tb;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    return _outline.glyphIndex(font, code);
}

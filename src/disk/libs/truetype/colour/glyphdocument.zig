// SPDX-License-Identifier: MIT
//! GlyphDocument: the SVG document of the font's `SVG ` table that draws
//! a glyph. `documentOf` is the reading, for the library's call and for
//! a tool on the host (`outlines.zig`).
//!
//! The table is a list of documents, each for a range of glyphs and in
//! the order of them: where the document's text is, from the list's
//! start, and how long it is.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");
const Font = _outline.Font;
const Table = _outline.Table;

/// The SVG document that draws a glyph.
///
/// SYNOPSIS:
/// ```zig
/// fn GlyphDocument(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, document: *truetype.Document) bool
/// ```
///
/// SINCE: 1.17. LVO -100.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `glyph` - the glyph's number, from `GlyphIndex`.
/// - `document` - where the document goes.
///
/// RESULT:
/// True, the document in `document`. False for a glyph the font's
/// `SVG ` table does not draw, and for a font without one; `document`
/// is then all 0.
///
/// BEHAVIOR:
/// The document is its text within the font's bytes, as the table has
/// it: an SVG document, or one packed with gzip (it starts 0x1F 0x8B).
/// `first` and `last` are the glyphs it is for. One for a single glyph
/// is that glyph whole; one for more draws each as the element whose
/// `id` is "glyph" and the glyph's number.
///
/// The document is drawn in the font's units from the glyph's point, y
/// down, as SVG has it: the glyph stands on the line y = 0, above it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `document` is the caller's; the text it points at is the font's, and
/// lasts until `CloseOutline`.
///
/// NOTES:
/// A program draws a glyph by the first of `GlyphPaints`,
/// `GlyphDocument` and `GlyphPicture` that has it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GlyphPaints`, `GlyphPicture`
///
/// EXAMPLES:
/// ```zig
/// var document: truetype.Document = undefined;
/// if (tb.GlyphDocument(outline, glyph, &document)) {
///     const text = document.bytes.?[0..document.size];
///     _ = text;
/// }
/// ```
pub fn GlyphDocument(_: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, document: *truetype.Document) bool {
    const font: *const Font = @ptrCast(@alignCast(outline));
    document.* = documentOf(font, glyph) orelse {
        document.* = .{};
        return false;
    };
    return true;
}

/// The document that draws `glyph`; null for none.
pub fn documentOf(font: *const Font, glyph: u32) ?truetype.Document {
    const table = _outline.findTable(font, "SVG ") orelse return null;
    const offset = _outline.longIn(font, table, 2);
    if (offset == 0 or offset >= table.len) return null;
    const list: Table = .{ .at = table.at + offset, .len = table.len - offset };
    const count: u32 = _outline.wordIn(font, list, 0);
    if (count > (list.len -| 2) / 12) return null;
    var low: u32 = 0;
    var high: u32 = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const record = 2 + middle * 12;
        const first: u32 = _outline.wordIn(font, list, record);
        const last: u32 = _outline.wordIn(font, list, record + 2);
        if (glyph < first) {
            high = middle;
        } else if (glyph > last) {
            low = middle + 1;
        } else {
            const at = _outline.longIn(font, list, record + 4);
            const size = _outline.longIn(font, list, record + 8);
            if (at >= list.len or size == 0 or size > list.len - at) return null;
            return .{ .bytes = font.data + list.at + at, .size = size, .first = first, .last = last };
        }
    }
    return null;
}

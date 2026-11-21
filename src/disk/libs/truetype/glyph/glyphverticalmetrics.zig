// SPDX-License-Identifier: MIT
//! GlyphVerticalMetrics: a glyph's advance down a column of text and
//! its vertical origin, from the font's vertical metrics (`vhea`,
//! `vmtx`, `VORG`, `VVAR`) where it has them and from its horizontal
//! measures where not. `measure` is the reading, for the library's call
//! and for a tool on the host (`outlines.zig`).

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("../outline/_outline.zig");
const _variation = @import("../outline/_variation.zig");
const Font = _outline.Font;
const Table = _outline.Table;
const wordIn = _outline.wordIn;

/// A glyph's advance down a column of text and its vertical origin.
///
/// SYNOPSIS:
/// ```zig
/// fn GlyphVerticalMetrics(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, metrics: *truetype.VerticalMetrics) bool
/// ```
///
/// SINCE: 1.17. LVO -88.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `glyph` - the glyph's number, from `GlyphIndex`.
/// - `metrics` - where the measures go, in the font's units, y up.
///
/// RESULT:
/// True, the measures in `metrics`. False for a number past the font's
/// glyphs; `metrics` is then all 0.
///
/// BEHAVIOR:
/// For a glyph drawn upright in a column: `advance` is how far it moves
/// the point down, and the glyph is drawn with its point (`origin_x`,
/// `origin_y`) on the column's point.
///
/// - `advance` is the font's vertical metrics' (`vmtx`, as many as
///   `vhea` says, the last one's for the glyphs after them); a font
///   without them has its line's height, ascender less descender, as
///   `FontMetrics` gives them.
/// - `origin_x` is the middle of the glyph's horizontal advance.
/// - `origin_y` is the font's `VORG` table's for the glyph where it has
///   one; else the top of the glyph's box and its top side bearing from
///   `vmtx`; else, in a font without vertical metrics, the height that
///   sets the glyph's box in the middle of the line's height. A glyph
///   of no outline, a space, has its origin at the ascender.
///
/// A variable font away from its default has the advance and the top
/// side bearing its `VVAR` table moves them to, and the box its deltas
/// make.
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
/// A glyph set sideways in a column - a Latin letter turned with the
/// line - takes its horizontal measures, `GlyphMetrics`', not these.
///
/// BUGS:
/// A variable font without `VVAR` keeps its default's vertical advances:
/// the deltas of the glyphs' top and bottom points in `gvar` are not
/// read.
///
/// SEE ALSO:
/// `GlyphMetrics`, `GlyphAdvance`, `FontMetrics`
///
/// EXAMPLES:
/// ```zig
/// var column: truetype.VerticalMetrics = undefined;
/// if (tb.GlyphVerticalMetrics(outline, tb.GlyphIndex(outline, 0x6587), &column)) {
///     y += column.advance;
/// }
/// ```
pub fn GlyphVerticalMetrics(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, metrics: *truetype.VerticalMetrics) bool {
    const font: *const Font = @ptrCast(@alignCast(outline));
    metrics.* = .{};
    if (glyph >= font.glyph_count) return false;
    const table = _base.iface(tb);
    var measures: truetype.FontMetrics = undefined;
    table.FontMetrics(outline, &measures);
    var box: truetype.GlyphMetrics = .{};
    _ = table.GlyphMetrics(outline, glyph, &box);
    metrics.* = measure(font, glyph, &box, &measures);
    return true;
}

/// A glyph's measures in a column, from the font's tables, its box and
/// advance (`GlyphMetrics`'), and its line's measures (`FontMetrics`').
pub fn measure(font: *const Font, glyph: u32, box: *const truetype.GlyphMetrics, measures: *const truetype.FontMetrics) truetype.VerticalMetrics {
    const height = measures.ascender - measures.descender;
    var metrics: truetype.VerticalMetrics = .{ .origin_x = @divFloor(box.advance, 2) };
    const columns = columnsOf(font);
    metrics.advance = if (columns) |found| @max(0, @as(i32, wordIn(font, found.vmtx, rowOf(found, glyph) * 4)) + _variation.verticalDelta(font, glyph, .advance)) else height;
    if (originOf(font, glyph)) |origin| {
        metrics.origin_y = origin;
        return metrics;
    }
    const inked = box.x_max > box.x_min or box.y_max > box.y_min;
    if (!inked) {
        metrics.origin_y = measures.ascender;
    } else if (columns) |found| {
        metrics.origin_y = box.y_max + topBearingOf(font, found, glyph) + _variation.verticalDelta(font, glyph, .top);
    } else {
        metrics.origin_y = box.y_max + @divFloor(height - (box.y_max - box.y_min), 2);
    }
    return metrics;
}

/// The font's vertical metrics: `vmtx`, and how many of its records
/// have an advance (`vhea`'s count).
const Columns = struct { vmtx: Table, count: u32 };

/// The font's vertical metrics; null for a font without them, or with
/// tables too short for what they say.
fn columnsOf(font: *const Font) ?Columns {
    const vhea = _outline.findTable(font, "vhea") orelse return null;
    const vmtx = _outline.findTable(font, "vmtx") orelse return null;
    if (vhea.len < 36) return null;
    const count: u32 = wordIn(font, vhea, 34);
    if (count == 0 or vmtx.len < count * 4) return null;
    return .{ .vmtx = vmtx, .count = count };
}

/// The record of `vmtx` with a glyph's advance: its own, or the last.
fn rowOf(columns: Columns, glyph: u32) u32 {
    return @min(glyph, columns.count - 1);
}

/// A glyph's top side bearing: in its record, or, for a glyph past
/// those, in the bearings that follow them.
fn topBearingOf(font: *const Font, columns: Columns, glyph: u32) i32 {
    if (glyph < columns.count) return _outline.signedIn(font, columns.vmtx, glyph * 4 + 2);
    return _outline.signedIn(font, columns.vmtx, columns.count * 4 + (glyph - columns.count) * 2);
}

/// A glyph's vertical origin from the font's `VORG` table: its own
/// record, kept in the order of the glyphs, or the table's default; null
/// for a font without the table.
fn originOf(font: *const Font, glyph: u32) ?i32 {
    const vorg = _outline.findTable(font, "VORG") orelse return null;
    if (vorg.len < 8 or wordIn(font, vorg, 0) != 1) return null;
    const count: u32 = wordIn(font, vorg, 6);
    var low: u32 = 0;
    var high: u32 = @min(count, (vorg.len - 8) / 4);
    while (low < high) {
        const middle = (low + high) / 2;
        const number: u32 = wordIn(font, vorg, 8 + middle * 4);
        if (number == glyph) return _outline.signedIn(font, vorg, 8 + middle * 4 + 2);
        if (number < glyph) low = middle + 1 else high = middle;
    }
    return _outline.signedIn(font, vorg, 4);
}

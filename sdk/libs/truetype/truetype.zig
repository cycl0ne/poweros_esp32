// SPDX-License-Identifier: MIT
//! truetype.library's types and constants.
//!
//! truetype.library reads a TrueType font file and renders any size of it
//! into a font image (`graphics.fontimage`): each glyph's outline scaled
//! to the height asked, and its coverage of every pixel measured, in four
//! bits. The image is then a font like any other - diskfont.library puts
//! it on graphics' list and frees it when nobody holds it.
//!
//! Since 1.2 a font is read for drawing at any size and angle as well:
//! a character's glyph (`GlyphIndex`), its outline as lines and curves
//! in the font's units (`GlyphSegments`) - verbs and points as
//! vector.library's `AddSegments` takes them - its measures
//! (`GlyphMetrics`), the font's (`FontMetrics`), and how much two glyphs
//! are moved together (`Kerning`). SVG's text is drawn so. A program that
//! needs these looks for revision 2 or later in the library it opened.
//!
//! Open it with OpenLibrary(TRUETYPENAME, 1); its functions are in
//! sdk/interface/truetype.zig.

const graphics = @import("../graphics/graphics.zig");
const vector = @import("../vector/vector.zig");

/// The name to open it by.
pub const TRUETYPENAME = "truetype.library";
/// The version a caller of this SDK asks for.
pub const TRUETYPE_VERSION = 1;

/// A font file opened for rendering: its tables found and checked. What
/// it holds is the library's; the file's bytes stay the caller's, and must
/// last until `CloseOutline`.
pub const Outline = opaque {};

/// Codes `first` to `last`, both in: a part of what `RenderFontImage`
/// renders. Since 1.3.
pub const CodeRange = extern struct {
    first: u32,
    last: u32,
};

// --- glyphs as outlines (since 1.2) ---------------------------------------------

/// A glyph's measures, in the font's units, y up from the baseline.
pub const GlyphMetrics = extern struct {
    /// How far the glyph moves the point along the line.
    advance: i32 = 0,
    /// From the point to the left of the glyph's box.
    left_bearing: i32 = 0,
    /// The box of its outline; all 0 for a glyph of none, a space.
    x_min: i32 = 0,
    y_min: i32 = 0,
    x_max: i32 = 0,
    y_max: i32 = 0,
};

/// A font's measures, in its units, y up from the baseline. A measure
/// the file does not give is 0.
pub const FontMetrics = extern struct {
    /// The units of an em: the font drawn n pixels tall scales them by n
    /// over this.
    units_per_em: u32 = 0,
    glyph_count: u32 = 0,
    /// Above the baseline, below it (negative), and the gap between one
    /// line's descender and the next's ascender.
    ascender: i32 = 0,
    descender: i32 = 0,
    line_gap: i32 = 0,
    /// How tall a lower-case x is, and a capital.
    x_height: i32 = 0,
    cap_height: i32 = 0,
    /// The top of an underline (negative below the baseline), and how
    /// thick it is.
    underline_position: i32 = 0,
    underline_thickness: i32 = 0,
    /// The bottom of a line struck through, and how thick it is.
    strikeout_position: i32 = 0,
    strikeout_thickness: i32 = 0,
    /// The most verbs and points `GlyphSegments` gives for any glyph of
    /// the font: arrays this long hold every one.
    most_verbs: u32 = 0,
    most_points: u32 = 0,
    /// The styles the file says it is drawn in, as `styleOf`.
    style: graphics.FontStyle = graphics.FS_NORMAL,
};

/// A glyph's outline, as `GlyphSegments` gives it: in the caller's
/// arrays, and how much of them it took.
pub const Segments = extern struct {
    /// The verbs, a byte each: vector.library's `SEG_MOVE`, `SEG_LINE`,
    /// `SEG_QUAD` and `SEG_CLOSE`.
    verbs: [*]u8,
    /// Their points, in the font's units, y up from the glyph's origin
    /// on the baseline.
    points: [*]vector.Point,
    /// How many each array holds.
    verb_room: u32,
    point_room: u32,
    /// How many the glyph took - or, when they did not fit, needs.
    verb_count: u32 = 0,
    point_count: u32 = 0,
};

/// What `GlyphSegments` answers.
pub const TRUETYPE_OK: i32 = 0;
/// The arrays are too short: the counts say how long they must be.
pub const TRUETYPEERR_ROOM: i32 = -1;
/// No glyph of that number, or its data is damaged.
pub const TRUETYPEERR_GLYPH: i32 = -2;
/// There was not the memory to read it.
pub const TRUETYPEERR_NOMEM: i32 = -3;

/// Whether `bytes` start as a TrueType file: version 1.0 or 'true'.
///
/// INPUTS:
/// - `bytes` - the file's first four bytes at least.
pub fn isTrueType(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    const tag = @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
    return tag == 0x0001_0000 or tag == 0x7472_7565;
}

/// The styles a TrueType file says it is drawn in: `FSF_BOLD` and
/// `FSF_ITALIC`, from the style bits of its `head` table - a bold face of
/// a family says it is bold. None when the file has no `head` table, or
/// `bytes` end before it.
///
/// INPUTS:
/// - `bytes` - the file from its start, through its `head` table at least.
pub fn styleOf(bytes: []const u8) graphics.FontStyle {
    if (bytes.len < 12 or !isTrueType(bytes)) return graphics.FS_NORMAL;
    const tables = @as(usize, bytes[4]) << 8 | bytes[5];
    for (0..tables) |i| {
        const record = 12 + 16 * i;
        if (record + 16 > bytes.len) break;
        if (bytes[record] != 'h' or bytes[record + 1] != 'e' or bytes[record + 2] != 'a' or bytes[record + 3] != 'd') continue;
        const head = @as(usize, bytes[record + 8]) << 24 | @as(usize, bytes[record + 9]) << 16 |
            @as(usize, bytes[record + 10]) << 8 | bytes[record + 11];
        // macStyle, at 44 into the table: bit 0 bold, bit 1 italic.
        if (head + 46 > bytes.len) break;
        const bits = bytes[head + 45];
        var style: graphics.FontStyle = graphics.FS_NORMAL;
        if (bits & 1 != 0) style |= graphics.FSF_BOLD;
        if (bits & 2 != 0) style |= graphics.FSF_ITALIC;
        return style;
    }
    return graphics.FS_NORMAL;
}

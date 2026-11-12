// SPDX-License-Identifier: MIT
//! truetype.library's types and constants.
//!
//! truetype.library reads a TrueType font file and renders any size of it
//! into a font image (`graphics.fontimage`): each glyph's outline scaled
//! to the height asked, and its coverage of every pixel measured, in four
//! bits - or, of a font whose glyphs are pictures, each picture scaled to
//! it. The image is then a font like any other - diskfont.library puts
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
//! Since 1.4 a file may be a collection of fonts, and `OpenOutline`'s
//! tags say which one is meant; a character map of any format is read,
//! and the variation sequences beside it (`GlyphVariant`); a font says
//! what it is called (`FontName`); and any of its tables is handed out
//! as the file has it (`FontTable`), which is what
//! truetypeshaping.library reads the layout tables through. A font may
//! be without outlines and still maps, measures and names.
//!
//! Since 1.5 one glyph is rendered by its number (`RenderGlyph`), the
//! way a font image's glyphs are: what a text shaped into glyphs is drawn
//! with, since a glyph a font's lookups put in has no character to be
//! found by.
//!
//! Since 1.6 a font's outlines may be of cubic curves, in a `CFF ` table,
//! one font or many under one set of glyphs: such a file starts 'OTTO'.
//! It renders, maps and measures as any other, and `GlyphSegments` gives
//! its curves as `SEG_CUBIC`. Its hints are passed over.
//!
//! Since 1.7 a font without outlines whose glyphs are pictures is
//! rendered from them: pictures of coverage (`EBLC` and `EBDT`) into an
//! image of coverage, colour pictures (`CBLC` and `CBDT`, PNG files) into
//! one of colour (`rgba32`), which is what an emoji font is. Of a font's
//! sizes of pictures the nearest above the line's is taken and scaled to
//! it. A font of colour pictures is opened with compression.library.
//!
//! Since 1.8 a variable font - one file that draws a range of faces
//! along its axes, a weight from light to black - is opened at a place
//! on them (`TTA_Axes`) and reads as a font of that face: its glyphs'
//! outlines, their advances and the font's measures are that
//! instance's. `FontAxes` says which axes a font has, `FontInstance`
//! the places its designer named ("Semibold"), `FontCoordinates` where
//! an outline is as shaping tables count it, and `GlyphAdvance` one
//! glyph's advance. One outline is one instance; a second face of the
//! same file is a second outline over the same bytes. Since 1.9 a
//! variable font of cubic curves (a `CFF2` table) is read the same way.
//!
//! Since 1.10 a size is rendered with three heights on whole rows: the
//! baseline, the x height and the cap height, so that a line of text
//! stands on one row and its small and capital letters end on one. The
//! columns and the advances are as the outline has them. `TTA_Plain`
//! opens an outline that is rendered scaled and no more.
//!
//! Since 1.11 `VariationDelta` answers what an item of a store of
//! deltas adds at an outline's place: the number a layout table's
//! kerning or anchor is varied by, read from the bytes `FontTable`
//! hands out, by the rule the library varies its own advances and
//! measures by.
//!
//! Open it with OpenLibrary(TRUETYPENAME, 1); its functions are in
//! sdk/interface/truetype.zig.

const graphics = @import("../graphics/graphics.zig");
const utility = @import("../utility/utility.zig");
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
    /// the font: arrays this long hold every one. A font of cubic curves
    /// does not say how large its glyphs are: these hold one of 1024
    /// points in 128 contours, and a larger glyph answers
    /// `TRUETYPEERR_ROOM` with what it needs.
    most_verbs: u32 = 0,
    most_points: u32 = 0,
    /// The styles the file says it is drawn in, as `styleOf`.
    style: graphics.FontStyle = graphics.FS_NORMAL,
};

/// A glyph's outline, as `GlyphSegments` gives it: in the caller's
/// arrays, and how much of them it took.
pub const Segments = extern struct {
    /// The verbs, a byte each: vector.library's `SEG_MOVE`, `SEG_LINE`,
    /// `SEG_QUAD` and `SEG_CLOSE`, and since 1.6 `SEG_CUBIC` from a font
    /// of cubic curves.
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

/// What `GlyphSegments` and `RenderGlyph` answer.
pub const TRUETYPE_OK: i32 = 0;
/// The caller's room is too short: the counts say how long it must be.
pub const TRUETYPEERR_ROOM: i32 = -1;
/// No glyph of that number, its data is damaged, or - rendered - the
/// font has neither outlines nor pictures.
pub const TRUETYPEERR_GLYPH: i32 = -2;
/// There was not the memory to read it.
pub const TRUETYPEERR_NOMEM: i32 = -3;
/// A line of no rows, or of more than 4096. Since 1.5.
pub const TRUETYPEERR_ROWS: i32 = -4;

// --- a glyph by its number (since 1.5) ------------------------------------------

/// A glyph rendered for a line of some height, as `RenderGlyph` gives
/// it: its pixels in the caller's bytes, and its box and advance.
pub const GlyphImage = extern struct {
    /// Where the pixels go: the rows of the box one after another, each
    /// `glyph.pitch` bytes.
    pixels: [*]u8,
    /// How many bytes `pixels` holds.
    room: u32,
    /// How many the glyph took - or, when they did not fit, needs:
    /// `glyph.pitch` times `glyph.rows`. None for a glyph with no ink.
    size: u32 = 0,
    /// What a pixel is: `alpha4`, four bits of coverage, two pixels a
    /// byte, the left one high; or, of a font of colour pictures,
    /// `rgba32`, a byte each of red, green, blue and coverage.
    kind: graphics.fontimage.Kind = .alpha4,
    /// The box, from the point and from the top of the line, and the
    /// advance, in pixels. `data` is 0: where the pixels are kept is the
    /// caller's to say.
    glyph: graphics.fontimage.Glyph = .{},
};

// --- which font, its names and its tables (since 1.4) ---------------------------

/// `OpenOutline`'s tags start here.
pub const TTA_Dummy = utility.TAG_USER + 0x61200;
/// (u32) Which font of a collection, counted from 0: `fontCount` says how
/// many there are. A file of one font has font 0 only. Default 0.
pub const TTA_FontIndex = TTA_Dummy + 1;
/// ([*]const AxisValue) Where on a variable font's axes the outline is
/// opened: `TTA_AxisCount` values, each an axis by its tag and a value
/// in the axis' own units. An axis not named is at its default; a value
/// outside an axis' range is cut to it; a tag the font has no axis of
/// is passed over, and of two values for one axis the first counts.
/// Default: every axis at its default. Since 1.8.
pub const TTA_Axes = TTA_Dummy + 2;
/// (u32) How many values `TTA_Axes` points at. Default 0. Since 1.8.
pub const TTA_AxisCount = TTA_Dummy + 3;
/// (bool) The outline is rendered as it is drawn: no height of the font
/// is fitted to the rows, and the baseline lies where the ascender's
/// share of the line falls, between two rows as a rule. For a caller
/// that holds the pixels against the outline itself. Default false.
/// Since 1.10.
pub const TTA_Plain = TTA_Dummy + 4;

/// A place on one axis of a variable font: the axis by its tag
/// (`tableTag("wght")`) and a value in the axis' own units - a weight of
/// 650, a width of 87.5 percent. What `TTA_Axes` points at and
/// `FontInstance` fills. Since 1.8.
pub const AxisValue = extern struct {
    tag: u32,
    value: f32,
};

/// One axis of a variable font, as `FontAxes` gives it. Since 1.8.
pub const Axis = extern struct {
    /// The axis' four letters: `wght`, `wdth`, `opsz`, `ital`, `slnt`,
    /// or a font's own in capitals.
    tag: u32,
    /// The range of its values, and the one a font opened without
    /// `TTA_Axes` is at.
    minimum: f32,
    default: f32,
    maximum: f32,
    /// Where this outline was opened on it.
    value: f32,
    /// The axis' name ("Weight"), as the number `FontName` takes.
    name: u32,
    /// The font asks that the axis is not offered to a user.
    hidden: bool,
};

/// Which of a font's names `FontName` answers: the numbers of the `name`
/// table, of which these are the ones most asked for. Any other number
/// of the table is answered as well.
pub const TTNAME_COPYRIGHT: u32 = 0;
/// The family, as a font requester lists it: "Liberation Sans".
pub const TTNAME_FAMILY: u32 = 1;
/// The style within the family: "Bold Italic".
pub const TTNAME_STYLE: u32 = 2;
/// A name no other font has.
pub const TTNAME_UNIQUE: u32 = 3;
/// Family and style in one: "Liberation Sans Bold Italic".
pub const TTNAME_FULL: u32 = 4;
/// The version, as text: "Version 2.1.5".
pub const TTNAME_VERSION: u32 = 5;
/// The name a PostScript printer knows it by.
pub const TTNAME_POSTSCRIPT: u32 = 6;
/// What the font may be used for, and where that is written in full.
pub const TTNAME_LICENCE: u32 = 13;
pub const TTNAME_LICENCE_URL: u32 = 14;
/// The family and style of a family of more than four styles, where
/// they differ from `TTNAME_FAMILY` and `TTNAME_STYLE`.
pub const TTNAME_TYPO_FAMILY: u32 = 16;
pub const TTNAME_TYPO_STYLE: u32 = 17;

/// A table's four-letter tag as `FontTable` takes it: the first letter
/// highest.
///
/// INPUTS:
/// - `name` - the four letters, as the font's directory has them: "GSUB",
///   "OS/2", "cvt ".
pub fn tableTag(name: *const [4]u8) u32 {
    return @as(u32, name[0]) << 24 | @as(u32, name[1]) << 16 | @as(u32, name[2]) << 8 | name[3];
}

/// An item of a store of deltas as `VariationDelta` takes it. Since 1.11.
///
/// INPUTS:
/// - `outer` - the number of the store's data the item is in.
/// - `inner` - the number of its row there.
pub fn variationItem(outer: u16, inner: u16) u32 {
    return @as(u32, outer) << 16 | inner;
}

/// The four bytes at `at` as a number, the first highest; 0 where `bytes`
/// end before them.
fn long(bytes: []const u8, at: usize) u32 {
    if (at > bytes.len or bytes.len - at < 4) return 0;
    return @as(u32, bytes[at]) << 24 | @as(u32, bytes[at + 1]) << 16 | @as(u32, bytes[at + 2]) << 8 | bytes[at + 3];
}

/// Whether `bytes` start as a font file of one font: version 1.0 or
/// 'true', or 'OTTO', which a font of cubic curves starts with.
///
/// INPUTS:
/// - `bytes` - the file's first four bytes at least.
pub fn isTrueType(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    const tag = long(bytes, 0);
    return tag == 0x0001_0000 or tag == 0x7472_7565 or tag == 0x4F54_544F;
}

/// How many fonts a file holds: 1 for a TrueType file, what its header
/// says for a collection ('ttcf'), 0 for anything else. Since 1.4.
///
/// A collection's fonts are counted whatever their outlines are;
/// `OpenOutline` says whether one of them is read.
///
/// INPUTS:
/// - `bytes` - the file's first twelve bytes at least.
pub fn fontCount(bytes: []const u8) u32 {
    if (isTrueType(bytes)) return 1;
    if (bytes.len < 12 or long(bytes, 0) != tableTag("ttcf")) return 0;
    return long(bytes, 8);
}

/// Where in a file the table directory of its font `index` starts: 0 for
/// the one font of a TrueType file, what the header says for a font of a
/// collection. Null when the file holds no font of that number, the
/// place is outside the file, or what is there is no TrueType font.
/// Since 1.4.
///
/// A table's place, as a directory gives it, counts from the start of
/// the file in a collection too.
///
/// INPUTS:
/// - `bytes` - the file, whole.
/// - `index` - which font, from 0.
pub fn fontDirectory(bytes: []const u8, index: u32) ?u32 {
    if (isTrueType(bytes)) return if (index == 0 and bytes.len >= 12) 0 else null;
    if (index >= fontCount(bytes)) return null;
    const entry = 12 + @as(usize, index) * 4;
    if (entry > bytes.len or bytes.len - entry < 4) return null;
    const directory = long(bytes, entry);
    if (directory > bytes.len or bytes.len - directory < 12) return null;
    if (!isTrueType(bytes[directory..])) return null;
    return directory;
}

/// The styles `head`'s style bits say a font is drawn in: `FSF_BOLD` for
/// bit 0, `FSF_ITALIC` for bit 1. Since 1.4.
///
/// INPUTS:
/// - `bits` - the table's `macStyle`.
pub fn styleOfBits(bits: u32) graphics.FontStyle {
    var style: graphics.FontStyle = graphics.FS_NORMAL;
    if (bits & 1 != 0) style |= graphics.FSF_BOLD;
    if (bits & 2 != 0) style |= graphics.FSF_ITALIC;
    return style;
}

/// The styles a TrueType file says it is drawn in: `FSF_BOLD` and
/// `FSF_ITALIC`, from the style bits of its `head` table - a bold face of
/// a family says it is bold. None when the file has no `head` table, or
/// `bytes` end before it, and none for a collection: each of its fonts
/// says its own (`styleOfFont`).
///
/// INPUTS:
/// - `bytes` - the file from its start, through its `head` table at least.
pub fn styleOf(bytes: []const u8) graphics.FontStyle {
    if (!isTrueType(bytes)) return graphics.FS_NORMAL;
    return styleOfFont(bytes, 0);
}

/// The styles one font of a file says it is drawn in, as `styleOf`
/// answers them for a file of one font. None when the file holds no
/// font of that number.
///
/// INPUTS:
/// - `bytes` - the file from its start, through that font's `head` table
///   at least.
/// - `index` - which font, from 0: 0 for a file of one font, any of a
///   collection's.
pub fn styleOfFont(bytes: []const u8, index: u32) graphics.FontStyle {
    const directory: usize = fontDirectory(bytes, index) orelse return graphics.FS_NORMAL;
    const tables = @as(usize, bytes[directory + 4]) << 8 | bytes[directory + 5];
    for (0..tables) |i| {
        const record = directory + 12 + 16 * i;
        if (record + 16 > bytes.len) break;
        if (bytes[record] != 'h' or bytes[record + 1] != 'e' or bytes[record + 2] != 'a' or bytes[record + 3] != 'd') continue;
        const head = @as(usize, bytes[record + 8]) << 24 | @as(usize, bytes[record + 9]) << 16 |
            @as(usize, bytes[record + 10]) << 8 | bytes[record + 11];
        // macStyle, at 44 into the table: bit 0 bold, bit 1 italic.
        if (head > bytes.len or bytes.len - head < 46) break;
        return styleOfBits(bytes[head + 45]);
    }
    return graphics.FS_NORMAL;
}

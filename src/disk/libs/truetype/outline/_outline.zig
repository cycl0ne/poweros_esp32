// SPDX-License-Identifier: MIT
//! A TrueType file as the library reads it: its tables, the character
//! map, the horizontal metrics, and each glyph's contours.
//!
//! Everything is read in place from the caller's bytes, big-endian. A
//! table is where the font's directory says it is, checked once to lie
//! within the file; what is read of it afterwards is read by its place in
//! the table (`wordIn`, `longIn`), which answers 0 past the table's end.
//! A count the file gives is cut to what its table has room for before
//! anything is looked up by it. So a damaged file gives a missing glyph
//! and never a read outside it.
//!
//! A `Font` is written once, by `open`, and only read after that: every
//! other function here takes it const, and what a call needs to work in
//! is the caller's. Any number of tasks read one font at once.
//!
//! A glyph is a list of contours, each a closed loop of points, on the
//! curve or off it: two points on the curve are a line, one off it between
//! two on it the control point of a quadratic curve, and two off it in a
//! row have an implied point on the curve halfway between them. A
//! composite glyph is other glyphs, each moved and possibly scaled; they
//! are read into the same list, to a limited depth and number.
//!
//! Since 1.2 the measures a program drawing the outlines itself needs are
//! kept as well - the line gap, the x and capital heights, the underline
//! and the strike-out - and the `kern` table, if the font has one, found.
//!
//! Since 1.4 the font may be one of a collection, a character map of any
//! format is read, the variation sequences beside it are kept, and a font
//! need not have outlines: one whose glyphs are pictures has neither
//! `glyf` nor `loca`, and every glyph of it reads as one of no outline.
//!
//! Since 1.6 a font's outlines may be a `CFF ` table's in place of
//! `glyf` and `loca`: lines and cubic curves, read by `_cff.zig` into the
//! same list of contours, a curve as two control points (`Point.cubic`)
//! and the point it ends at. Such a font says nothing of its largest
//! glyph, and a glyph that does not fit the room it is read into says
//! what it needs (`Contours.short`). Since 1.9 a variable font's `CFF2`
//! table is read the same way, at the font's place on its axes.
//!
//! Since 1.7 a font without outlines may have its glyphs as pictures,
//! bitmaps at one size or several (`_strike.zig`): found here, and read
//! and scaled when a glyph is rendered (`render/_picture.zig`).
//!
//! Since 1.8 a font may be a variable one, opened at a place on its axes
//! (`_variation.zig`). At any place but the default a `glyf` glyph's
//! points are read with their deltas added, a composite's parts are
//! placed with theirs, and a glyph's advance and the font's measures are
//! that instance's. The points keep the fractions the deltas give them.
//! Reading a glyph's deltas takes room of its own (`Contours.vary`).

const sdk = @import("sdk");
const _cff = @import("_cff.zig");
const _strike = @import("_strike.zig");
const _variation = @import("_variation.zig");
const _macroman = @import("_macroman.zig");
const CompressionBase = sdk.interface.compression.CompressionBase;

/// A font file, opened: where its tables are and the measures rendering
/// needs. What `OpenOutline` answers, behind `truetype.Outline`.
pub const Font = struct {
    data: [*]const u8,
    size: u32,
    /// Where the font's table directory starts: 0, or where a collection's
    /// header says its font is.
    directory: u32,
    units_per_em: u32,
    /// Whether `loca` holds 32-bit offsets rather than halved 16-bit ones.
    loca_long: bool,
    glyph_count: u32,
    /// From `hhea`: above the baseline, below it (negative), in units.
    ascender: i32,
    descender: i32,
    hmetric_count: u32,
    /// The glyphs and the index into them; both of no length for a font
    /// without outlines.
    loca: Table,
    glyf: Table,
    hmtx: Table,
    /// The character map's subtable used, to the end of the `cmap` table,
    /// and its format (0, 2, 4, 6, 8, 10, 12 or 13).
    cmap: Table,
    cmap_format: u32,
    /// The map is in the Macintosh Roman encoding: a character is asked
    /// for by its byte there.
    cmap_roman: bool = false,
    /// The variation sequences' subtable (format 14); of no length when
    /// the font has none.
    variants: Table,
    /// The styles the file says it is drawn in (`FSF_BOLD`, `FSF_ITALIC`).
    style: sdk.graphics.FontStyle,
    /// From `hhea`, `OS/2` and `post` (since 1.2); 0 where not given.
    line_gap: i32,
    x_height: i32,
    cap_height: i32,
    /// The heights rendering fits to the rows (since 1.10): `x_height`
    /// and `cap_height`, or for a font that does not give one the top of
    /// its `x` and of its `H`; 0 for a height the font has neither of.
    fit_x_height: i32,
    fit_cap_height: i32,
    /// Whether the outline is rendered as it is drawn, no height fitted
    /// to the rows (`TTA_Plain`, since 1.10).
    plain: bool,
    underline_position: i32,
    underline_thickness: i32,
    strikeout_position: i32,
    strikeout_thickness: i32,
    /// The most points and contours of a glyph, simple or composite, from
    /// `maxp`; `default_points` and `default_contours` when it has none.
    max_points: u32,
    max_contours: u32,
    /// The `kern` table; of no length when the font has none.
    kern: Table,
    /// The `CFF ` table (since 1.6) or the `CFF2` table (since 1.9),
    /// read when the font has no `glyf`; its `table` of no length
    /// otherwise.
    cff: _cff.Cff,
    /// The font's pictures (since 1.7), read when it has no outlines;
    /// none otherwise.
    strikes: _strike.Strikes,
    /// compression.library, which unpacks a picture that is a PNG file:
    /// opened with the outline of such a font and closed with it, null
    /// for every other.
    compression: ?*CompressionBase,
    /// Where on its axes the font was opened (since 1.8); every
    /// coordinate 0 for a font without axes.
    vary: _variation.Variation,
};

/// What a glyph is read with when `maxp` does not say how large one is.
pub const default_points = 1024;
pub const default_contours = 128;

/// Where a table, or a part of one, is in the file. One that is handed
/// on lies within the file: `at + len` is no more than the file's size.
pub const Table = struct {
    at: u32 = 0,
    len: u32 = 0,
};

/// One point of a glyph, in font units: on the curve, or off it - the
/// control point of a quadratic curve, or with `cubic` one of the two a
/// cubic curve has, which stand in a row before the point it ends at.
pub const Point = struct {
    x: f32,
    y: f32,
    on: bool,
    cubic: bool = false,
};

/// A glyph's contours: `points`, and the index after each contour's last
/// point in `ends`.
pub const Contours = struct {
    points: []Point,
    ends: []u32,
    /// Room for one simple glyph's flags while its points are read.
    flags: []u8,
    point_count: u32 = 0,
    end_count: u32 = 0,
    /// The parts of composite glyphs read so far, of `max_parts`.
    part_count: u32 = 0,
    /// Set by `contours` when a glyph of cubic curves did not fit, with
    /// the points and contours it has: one more of each is room enough.
    short: bool = false,
    needed_points: u32 = 0,
    needed_ends: u32 = 0,
    /// Room for a glyph's deltas: what a font whose glyphs are varied
    /// (`isVaried`) is read with, and no glyph of it without.
    vary: ?_variation.Scratch = null,
};

/// The two bytes at `at` in the file, 0 where it ends before them.
pub fn u16At(font: *const Font, at: u32) u16 {
    if (at >= font.size or font.size - at < 2) return 0;
    return @as(u16, font.data[at]) << 8 | font.data[at + 1];
}

pub fn u32At(font: *const Font, at: u32) u32 {
    return @as(u32, u16At(font, at)) << 16 | u16At(font, at +| 2);
}

/// The byte `at` into `table`, 0 past its end.
pub fn byteIn(font: *const Font, table: Table, at: u32) u8 {
    if (at >= table.len) return 0;
    return font.data[table.at + at];
}

/// The two bytes `at` into `table`, 0 where it ends before them.
pub fn wordIn(font: *const Font, table: Table, at: u32) u16 {
    if (at >= table.len or table.len - at < 2) return 0;
    const from = table.at + at;
    return @as(u16, font.data[from]) << 8 | font.data[from + 1];
}

/// The same, signed.
pub fn signedIn(font: *const Font, table: Table, at: u32) i16 {
    return @bitCast(wordIn(font, table, at));
}

/// The three bytes `at` into `table`, 0 where it ends before them.
pub fn tripleIn(font: *const Font, table: Table, at: u32) u32 {
    if (at >= table.len or table.len - at < 3) return 0;
    const from = table.at + at;
    return @as(u32, font.data[from]) << 16 | @as(u32, font.data[from + 1]) << 8 | font.data[from + 2];
}

/// The four bytes `at` into `table`, 0 where it ends before them.
pub fn longIn(font: *const Font, table: Table, at: u32) u32 {
    if (at >= table.len or table.len - at < 4) return 0;
    const from = table.at + at;
    return @as(u32, font.data[from]) << 24 | @as(u32, font.data[from + 1]) << 16 | @as(u32, font.data[from + 2]) << 8 | font.data[from + 3];
}

/// What of `table` starts `offset` into it, to its end; null when that is
/// not within it.
fn partOf(table: Table, offset: u32) ?Table {
    if (offset >= table.len) return null;
    return .{ .at = table.at + offset, .len = table.len - offset };
}

/// The table of a four-letter tag, or null.
pub fn findTable(font: *const Font, tag: *const [4]u8) ?Table {
    return findTableByTag(font, sdk.truetype.tableTag(tag));
}

/// The table of a tag as `truetype.tableTag` makes it, or null: none of
/// that tag in the font's directory, or one that is not within the file.
pub fn findTableByTag(font: *const Font, tag: u32) ?Table {
    const count: u32 = u16At(font, font.directory +| 4);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const record = font.directory +| (12 + i * 16);
        if (record >= font.size or font.size - record < 16) return null;
        if (u32At(font, record) != tag) continue;
        const at = u32At(font, record + 8);
        const len = u32At(font, record + 12);
        if (at > font.size or len > font.size - at) return null;
        return .{ .at = at, .len = len };
    }
    return null;
}

/// The tables of the file's font `index` read and checked, at the place
/// on its axes the `axis_count` values at `axes` name; false if the file
/// has no font of that number or it lacks a table it needs.
pub fn open(font: *Font, data: [*]const u8, size: u32, index: u32, axes: ?[*]const sdk.truetype.AxisValue, axis_count: u32) bool {
    font.* = undefined;
    font.data = data;
    font.size = size;
    font.directory = sdk.truetype.fontDirectory(data[0..size], index) orelse return false;
    const head = findTable(font, "head") orelse return false;
    const hhea = findTable(font, "hhea") orelse return false;
    const maxp = findTable(font, "maxp") orelse return false;
    const cmap = findTable(font, "cmap") orelse return false;
    font.hmtx = findTable(font, "hmtx") orelse return false;
    // Outlines are both tables or neither.
    const loca = findTable(font, "loca");
    const glyf = findTable(font, "glyf");
    if ((loca == null) != (glyf == null)) return false;
    font.loca = loca orelse .{};
    font.glyf = glyf orelse .{};
    // Without them, the outlines a `CFF ` table has, or a `CFF2` table;
    // one that cannot be read is a font not read.
    font.cff = .{};
    if (glyf == null) {
        if (findTable(font, "CFF ")) |table| {
            font.cff = _cff.open(font, table, false) orelse return false;
        } else if (findTable(font, "CFF2")) |table| {
            font.cff = _cff.open(font, table, true) orelse return false;
        }
    }
    // A font without outlines is its pictures, if it has them; one with
    // outlines is drawn from those at every size.
    font.compression = null;
    font.strikes = if (hasOutlines(font)) .{} else _strike.open(font);
    if (head.len < 54 or hhea.len < 36 or maxp.len < 6) return false;
    font.units_per_em = wordIn(font, head, 18);
    font.loca_long = signedIn(font, head, 50) != 0;
    font.glyph_count = wordIn(font, maxp, 4);
    font.ascender = signedIn(font, hhea, 4);
    font.descender = signedIn(font, hhea, 6);
    font.hmetric_count = wordIn(font, hhea, 34);
    font.style = sdk.truetype.styleOfBits(wordIn(font, head, 44));
    font.line_gap = signedIn(font, hhea, 8);
    readMeasures(font, maxp);
    _variation.open(font, axes, axis_count);
    font.kern = findTable(font, "kern") orelse .{};
    if (font.units_per_em == 0 or font.hmetric_count == 0 or font.ascender <= font.descender) return false;
    font.plain = false;
    font.fit_x_height = 0;
    font.fit_cap_height = 0;
    if (!pickCmap(font, cmap)) return false;
    font.fit_x_height = fitHeight(font, font.x_height, 'x');
    font.fit_cap_height = fitHeight(font, font.cap_height, 'H');
    return true;
}

/// A height rendering fits to the rows: `given`, what the font says it
/// is, or for a font that says nothing the top of the box of `letter`,
/// whose top is flat. 0 for a font that has neither, and for one whose
/// glyphs have deltas where it is opened: a glyph's box is the
/// default's there.
fn fitHeight(font: *const Font, given: i32, letter: u32) i32 {
    if (given > 0) return given;
    if (!hasOutlines(font) or isVaried(font)) return 0;
    const glyph = glyphIndex(font, letter);
    if (glyph == 0) return 0;
    return @max(boxOf(font, glyph)[3], 0);
}

/// The measures `OS/2` and `post` give, and how large `maxp` says a glyph
/// may be.
fn readMeasures(font: *Font, maxp: Table) void {
    font.x_height = 0;
    font.cap_height = 0;
    font.underline_position = 0;
    font.underline_thickness = 0;
    font.strikeout_position = 0;
    font.strikeout_thickness = 0;
    if (findTable(font, "OS/2")) |os2| {
        if (os2.len >= 30) {
            font.strikeout_thickness = signedIn(font, os2, 26);
            font.strikeout_position = signedIn(font, os2, 28);
        }
        if (wordIn(font, os2, 0) >= 2 and os2.len >= 90) {
            font.x_height = signedIn(font, os2, 86);
            font.cap_height = signedIn(font, os2, 88);
        }
    }
    if (findTable(font, "post")) |post| {
        if (post.len >= 12) {
            font.underline_position = signedIn(font, post, 8);
            font.underline_thickness = signedIn(font, post, 10);
        }
    }
    font.max_points = default_points;
    font.max_contours = default_contours;
    // Version 1.0 says: the simple glyphs' most and the composites'.
    if (longIn(font, maxp, 0) == 0x0001_0000 and maxp.len >= 14) {
        font.max_points = @max(wordIn(font, maxp, 6), wordIn(font, maxp, 10));
        font.max_contours = @max(wordIn(font, maxp, 8), wordIn(font, maxp, 12));
    }
}

/// The character map's subtables to read. Of the ones that map
/// characters, a Unicode one before a symbol font's, and that before one
/// in the Macintosh Roman encoding; among those the format that reaches
/// furthest: 12, 13, 8, 10, 4, 2, 6, 0; the first of two alike. The variation sequences (format 14) are kept beside it. False
/// when the font has no map this library reads.
fn pickCmap(font: *Font, cmap: Table) bool {
    font.variants = .{};
    var best: ?Table = null;
    var best_rank: u32 = 0;
    var best_format: u32 = 0;
    var best_roman = false;
    const count: u32 = wordIn(font, cmap, 2);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const record = 4 + i * 8;
        if (record >= cmap.len or cmap.len - record < 8) break;
        const platform = wordIn(font, cmap, record);
        const encoding = wordIn(font, cmap, record + 2);
        const subtable = partOf(cmap, longIn(font, cmap, record + 4)) orelse continue;
        const format = wordIn(font, subtable, 0);
        if (format == 14) {
            if (platform == 0 and encoding == 5 and font.variants.len == 0) font.variants = subtable;
            continue;
        }
        const rank = cmapRank(platform, encoding, format);
        if (rank > best_rank) {
            best = subtable;
            best_rank = rank;
            best_format = format;
            best_roman = platform == 1 and encoding == 0;
        }
    }
    font.cmap = best orelse return false;
    font.cmap_format = best_format;
    font.cmap_roman = best_roman;
    return true;
}

/// How much a character map's subtable is preferred; 0 for one that is
/// not read. A symbol font's map (Windows, encoding 0) has its
/// characters where the font puts them, U+F020 to U+F0FF mostly, and is
/// taken when there is no Unicode one. One in the Macintosh Roman
/// encoding (the Macintosh platform, encoding 0) is the last resort, of
/// a font that has no other: its characters are that encoding's 256.
fn cmapRank(platform: u32, encoding: u32, format: u32) u32 {
    const unicode = (platform == 0 and encoding != 5) or (platform == 3 and (encoding == 1 or encoding == 10));
    const symbol = platform == 3 and encoding == 0;
    const roman = platform == 1 and encoding == 0;
    if (!unicode and !symbol and !roman) return 0;
    const reach: u32 = switch (format) {
        12 => 8,
        13 => 7,
        8 => 6,
        10 => 5,
        4 => 4,
        2 => 3,
        6 => 2,
        0 => 1,
        else => return 0,
    };
    return if (unicode) 32 + reach else if (symbol) 16 + reach else reach;
}

/// The glyph a character is, 0 (the missing glyph) when it has none or
/// the map names a glyph the font does not have.
pub fn glyphIndex(font: *const Font, code: u32) u32 {
    const glyph = mapped(font, code);
    return if (glyph < font.glyph_count) glyph else 0;
}

/// What the character map says `char` is, unchecked.
fn mapped(font: *const Font, char: u32) u32 {
    const map = font.cmap;
    const code: u32 = if (font.cmap_roman) _macroman.byteOf(char) orelse return 0 else char;
    switch (font.cmap_format) {
        // A byte a character, for the first 256.
        0 => return if (code < 256) byteIn(font, map, 6 + code) else 0,
        4 => return segmentGlyph(font, map, code),
        // One run of characters, 16-bit and 32-bit.
        6 => {
            const first: u32 = wordIn(font, map, 6);
            const count: u32 = wordIn(font, map, 8);
            if (code < first or code - first >= count) return 0;
            return wordIn(font, map, 10 + (code - first) * 2);
        },
        10 => {
            const first = longIn(font, map, 12);
            const count: u32 = @min(longIn(font, map, 16), (map.len -| 20) / 2);
            if (code < first or code - first >= count) return 0;
            return wordIn(font, map, 20 + (code - first) * 2);
        },
        2 => return byteGlyph(font, map, code),
        // Groups behind a header of its own: the bits that say which
        // characters are 32 bits wide are a reader of bytes' business.
        8 => return groupGlyph(font, map, code, 8204, false),
        12 => return groupGlyph(font, map, code, 12, false),
        13 => return groupGlyph(font, map, code, 12, true),
        else => return 0,
    }
}

/// Format 2: characters of one byte and of two. A first byte names a
/// subheader - a run of second bytes, what to add to a glyph, and where
/// the run's glyphs are listed; the subheader 0 is the one of the
/// characters of one byte.
fn byteGlyph(font: *const Font, map: Table, code: u32) u32 {
    if (code > 0xFFFF) return 0;
    const keys: u32 = 6;
    const subheaders: u32 = keys + 256 * 2;
    const high = code >> 8;
    const low = code & 0xFF;
    const key: u32 = wordIn(font, map, keys + (if (code < 0x100) low else high) * 2);
    // A character of one byte is the subheader 0's, and a first byte that
    // names it is no first byte.
    if ((code < 0x100) != (key == 0)) return 0;
    const subheader = subheaders + key;
    const first: u32 = wordIn(font, map, subheader);
    const count: u32 = wordIn(font, map, subheader + 2);
    const delta: u32 = wordIn(font, map, subheader + 4);
    const offset: u32 = wordIn(font, map, subheader + 6);
    if (low < first or low - first >= count) return 0;
    const glyph: u32 = wordIn(font, map, subheader + 6 + offset + (low - first) * 2);
    if (glyph == 0) return 0;
    return (glyph + delta) & 0xFFFF;
}

/// Format 4: segments of the basic plane sorted by their last character,
/// each a first character and either what to add to a character to get
/// its glyph or where the segment's glyphs are listed.
fn segmentGlyph(font: *const Font, map: Table, code: u32) u32 {
    if (code > 0xFFFF) return 0;
    const said: u32 = wordIn(font, map, 6) / 2;
    const segments: u32 = @min(said, (map.len -| 16) / 8);
    const ends: u32 = 14;
    const starts = ends + segments * 2 + 2;
    const deltas = starts + segments * 2;
    const offsets = deltas + segments * 2;
    // The first segment that does not end before the character.
    var low: u32 = 0;
    var high: u32 = segments;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (wordIn(font, map, ends + mid * 2) < code) low = mid + 1 else high = mid;
    }
    if (low == segments) return 0;
    const start: u32 = wordIn(font, map, starts + low * 2);
    if (start > code) return 0;
    const delta: u32 = wordIn(font, map, deltas + low * 2);
    const offset: u32 = wordIn(font, map, offsets + low * 2);
    if (offset == 0) return (code + delta) & 0xFFFF;
    const glyph: u32 = wordIn(font, map, offsets + low * 2 + offset + (code - start) * 2);
    if (glyph == 0) return 0;
    return (glyph + delta) & 0xFFFF;
}

/// Formats 8, 12 and 13: groups of characters sorted by their last, each
/// a first character and a glyph - the first character's, the others
/// following it, or with `every` (13) every character's. The groups'
/// count is at `counted`, the groups behind it.
fn groupGlyph(font: *const Font, map: Table, code: u32, counted: u32, every: bool) u32 {
    const list = counted + 4;
    const groups: u32 = @min(longIn(font, map, counted), (map.len -| list) / 12);
    var low: u32 = 0;
    var high: u32 = groups;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (longIn(font, map, list + mid * 12 + 4) < code) low = mid + 1 else high = mid;
    }
    if (low == groups) return 0;
    const group = list + low * 12;
    const first = longIn(font, map, group);
    if (first > code) return 0;
    const glyph = longIn(font, map, group + 8);
    if (every) return glyph;
    return glyph +| (code - first);
}

/// The glyph of `code` followed by the variation selector `selector`: the
/// one the font draws that sequence with, which is the character's own
/// where the font says the sequence looks as the character does. 0 when
/// the font has no such sequence.
pub fn glyphVariant(font: *const Font, code: u32, selector: u32) u32 {
    const map = font.variants;
    if (map.len < 10) return 0;
    // A record a selector, sorted: the selector, where the characters
    // that keep their glyph are, where the ones that change it are.
    const records: u32 = @min(longIn(font, map, 6), (map.len - 10) / 11);
    var low: u32 = 0;
    var high: u32 = records;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const record = 10 + mid * 11;
        const here = tripleIn(font, map, record);
        if (here < selector) {
            low = mid + 1;
        } else if (here > selector) {
            high = mid;
        } else {
            if (changedGlyph(font, map, longIn(font, map, record + 7), code)) |glyph| {
                return if (glyph < font.glyph_count) glyph else 0;
            }
            if (keepsGlyph(font, map, longIn(font, map, record + 3), code)) return glyphIndex(font, code);
            return 0;
        }
    }
    return 0;
}

/// The glyph a selector's list at `offset` gives `code`: characters
/// sorted, each with its glyph. Null when it is not in the list.
fn changedGlyph(font: *const Font, map: Table, offset: u32, code: u32) ?u32 {
    if (offset == 0) return null;
    const list = partOf(map, offset) orelse return null;
    const count: u32 = @min(longIn(font, list, 0), (list.len -| 4) / 5);
    var low: u32 = 0;
    var high: u32 = count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = 4 + mid * 5;
        const here = tripleIn(font, list, entry);
        if (here < code) {
            low = mid + 1;
        } else if (here > code) {
            high = mid;
        } else {
            return wordIn(font, list, entry + 3);
        }
    }
    return null;
}

/// Whether `code` is in a selector's list at `offset` of the characters
/// that keep their glyph: ranges sorted, each a first character and how
/// many follow it.
fn keepsGlyph(font: *const Font, map: Table, offset: u32, code: u32) bool {
    if (offset == 0) return false;
    const list = partOf(map, offset) orelse return false;
    const count: u32 = @min(longIn(font, list, 0), (list.len -| 4) / 4);
    var low: u32 = 0;
    var high: u32 = count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = 4 + mid * 4;
        const first = tripleIn(font, list, entry);
        if (first > code) {
            high = mid;
        } else if (code - first > byteIn(font, list, entry + 3)) {
            low = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// How far a glyph moves the point, in units, at the font's instance.
pub fn advanceOf(font: *const Font, glyph: u32) i32 {
    const index = @min(glyph, font.hmetric_count - 1);
    const plain: i32 = wordIn(font, font.hmtx, index * 4);
    if (!font.vary.varied) return plain;
    return _variation.advanceOf(font, glyph, plain);
}

/// Whether the font's glyphs are read with deltas: a font of `glyf`
/// outlines, away from its default instance, that has them.
pub fn isVaried(font: *const Font) bool {
    return font.vary.gvar.len != 0;
}

/// What a glyph's side points are counted from: how many points come
/// before them - a simple glyph's own, a composite's parts - and the x
/// of its left side, its box's left less its left side bearing.
pub const Sides = struct {
    points: u32,
    left: i32,
};

pub fn sidesOf(font: *const Font, glyph: u32) Sides {
    const bearing = leftBearingOf(font, glyph);
    const data = glyphData(font, glyph) orelse return .{ .points = 0, .left = -bearing };
    if (data.len < 10) return .{ .points = 0, .left = -bearing };
    const left = signedIn(font, data, 2) - bearing;
    const count = signedIn(font, data, 0);
    if (count < 0) return .{ .points = partsOf(font, data) orelse 0, .left = left };
    if (count == 0) return .{ .points = 0, .left = left };
    const contour_count: u32 = @intCast(count);
    return .{ .points = @as(u32, wordIn(font, data, 10 + (contour_count - 1) * 2)) + 1, .left = left };
}

/// From a glyph's origin to the left of its box, in units.
pub fn leftBearingOf(font: *const Font, glyph: u32) i32 {
    if (glyph < font.hmetric_count) return signedIn(font, font.hmtx, glyph * 4 + 2);
    if (glyph >= font.glyph_count) return 0;
    return signedIn(font, font.hmtx, font.hmetric_count * 4 + (glyph - font.hmetric_count) * 2);
}

/// Whether the font's glyphs are pictures: a font without outlines that
/// has them as bitmaps.
pub fn hasPictures(font: *const Font) bool {
    return _strike.has(font);
}

/// Whether the font has outlines at all: `glyf`, or a `CFF ` or `CFF2`
/// table.
pub fn hasOutlines(font: *const Font) bool {
    return font.glyf.len != 0 or font.cff.table.len != 0;
}

/// Whether the font's outlines are a `CFF ` or a `CFF2` table's.
pub fn isCubic(font: *const Font) bool {
    return font.glyf.len == 0 and font.cff.table.len != 0;
}

/// A glyph's box: x min, y min, x max, y max; all 0 for a glyph of no
/// outline. As its data's header gives it, and for a `CFF ` table's
/// glyph, which has none, the box of its points.
pub fn boxOf(font: *const Font, glyph: u32) [4]i32 {
    if (isCubic(font)) return _cff.boxOf(font, glyph);
    if (hasPictures(font)) return _strike.boxOf(font, glyph);
    const data = glyphData(font, glyph) orelse return .{ 0, 0, 0, 0 };
    if (data.len < 10) return .{ 0, 0, 0, 0 };
    // From the glyph's left side point, as its contours are.
    const left = sidesOf(font, glyph).left;
    return .{ signedIn(font, data, 2) - left, signedIn(font, data, 4), signedIn(font, data, 6) - left, signedIn(font, data, 8) };
}

/// How much further apart `left` and `right` are drawn side by side, in
/// units: what the `kern` table's horizontal pairs say, summed over its
/// subtables (one that overrides putting the sum aside first). 0 for a
/// font without one, and for Apple's version of the table.
pub fn kerningOf(font: *const Font, left: u32, right: u32) i32 {
    const kern = font.kern;
    if (kern.len < 4 or wordIn(font, kern, 0) != 0) return 0;
    if (left > 0xFFFF or right > 0xFFFF) return 0;
    const key = left << 16 | right;
    var total: i32 = 0;
    var at: u32 = 4;
    var n = wordIn(font, kern, 2);
    while (n > 0 and at < kern.len and kern.len - at >= 14) : (n -= 1) {
        const length: u32 = wordIn(font, kern, at + 2);
        const coverage = wordIn(font, kern, at + 4);
        const pairs: u32 = wordIn(font, kern, at + 6);
        // Format 0, horizontal, not a minimum, not across the line.
        if (coverage >> 8 == 0 and coverage & 0x7 == 0x1) {
            const first = at + 14;
            if (pairs * 6 <= kern.len - first) {
                if (pairValue(font, kern, first, pairs, key)) |value| {
                    total = if (coverage & 0x8 != 0) value else total +| value;
                }
            }
        }
        // A table of many pairs overflows its 16-bit length: its pairs say
        // how long it is.
        const span = @max(length, 14 + pairs * 6);
        at +|= span;
    }
    return total;
}

/// The value of the pair `key` (left << 16 | right) among `count` pairs
/// sorted by it, `first` into `kern`; null if it is not there.
fn pairValue(font: *const Font, kern: Table, first: u32, count: u32, key: u32) ?i32 {
    var low: u32 = 0;
    var high: u32 = count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const at = first + mid * 6;
        const here = longIn(font, kern, at);
        if (here == key) return signedIn(font, kern, at + 4);
        if (here < key) low = mid + 1 else high = mid;
    }
    return null;
}

/// Where a glyph's data is in `glyf`, and how long; null for a glyph of
/// no outline.
fn glyphData(font: *const Font, glyph: u32) ?Table {
    if (glyph >= font.glyph_count) return null;
    const start, const end = if (font.loca_long)
        .{ longIn(font, font.loca, glyph * 4), longIn(font, font.loca, glyph * 4 + 4) }
    else
        .{ @as(u32, wordIn(font, font.loca, glyph * 2)) * 2, @as(u32, wordIn(font, font.loca, glyph * 2 + 2)) * 2 };
    if (end <= start or end > font.glyf.len) return null;
    return .{ .at = font.glyf.at + start, .len = end - start };
}

/// How deep composite glyphs may nest, and how many parts one glyph may
/// be put together from, counted through every depth: far more than a
/// font's glyphs have, and few enough that parts naming parts in a
/// damaged file come to an end.
const max_depth = 4;
const max_parts = 256;

/// A glyph's contours added to `into`, transformed by `m` (a, b, c, d,
/// dx, dy: x' = a x + c y + dx, y' = b x + d y + dy). False when they do
/// not fit or the data is damaged; for a glyph of cubic curves that does
/// not fit, `into.short` says so and how much it needs.
///
/// A glyph asked for itself (`depth` 0) is moved so that its left side
/// point is at 0: its points are where its left side bearing and its
/// advance count from, also in a font whose `hmtx` bearing is not its
/// box's left. A part of another glyph stays where its points are, as
/// the other places it; a glyph of cubic curves is drawn from where its
/// program starts.
pub fn contours(font: *const Font, glyph: u32, into: *Contours, m: [6]f32, depth: u32) bool {
    into.short = false;
    if (isCubic(font)) return _cff.contours(font, glyph, into, m);
    const data = glyphData(font, glyph) orelse return true;
    var placed = m;
    if (depth == 0) {
        const origin: f32 = @floatFromInt(_variation.originOf(font, glyph));
        placed[4] -= m[0] * origin;
        placed[5] -= m[1] * origin;
    }
    const count = signedIn(font, data, 0);
    if (count >= 0) return simple(font, glyph, data, @intCast(count), into, placed);
    if (depth >= max_depth) return false;
    return composite(font, glyph, data, into, placed, depth);
}

fn simple(font: *const Font, glyph: u32, data: Table, contour_count: u32, into: *Contours, m: [6]f32) bool {
    if (contour_count == 0) return true;
    const ends_at: u32 = 10;
    if (data.len < ends_at + contour_count * 2 + 2) return false;
    const point_count: u32 = @as(u32, wordIn(font, data, ends_at + (contour_count - 1) * 2)) + 1;
    if (point_count > into.points.len - into.point_count) return false;
    if (contour_count > into.ends.len - into.end_count) return false;
    if (point_count > into.flags.len) return false;
    // Each contour ends where the one before it did or later, and none
    // past the last point.
    const base = into.point_count;
    var before: u32 = 0;
    var i: u32 = 0;
    while (i < contour_count) : (i += 1) {
        const end = @as(u32, wordIn(font, data, ends_at + i * 2)) + 1;
        if (end < before or end > point_count) return false;
        before = end;
        into.ends[into.end_count + i] = base + end;
    }
    const instructions: u32 = wordIn(font, data, ends_at + contour_count * 2);
    var at = ends_at + contour_count * 2 + 2 + instructions;
    const limit = data.len;

    // The flags, a byte a point unless one says it repeats.
    const points = into.points[base..][0..point_count];
    const flags_of = into.flags;
    var n: u32 = 0;
    while (n < point_count) {
        if (at >= limit) return false;
        const flag = byteIn(font, data, at);
        at += 1;
        flags_of[n] = flag;
        n += 1;
        if (flag & 8 != 0) {
            if (at >= limit) return false;
            var repeat = byteIn(font, data, at);
            at += 1;
            while (repeat > 0 and n < point_count) : (repeat -= 1) {
                flags_of[n] = flag;
                n += 1;
            }
        }
    }
    // x, then y: a byte with the flag's sign, the same as before, or a
    // word. `at` is never past `limit`.
    var x: i32 = 0;
    for (0..point_count) |p| {
        const flag = flags_of[p];
        if (flag & 2 != 0) {
            if (at >= limit) return false;
            const step: i32 = byteIn(font, data, at);
            at += 1;
            x += if (flag & 16 != 0) step else -step;
        } else if (flag & 16 == 0) {
            if (limit - at < 2) return false;
            x += signedIn(font, data, at);
            at += 2;
        }
        points[p].x = @floatFromInt(x);
        points[p].on = flag & 1 != 0;
        points[p].cubic = false;
    }
    var y: i32 = 0;
    for (0..point_count) |p| {
        const flag = flags_of[p];
        if (flag & 4 != 0) {
            if (at >= limit) return false;
            const step: i32 = byteIn(font, data, at);
            at += 1;
            y += if (flag & 32 != 0) step else -step;
        } else if (flag & 32 == 0) {
            if (limit - at < 2) return false;
            y += signedIn(font, data, at);
            at += 2;
        }
        points[p].y = @floatFromInt(y);
    }
    // At an instance each point moves by its delta, before the glyph is
    // placed.
    if (isVaried(font)) {
        const scratch = if (into.vary) |*room| room else return false;
        if (!_variation.glyphDeltas(font, glyph, scratch, points, into.ends[into.end_count..][0..contour_count], base, point_count)) return false;
        for (points, scratch.sums[0..point_count]) |*p, sum| {
            p.x = @floatCast(@as(f64, p.x) + sum[0]);
            p.y = @floatCast(@as(f64, p.y) + sum[1]);
        }
    }
    for (points) |*p| {
        const px = p.x;
        const py = p.y;
        p.x = m[0] * px + m[2] * py + m[4];
        p.y = m[1] * px + m[3] * py + m[5];
    }
    into.point_count += point_count;
    into.end_count += contour_count;
    return true;
}

/// How many parts a composite glyph's data names; null when the data
/// ends within one.
fn partsOf(font: *const Font, data: Table) ?u32 {
    var parts: u32 = 0;
    var at: u32 = 10;
    const limit = data.len;
    while (at < limit and limit - at >= 4) {
        const flags = wordIn(font, data, at);
        at += 4;
        const offsets: u32 = if (flags & 1 != 0) 4 else 2;
        const scales: u32 = if (flags & 8 != 0) 2 else if (flags & 0x40 != 0) 4 else if (flags & 0x80 != 0) 8 else 0;
        if (limit - at < offsets + scales) return null;
        at += offsets + scales;
        parts += 1;
        if (flags & 0x20 == 0) break;
    }
    return parts;
}

fn composite(font: *const Font, glyph: u32, data: Table, into: *Contours, m: [6]f32, depth: u32) bool {
    // At an instance each part's offset moves by a delta. They are kept
    // aside while the parts are read, which read deltas of their own in
    // the same room, and given up when this glyph is done.
    var moved: []const [2]f64 = &.{};
    const mark = if (into.vary) |room| room.offset_count else 0;
    defer if (into.vary) |*room| {
        room.offset_count = mark;
    };
    if (isVaried(font)) {
        const scratch = if (into.vary) |*room| room else return false;
        const parts = partsOf(font, data) orelse return false;
        if (parts > scratch.offsets.len - scratch.offset_count) return false;
        if (!_variation.glyphDeltas(font, glyph, scratch, &.{}, &.{}, 0, parts)) return false;
        const kept = scratch.offsets[scratch.offset_count..][0..parts];
        @memcpy(kept, scratch.sums[0..parts]);
        scratch.offset_count += parts;
        moved = kept;
    }
    var number: u32 = 0;
    var at: u32 = 10;
    const limit = data.len;
    while (at < limit and limit - at >= 4) : (number += 1) {
        if (into.part_count >= max_parts) return false;
        into.part_count += 1;
        const flags = wordIn(font, data, at);
        const part = wordIn(font, data, at + 2);
        at += 4;
        // What follows of this part: its offsets, bytes or words, and its
        // scale, if it has one.
        const offsets: u32 = if (flags & 1 != 0) 4 else 2;
        const scales: u32 = if (flags & 8 != 0) 2 else if (flags & 0x40 != 0) 4 else if (flags & 0x80 != 0) 8 else 0;
        if (limit - at < offsets + scales) return false;
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (flags & 1 != 0) {
            dx = @floatFromInt(signedIn(font, data, at));
            dy = @floatFromInt(signedIn(font, data, at + 2));
            at += 4;
        } else {
            dx = @floatFromInt(@as(i8, @bitCast(byteIn(font, data, at))));
            dy = @floatFromInt(@as(i8, @bitCast(byteIn(font, data, at + 1))));
            at += 2;
        }
        // Offsets that name points to match are not followed: the part
        // stays where it was drawn.
        if (flags & 2 == 0) {
            dx = 0;
            dy = 0;
        } else if (number < moved.len) {
            dx = @floatCast(@as(f64, dx) + moved[number][0]);
            dy = @floatCast(@as(f64, dy) + moved[number][1]);
        }
        var a: f32 = 1;
        var b: f32 = 0;
        var c: f32 = 0;
        var d: f32 = 1;
        if (flags & 8 != 0) {
            a = f2dot14(font, data, at);
            d = a;
            at += 2;
        } else if (flags & 0x40 != 0) {
            a = f2dot14(font, data, at);
            d = f2dot14(font, data, at + 2);
            at += 4;
        } else if (flags & 0x80 != 0) {
            a = f2dot14(font, data, at);
            b = f2dot14(font, data, at + 2);
            c = f2dot14(font, data, at + 4);
            d = f2dot14(font, data, at + 6);
            at += 8;
        }
        // The part's own transform, then the whole glyph's.
        const own = [6]f32{
            m[0] * a + m[2] * b,
            m[1] * a + m[3] * b,
            m[0] * c + m[2] * d,
            m[1] * c + m[3] * d,
            m[0] * dx + m[2] * dy + m[4],
            m[1] * dx + m[3] * dy + m[5],
        };
        if (!contours(font, part, into, own, depth + 1)) return false;
        if (flags & 0x20 == 0) break;
    }
    return true;
}

fn f2dot14(font: *const Font, data: Table, at: u32) f32 {
    return @as(f32, @floatFromInt(signedIn(font, data, at))) / 16384.0;
}

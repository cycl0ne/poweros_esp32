// SPDX-License-Identifier: MIT
//! A font's pictures: where a font without outlines keeps its glyphs as
//! bitmaps, and what each one measures.
//!
//! Two tables hold them. One lists where the pictures are (`CBLC`, or
//! `EBLC`), the other is the pictures (`CBDT`, or `EBDT`). The list is a
//! strike for each size the font was drawn at: how many pixels an em is
//! across and down, how many bits a pixel has, and ranges of glyphs. A
//! range says in which form its glyphs' pictures are kept and where each
//! one starts, in one of five ways (a start for every glyph, as four
//! bytes or two; pictures all of one size; and the two of those that
//! name their glyphs one by one).
//!
//! A picture is, with its measures or after them:
//!
//! | Form | Formats | What it is |
//! |---|---|---|
//! | `rows` | 1, 6 | pixels of 1, 2, 4 or 8 bits, each row from a new byte |
//! | `bits` | 2, 5, 7 | the same, one row straight after the other |
//! | `parts` | 8, 9 | other glyphs of the strike, each put at a place |
//! | `png` | 17, 18, 19 | a PNG file |
//!
//! The measures are the picture's width and rows, where its left edge is
//! from the point and its top from the baseline, in the strike's pixels;
//! they stand in front of the picture (five bytes, or eight) or, for
//! pictures all of one size, once in the list.
//!
//! `CBLC` and `CBDT` are read for PNG files in strikes of 32 bits a
//! pixel, `EBLC` and `EBDT` for the other forms in strikes of 1, 2, 4 or
//! 8; a font with both is read by the first pair.
//!
//! Nothing is taken on trust. A count is cut to what its table has room
//! for, at most `most_strikes` strikes are looked at, every place is
//! worked out in 64 bits and checked against its table before it is
//! read, and a picture that does not lie within the table is a glyph
//! without one.

const _outline = @import("_outline.zig");
const Font = _outline.Font;
const Table = _outline.Table;

/// The pictures of a font: nothing of it set for a font without.
pub const Strikes = struct {
    /// The list of where the pictures are.
    places: Table = .{},
    /// The pictures.
    pictures: Table = .{},
    /// How many strikes are read.
    count: u32 = 0,
    /// PNG files in colour, not coverage.
    colour: bool = false,
};

/// The most strikes of a font that are looked at.
pub const most_strikes = 64;

/// The bytes of one strike in the list, and of the list's header.
const strike_bytes = 48;
const header_bytes = 8;

/// One size the font's pictures were drawn at.
pub const Strike = struct {
    /// Its ranges of glyphs, from the start of the list, and how many.
    ranges: u32 = 0,
    range_count: u32 = 0,
    /// The glyphs it may have pictures of.
    first: u32 = 0,
    last: u32 = 0,
    /// Pixels an em, across and down.
    ppem_x: u32 = 0,
    ppem_y: u32 = 0,
    /// Bits a pixel.
    depth: u32 = 0,
};

/// A picture's measures, in its strike's pixels.
pub const Metrics = struct {
    width: u32 = 0,
    rows: u32 = 0,
    /// From the point to the picture's left edge.
    left: i32 = 0,
    /// From the baseline up to the picture's top.
    top: i32 = 0,
};

/// How a picture's bytes are read.
pub const Form = enum { rows, bits, parts, png };

/// One glyph's picture: found, measured, not yet read.
pub const Picture = struct {
    strike: Strike,
    metrics: Metrics,
    form: Form,
    /// The picture after its measures: for `parts` from the count of
    /// them, for `png` the file.
    bytes: Table,
};

/// One of a picture's parts: a glyph of the same strike and where its
/// picture's left top corner goes in this one.
pub const Part = struct {
    glyph: u32,
    x: i32,
    y: i32,
};

/// The font's pictures found: the colour ones before the others, and
/// none for a font that has neither pair of tables whole.
pub fn open(font: *const Font) Strikes {
    const pairs = [_][2]*const [4]u8{ .{ "CBLC", "CBDT" }, .{ "EBLC", "EBDT" } };
    for (pairs, 0..) |pair, nth| {
        const places = _outline.findTable(font, pair[0]) orelse continue;
        const pictures = _outline.findTable(font, pair[1]) orelse continue;
        if (places.len < header_bytes) continue;
        const major = _outline.wordIn(font, places, 0);
        if (major != 2 and major != 3) continue;
        const room = (places.len - header_bytes) / strike_bytes;
        const count = @min(_outline.longIn(font, places, 4), room, most_strikes);
        if (count == 0) continue;
        return .{ .places = places, .pictures = pictures, .count = count, .colour = nth == 0 };
    }
    return .{};
}

/// Whether the font has pictures to read.
pub fn has(font: *const Font) bool {
    return font.strikes.count != 0;
}

/// Strike `nth` of the list, its ranges cut to the list's room; one of no
/// ranges when they start outside it.
fn strikeAt(font: *const Font, nth: u32) Strike {
    const places = font.strikes.places;
    const at = header_bytes + nth * strike_bytes;
    const ranges = _outline.longIn(font, places, at);
    if (ranges > places.len) return .{};
    return .{
        .ranges = ranges,
        .range_count = @min(_outline.longIn(font, places, at + 8), (places.len - ranges) / 8),
        .first = _outline.wordIn(font, places, at + 40),
        .last = _outline.wordIn(font, places, at + 42),
        .ppem_x = _outline.byteIn(font, places, at + 44),
        .ppem_y = _outline.byteIn(font, places, at + 45),
        .depth = _outline.byteIn(font, places, at + 46),
    };
}

/// Whether a strike's pictures are ones this font is read for.
fn readable(font: *const Font, strike: Strike) bool {
    if (strike.ppem_x == 0 or strike.ppem_y == 0) return false;
    if (font.strikes.colour) return strike.depth == 32;
    return strike.depth == 1 or strike.depth == 2 or strike.depth == 4 or strike.depth == 8;
}

/// The picture of `glyph` for a line `rows` tall: of the strikes that
/// have one, the smallest whose em is no fewer pixels than the line's,
/// and the largest when none is; the first of two alike. With no height
/// asked, the largest. Null for a glyph no strike has a picture of.
pub fn pictureOf(font: *const Font, glyph: u32, rows: ?u32) ?Picture {
    // An em of `ppem` pixels against the line's: both sides times the
    // line's units and the strike's pixels, so nothing is divided.
    const span: u64 = @intCast(font.ascender - font.descender);
    const wanted: ?u64 = if (rows) |r| @as(u64, r) * font.units_per_em else null;
    var best: ?Picture = null;
    var best_enough = false;
    var nth: u32 = 0;
    while (nth < font.strikes.count) : (nth += 1) {
        const strike = strikeAt(font, nth);
        if (!readable(font, strike) or glyph < strike.first or glyph > strike.last) continue;
        const enough = if (wanted) |w| strike.ppem_y * span >= w else false;
        if (best) |so_far| {
            if (best_enough and !enough) continue;
            if (best_enough == enough) {
                // Among those large enough the smaller, else the larger.
                if (enough and strike.ppem_y >= so_far.strike.ppem_y) continue;
                if (!enough and strike.ppem_y <= so_far.strike.ppem_y) continue;
            }
        }
        const found = pictureIn(font, strike, glyph) orelse continue;
        best = found;
        best_enough = enough;
    }
    return best;
}

/// The picture of `glyph` in one strike, or null.
pub fn pictureIn(font: *const Font, strike: Strike, glyph: u32) ?Picture {
    const places = font.strikes.places;
    var nth: u32 = 0;
    while (nth < strike.range_count) : (nth += 1) {
        const entry = strike.ranges + nth * 8;
        const first = _outline.wordIn(font, places, entry);
        const last = _outline.wordIn(font, places, entry + 2);
        if (glyph < first or glyph > last) continue;
        const range = @as(u64, strike.ranges) + _outline.longIn(font, places, entry + 4);
        if (located(font, strike, range, glyph, glyph - first)) |picture| return picture;
    }
    return null;
}

/// Two and four bytes of the list at a place worked out in 64 bits; 0
/// outside it.
fn wordAt(font: *const Font, at: u64) u32 {
    if (at >= font.strikes.places.len) return 0;
    return _outline.wordIn(font, font.strikes.places, @intCast(at));
}

fn longAt(font: *const Font, at: u64) u32 {
    if (at >= font.strikes.places.len) return 0;
    return _outline.longIn(font, font.strikes.places, @intCast(at));
}

/// A glyph's picture by the range at `range` in the list: `nth` is the
/// glyph counted from the range's first.
fn located(font: *const Font, strike: Strike, range: u64, glyph: u32, nth: u32) ?Picture {
    const places = font.strikes.places;
    if (range + 8 > places.len) return null;
    const image_format = wordAt(font, range + 2);
    const base: u64 = longAt(font, range + 4);
    var shared: ?Metrics = null;
    var from: u64 = 0;
    var to: u64 = 0;
    switch (wordAt(font, range)) {
        // A start for each glyph and one more, four bytes each.
        1 => {
            const at = range + 8 + @as(u64, nth) * 4;
            if (at + 8 > places.len) return null;
            from = longAt(font, at);
            to = longAt(font, at + 4);
        },
        // Pictures all of one size, with the measures of them all.
        2 => {
            if (range + 20 > places.len) return null;
            const each: u64 = longAt(font, range + 8);
            shared = measures(font, places, @intCast(range + 12));
            from = @as(u64, nth) * each;
            to = from + each;
        },
        // A start for each glyph and one more, two bytes each.
        3 => {
            const at = range + 8 + @as(u64, nth) * 2;
            if (at + 4 > places.len) return null;
            from = wordAt(font, at);
            to = wordAt(font, at + 2);
        },
        // The glyphs named, in order, each with its start, and one more.
        4 => {
            if (range + 12 > places.len) return null;
            const room = (places.len - range - 12) / 4;
            if (room == 0) return null;
            const count = @min(longAt(font, range + 8), room - 1);
            const found = named(font, range + 12, 4, count, glyph) orelse return null;
            from = wordAt(font, range + 12 + found * 4 + 2);
            to = wordAt(font, range + 12 + (found + 1) * 4 + 2);
        },
        // The glyphs named, in order, their pictures all of one size.
        5 => {
            if (range + 24 > places.len) return null;
            const each: u64 = longAt(font, range + 8);
            shared = measures(font, places, @intCast(range + 12));
            const count = @min(longAt(font, range + 20), (places.len - range - 24) / 2);
            const found = named(font, range + 24, 2, count, glyph) orelse return null;
            from = found * each;
            to = from + each;
        },
        else => return null,
    }
    if (to <= from) return null;
    const pictures = font.strikes.pictures;
    if (base + to > pictures.len) return null;
    const data = Table{ .at = pictures.at + @as(u32, @intCast(base + from)), .len = @intCast(to - from) };
    return framed(font, strike, image_format, shared, data);
}

/// Which of `count` entries of `each` bytes from `at`, sorted by the
/// glyph each starts with, is `glyph`'s; null when none is.
fn named(font: *const Font, at: u64, each: u64, count: u64, glyph: u32) ?u64 {
    var low: u64 = 0;
    var high: u64 = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const here = wordAt(font, at + middle * each);
        if (here == glyph) return middle;
        if (here < glyph) low = middle + 1 else high = middle;
    }
    return null;
}

/// The measures at `at` in `table`: rows, width, left, top. The same in
/// the five bytes in front of a picture and in the first four of eight.
fn measures(font: *const Font, table: Table, at: u32) Metrics {
    const left: i8 = @bitCast(_outline.byteIn(font, table, at + 2));
    const top: i8 = @bitCast(_outline.byteIn(font, table, at + 3));
    return .{
        .rows = _outline.byteIn(font, table, at),
        .width = _outline.byteIn(font, table, at + 1),
        .left = left,
        .top = top,
    };
}

/// A picture's measures taken off the front of its data, by its format;
/// null for a format that is not read, data too short for it, a PNG
/// file in a font of coverage or anything else in one of colour.
fn framed(font: *const Font, strike: Strike, format: u32, shared: ?Metrics, data: Table) ?Picture {
    var front: u32 = 0;
    var metrics = Metrics{};
    switch (format) {
        1, 2, 8, 17 => front = 5,
        6, 7, 9, 18 => front = 8,
        5, 19 => metrics = shared orelse return null,
        else => return null,
    }
    const form: Form = switch (format) {
        1, 6 => .rows,
        2, 5, 7 => .bits,
        8, 9 => .parts,
        else => .png,
    };
    if ((form == .png) != font.strikes.colour) return null;
    if (front != 0) metrics = measures(font, data, 0);
    // Format 8 has a byte of nothing after its measures.
    if (format == 8) front += 1;
    if (data.len < front) return null;
    var bytes = Table{ .at = data.at + front, .len = data.len - front };
    if (form == .png) {
        if (bytes.len < 4) return null;
        const length = _outline.longIn(font, bytes, 0);
        if (length > bytes.len - 4) return null;
        bytes = .{ .at = bytes.at + 4, .len = length };
    }
    return .{ .strike = strike, .metrics = metrics, .form = form, .bytes = bytes };
}

/// How many parts a picture of parts has, cut to what its data holds.
pub fn partCount(font: *const Font, picture: *const Picture) u32 {
    if (picture.bytes.len < 2) return 0;
    return @min(_outline.wordIn(font, picture.bytes, 0), (picture.bytes.len - 2) / 4);
}

/// Part `nth` of a picture of parts.
pub fn partAt(font: *const Font, picture: *const Picture, nth: u32) Part {
    const at = 2 + nth * 4;
    const x: i8 = @bitCast(_outline.byteIn(font, picture.bytes, at + 2));
    const y: i8 = @bitCast(_outline.byteIn(font, picture.bytes, at + 3));
    return .{ .glyph = _outline.wordIn(font, picture.bytes, at), .x = x, .y = y };
}

/// A glyph's box in units, as its largest picture's measures give it: x
/// min, y min, x max, y max, widened to whole units; all 0 for a glyph
/// without a picture.
pub fn boxOf(font: *const Font, glyph: u32) [4]i32 {
    const picture = pictureOf(font, glyph, null) orelse return .{ 0, 0, 0, 0 };
    const m = picture.metrics;
    const em: i64 = font.units_per_em;
    const across: i64 = picture.strike.ppem_x;
    const down: i64 = picture.strike.ppem_y;
    const width: i64 = m.width;
    const rows: i64 = m.rows;
    return .{
        @intCast(@divFloor(m.left * em, across)),
        @intCast(@divFloor((m.top - rows) * em, down)),
        @intCast(-@divFloor(-(m.left + width) * em, across)),
        @intCast(-@divFloor(-m.top * em, down)),
    };
}

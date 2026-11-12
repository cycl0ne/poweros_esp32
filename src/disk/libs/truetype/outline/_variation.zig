// SPDX-License-Identifier: MIT
//! A variable font's variations: where on its axes an outline was
//! opened, and what that moves. Since 1.8.
//!
//! A variable font is one file that draws a range of faces: it has axes
//! (`fvar`) - a weight from light to black, a width - and tables that
//! say how its glyphs and measures change along them. An outline is
//! opened at one place on the axes, its instance, and reads as a font of
//! that face from then on.
//!
//! `open` takes the axis values asked, in the font's own units (a weight
//! of 650), and makes of each a coordinate from -1 to 1 with the axis'
//! default at 0: the value cut to the axis' range, its distance from the
//! default as a part of the range on that side, that part bent as the
//! `avar` table's map for the axis says, and the result rounded to 14
//! bits of fraction. The coordinates are kept with the font; with all of
//! them 0 the font is at its default instance, nothing here is asked
//! again, and it reads as a font without variations does.
//!
//! What changes is stored as deltas, each belonging to a region of the
//! axes: a start, a peak and an end on each axis that takes part. At the
//! peak the delta counts whole, towards the start and the end less, in a
//! straight line, and outside them not at all; over several axes the
//! parts are multiplied (`factor`). A value at an instance is its
//! default plus the sum of its deltas, each times its region's part.
//!
//! - `gvar` has, for each glyph, deltas of its points in groups, one
//!   group a region. A group may name only some points: the others of a
//!   contour follow the named ones on either side of them, each
//!   coordinate by itself (`between`). After a glyph's own points come
//!   four more, of which the first two are its left and its right side:
//!   their deltas are how its advance changes. A composite glyph has a
//!   delta for each part's offset in place of points.
//! - `HVAR` has the advances' deltas in an item variation store, a table
//!   of regions and of rows of deltas, found by two numbers; a map says
//!   which row is a glyph's. It is read in place of `gvar`'s side points
//!   when the font has it.
//! - `MVAR` has the deltas of the font's measures in such a store, by a
//!   tag for each.
//! - A `CFF2` table has its glyphs' deltas in their programs, after the
//!   numbers they belong to, and a store of its own that says which
//!   regions they are for (`storeRegions`, `storePart`; the programs
//!   are `_cff.zig`'s). Since 1.9.
//!
//! An item variation store is read by one reader, over its bytes and
//! the coordinates of a place (`deltaIn`): within the bytes and nowhere
//! else, a count cut to what they hold, an offset of 0 naming nothing.
//! `HVAR`'s and `MVAR`'s stores are read through it at the font's place
//! (`storeDelta`), and since 1.11 `VariationDelta` reads any store's
//! bytes with it, rounded once (`wholeDelta`) - the stores of tables the
//! library hands out and does not read, `GDEF`'s for the shaper.
//!
//! The sums are made in 64-bit floating point, the deltas added in the
//! file's order, and a point's delta is added to it before it is
//! rounded to the 32 bits a point is kept in: the same steps on every
//! machine, so an instance has the same outlines everywhere.
//!
//! Nothing here keeps state: what reading a glyph's deltas works in is
//! the caller's (`Scratch`), allocated with the room the glyph is read
//! into, and only for a font that is not at its default.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _outline = @import("_outline.zig");
const Font = _outline.Font;
const Table = _outline.Table;
const Point = _outline.Point;
const byteIn = _outline.byteIn;
const wordIn = _outline.wordIn;
const signedIn = _outline.signedIn;
const longIn = _outline.longIn;

/// How many axes a font is varied on. One with more is read at its
/// default instance.
pub const max_axes = 32;

/// How many parts' offsets are kept while composite glyphs are read: as
/// many as one glyph may be put together from.
pub const max_offsets = 256;

/// Where on its axes a font was opened, and the tables that say what
/// that changes. Written once, by `open`.
pub const Variation = struct {
    /// How many axes the font has: `fvar`'s count, cut to what the table
    /// holds. 0 for a font without variations.
    axis_count: u32,
    /// `fvar`, where its axes start, and how long one is.
    fvar: Table,
    axes_at: u32,
    axis_size: u32,
    /// Its named instances: where they start, how many, how long one is.
    instances_at: u32,
    instance_count: u32,
    instance_size: u32,
    /// Each axis' coordinate, -16384 to 16384 for -1 to 1, and its value
    /// in the font's units, as cut to the axis' range.
    coords: [max_axes]i16,
    values: [max_axes]f32,
    /// Whether any coordinate is not 0.
    varied: bool,
    /// The glyphs' deltas, and the advances'; empty when the font has
    /// none or the table is not for this font's axes.
    gvar: Table,
    hvar: Table,
};

/// What a glyph's deltas are read in: room for the points of the largest
/// glyph and the four after them.
pub const Scratch = struct {
    /// Each point's delta at the font's instance.
    sums: [][2]f64,
    /// One group's deltas as the file has them, and which points it names.
    deltas: [][2]i32,
    touched: []bool,
    /// The offsets' deltas of the composite glyphs being read, the
    /// outermost first; `offset_count` of them are in use.
    offsets: [][2]f64,
    offset_count: u32 = 0,

    /// How many points room for a glyph of `points` points holds: a
    /// composite glyph may have more parts than the font's largest glyph
    /// has points.
    fn mostOf(points: u32) u32 {
        return @max(points, max_offsets) + 4;
    }

    /// The bytes the room for a glyph of `points` points takes, with
    /// what bringing it to an address of eight takes.
    pub fn bytes(points: u32) u32 {
        const most = mostOf(points);
        return 8 + most * (@sizeOf([2]f64) + @sizeOf([2]i32) + 1) + max_offsets * @sizeOf([2]f64);
    }

    /// The room laid out in `bytes(points)` bytes at `memory`.
    pub fn within(memory: [*]u8, points: u32) Scratch {
        const most = mostOf(points);
        const start = (@intFromPtr(memory) + 7) & ~@as(usize, 7);
        const sums: [*][2]f64 = @ptrFromInt(start);
        const offsets: [*][2]f64 = sums + most;
        const deltas: [*][2]i32 = @ptrCast(offsets + max_offsets);
        const touched: [*]bool = @ptrCast(deltas + most);
        return .{
            .sums = sums[0..most],
            .deltas = deltas[0..most],
            .touched = touched[0..most],
            .offsets = offsets[0..max_offsets],
            .offset_count = 0,
        };
    }
};

/// What of `table` starts `offset` into it, to its end; null when that is
/// not within it.
fn partOf(table: Table, offset: u32) ?Table {
    if (offset >= table.len) return null;
    return .{ .at = table.at + offset, .len = table.len - offset };
}

/// A number of 16 bits of fraction.
fn fixed(bits: u32) f64 {
    return @as(f64, @floatFromInt(@as(i32, @bitCast(bits)))) / 65536.0;
}

/// A number of 14 bits of fraction.
fn fraction(bits: i16) f64 {
    return @as(f64, @floatFromInt(bits)) / 16384.0;
}

/// The whole number nearest `value`, a half upward; held to what an
/// `i32` keeps with room to add to.
fn rounded(value: f64) i32 {
    const whole = @floor(value + 0.5);
    // Asked so that what is not a number is caught as well.
    if (!(whole > -1073741824.0)) return -1073741824;
    if (whole > 1073741824.0) return 1073741824;
    return @intFromFloat(whole);
}

/// The font's variations found and its place on the axes worked out from
/// the `count` axis values at `values`; then the measures `MVAR` moves
/// brought to that place. Sets every field of `font.vary`; called by
/// `_outline.open` once the font's tables and measures are read.
pub fn open(font: *Font, values: ?[*]const truetype.AxisValue, count: u32) void {
    const vary = &font.vary;
    vary.axis_count = 0;
    vary.fvar = .{};
    vary.axes_at = 0;
    vary.axis_size = 0;
    vary.instances_at = 0;
    vary.instance_count = 0;
    vary.instance_size = 0;
    vary.coords = @splat(0);
    vary.values = @splat(0);
    vary.varied = false;
    vary.gvar = .{};
    vary.hvar = .{};

    const fvar = _outline.findTable(font, "fvar") orelse return;
    if (wordIn(font, fvar, 0) != 1) return;
    const axes_at: u32 = wordIn(font, fvar, 4);
    const axis_size: u32 = wordIn(font, fvar, 10);
    if (axis_size < 20 or axes_at >= fvar.len) return;
    const stated: u32 = wordIn(font, fvar, 8);
    const held: u32 = (fvar.len - axes_at) / axis_size;
    vary.fvar = fvar;
    vary.axes_at = axes_at;
    vary.axis_size = axis_size;
    vary.axis_count = @min(stated, held);
    // The instances follow the axes, each a name and a value an axis.
    // A font without an axis has no place to name.
    const instance_size: u32 = wordIn(font, fvar, 14);
    const instances_at = axes_at + stated * axis_size;
    if (stated != 0 and stated <= held and instance_size >= 4 + stated * 4 and instances_at < fvar.len) {
        const instances: u32 = wordIn(font, fvar, 12);
        vary.instances_at = instances_at;
        vary.instance_size = instance_size;
        vary.instance_count = @min(instances, (fvar.len - instances_at) / instance_size);
    }
    if (vary.axis_count == 0 or vary.axis_count > max_axes) return;

    const avar = _outline.findTable(font, "avar") orelse Table{};
    var axis: u32 = 0;
    while (axis < vary.axis_count) : (axis += 1) {
        const record = axes_at + axis * axis_size;
        const tag = longIn(font, fvar, record);
        const lower = fixed(longIn(font, fvar, record + 4));
        const middle = fixed(longIn(font, fvar, record + 8));
        const upper = fixed(longIn(font, fvar, record + 12));
        var value = middle;
        if (values) |given| {
            for (given[0..count]) |one| {
                if (one.tag != tag) continue;
                value = one.value;
                break;
            }
        }
        // An axis whose range is not in order does not vary. The value
        // is cut to the range, what is not a number to its start.
        if (!(lower <= middle and middle <= upper)) value = middle;
        if (!(value >= lower)) value = lower;
        if (value > upper) value = upper;
        vary.values[axis] = @floatCast(value);
        const bent = mapped(font, avar, axis, normalized(value, lower, middle, upper));
        const whole = rounded(bent * 16384.0);
        vary.coords[axis] = @intCast(@max(-16384, @min(16384, whole)));
        if (vary.coords[axis] != 0) vary.varied = true;
    }
    if (!vary.varied) return;

    // The tables of deltas, each only if it is for this many axes.
    if (font.glyf.len != 0) {
        if (_outline.findTable(font, "gvar")) |gvar| {
            if (gvar.len >= 20 and wordIn(font, gvar, 0) == 1 and wordIn(font, gvar, 4) == vary.axis_count) vary.gvar = gvar;
        }
    }
    if (_outline.findTable(font, "HVAR")) |hvar| {
        if (hvar.len >= 20 and wordIn(font, hvar, 0) == 1) vary.hvar = hvar;
    }
    measures(font);
}

/// A value's distance from the axis' default, as a part of the range on
/// its side: -1 at `lower`, 0 at `middle`, 1 at `upper`.
fn normalized(value: f64, lower: f64, middle: f64, upper: f64) f64 {
    if (value == middle or lower == upper) return 0;
    if ((value < middle and lower != middle) or (value > middle and upper == middle)) return (value - middle) / (middle - lower);
    return (value - middle) / (upper - middle);
}

/// `value` as `avar`'s map for `axis` bends it: the map's pairs say
/// where some values go, and one between two of them goes between where
/// they go, in a straight line; one outside them all keeps its distance
/// from the nearest. Unchanged without a table of version 1 or a map for
/// the axis.
fn mapped(font: *const Font, avar: Table, axis: u32, value: f64) f64 {
    if (avar.len < 8 or wordIn(font, avar, 0) != 1 or axis >= wordIn(font, avar, 6)) return value;
    var at: u32 = 8;
    var before: u32 = 0;
    while (before < axis) : (before += 1) at +|= 2 + @as(u32, wordIn(font, avar, at)) * 4;
    const pairs: u32 = wordIn(font, avar, at);
    at +|= 2;
    if (pairs == 0 or at >= avar.len or (avar.len - at) / 4 < pairs) return value;

    // Of two pairs for one value the later counts.
    var exact: ?f64 = null;
    var least = [2]f64{ 0, 0 };
    var most = [2]f64{ 0, 0 };
    var below: ?[2]f64 = null;
    var above: ?[2]f64 = null;
    var pair: u32 = 0;
    while (pair < pairs) : (pair += 1) {
        const from = fraction(signedIn(font, avar, at + pair * 4));
        const to = fraction(signedIn(font, avar, at + pair * 4 + 2));
        if (from == value) exact = to;
        if (pair == 0 or from <= least[0]) least = .{ from, to };
        if (pair == 0 or from >= most[0]) most = .{ from, to };
        if (from < value and (below == null or from >= below.?[0])) below = .{ from, to };
        if (from > value and (above == null or from <= above.?[0])) above = .{ from, to };
    }
    if (exact) |to| return to;
    if (value < least[0]) return value + least[1] - least[0];
    if (value > most[0]) return value + most[1] - most[0];
    const low = below orelse return value;
    const high = above orelse return value;
    return low[1] + (high[1] - low[1]) * (value - low[0]) / (high[0] - low[0]);
}

/// The measures `MVAR` has deltas for, of the ones the library keeps,
/// brought to the font's instance: each its default plus its delta,
/// rounded.
fn measures(font: *Font) void {
    const mvar = _outline.findTable(font, "MVAR") orelse return;
    if (mvar.len < 12 or wordIn(font, mvar, 0) != 1) return;
    const record_size: u32 = wordIn(font, mvar, 6);
    const count: u32 = wordIn(font, mvar, 8);
    const store_at: u32 = wordIn(font, mvar, 10);
    if (record_size < 8 or store_at == 0) return;
    const store = partOf(mvar, store_at) orelse return;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const record = 12 + index * record_size;
        if (record >= mvar.len or mvar.len - record < 8) return;
        const measure: *i32 = switch (longIn(font, mvar, record)) {
            truetype.tableTag("xhgt") => &font.x_height,
            truetype.tableTag("cpht") => &font.cap_height,
            truetype.tableTag("undo") => &font.underline_position,
            truetype.tableTag("unds") => &font.underline_thickness,
            truetype.tableTag("stro") => &font.strikeout_position,
            truetype.tableTag("strs") => &font.strikeout_thickness,
            else => continue,
        };
        measure.* += rounded(storeDelta(font, store, wordIn(font, mvar, record + 4), wordIn(font, mvar, record + 6)));
    }
}

// --- regions --------------------------------------------------------------------

/// How much of a region's delta counts on one axis, at the coordinate
/// `value`: 1 at the peak, falling in a straight line to 0 at `lower`
/// and at `upper`, and 0 outside them. An axis that takes no part - a
/// peak of 0 - counts 1, as does one whose three are out of order or
/// lie on both sides of 0 with the peak not on it.
fn factor(value: i32, lower: i32, peak: i32, upper: i32) f64 {
    if (peak == 0) return 1;
    if (lower > peak or peak > upper) return 1;
    if (lower < 0 and upper > 0) return 1;
    if (value == peak) return 1;
    if (value <= lower or upper <= value) return 0;
    if (value < peak) return @as(f64, @floatFromInt(value - lower)) / @as(f64, @floatFromInt(peak - lower));
    return @as(f64, @floatFromInt(value - upper)) / @as(f64, @floatFromInt(peak - upper));
}

/// How much a group of `gvar`'s deltas counts at the font's coordinates.
/// `peak` is a coordinate an axis; `bounds`, of a group that has them,
/// the starts and the ends. A group without them reaches from 0 to its
/// peak on each axis.
fn groupPart(font: *const Font, peak: Table, bounds: ?[2]Table) f64 {
    var part: f64 = 1;
    var axis: u32 = 0;
    while (axis < font.vary.axis_count) : (axis += 1) {
        const top: i32 = signedIn(font, peak, axis * 2);
        const lower: i32 = if (bounds) |b| signedIn(font, b[0], axis * 2) else @min(top, 0);
        const upper: i32 = if (bounds) |b| signedIn(font, b[1], axis * 2) else @max(top, 0);
        part *= factor(font.vary.coords[axis], lower, top, upper);
        if (part == 0) return 0;
    }
    return part;
}

/// The bytes of `table`, a part of the font's file.
fn bytesOf(font: *const Font, table: Table) []const u8 {
    return font.data[table.at..][0..table.len];
}

/// Where the font is on its axes: a coordinate an axis. None for a font
/// of more axes than are kept, which is at its default.
pub fn placeOf(font: *const Font) []const i16 {
    if (font.vary.axis_count > max_axes) return &.{};
    return font.vary.coords[0..font.vary.axis_count];
}

/// The two bytes `at` into `bytes`, 0 where they end before them.
fn wordOf(bytes: []const u8, at: u32) u16 {
    if (at >= bytes.len or bytes.len - at < 2) return 0;
    return @as(u16, bytes[at]) << 8 | bytes[at + 1];
}

/// The same, signed.
fn signedOf(bytes: []const u8, at: u32) i16 {
    return @bitCast(wordOf(bytes, at));
}

/// The four bytes `at` into `bytes`, 0 where they end before them.
fn longOf(bytes: []const u8, at: u32) u32 {
    if (at >= bytes.len or bytes.len - at < 4) return 0;
    return @as(u32, bytes[at]) << 24 | @as(u32, bytes[at + 1]) << 16 | @as(u32, bytes[at + 2]) << 8 | bytes[at + 3];
}

/// What of `bytes` starts `offset` into them, to their end; null for an
/// offset of 0, which says there is none, and one not within them.
fn tailOf(bytes: []const u8, offset: u32) ?[]const u8 {
    if (offset == 0 or offset >= bytes.len) return null;
    return bytes[offset..];
}

/// How many regions of `axes` axes each the region list `list` has: the
/// count it says, cut to the ones that lie within it.
fn regionCount(list: []const u8, axes: u32) u32 {
    const said: u32 = wordOf(list, 2);
    if (axes == 0 or list.len < 4) return 0;
    const held = (list.len - 4) / (axes * 6);
    return if (held < said) @intCast(held) else said;
}

/// How much region `region` of an item variation store's region list
/// counts at the coordinates `coords`. The list is for that many axes.
fn regionPart(list: []const u8, coords: []const i16, region: u32) f64 {
    var part: f64 = 1;
    const axes: u32 = @intCast(coords.len);
    for (coords, 0..) |coord, axis| {
        const at = 4 + (region * axes + @as(u32, @intCast(axis))) * 6;
        part *= factor(coord, signedOf(list, at), signedOf(list, at + 2), signedOf(list, at + 4));
        if (part == 0) return 0;
    }
    return part;
}

/// The delta of an item of the item variation store `store` at the
/// coordinates `coords`, one an axis: row `inner` of its data `outer`,
/// each of the row's deltas times its region's part, summed in the
/// order they are stored. 0 for an item the store does not have, for a
/// store that is not for that many axes, and for no coordinates; a
/// delta for a region the list does not hold adds nothing. `regions`,
/// where there is one, gets how many deltas the row read has - 0 when
/// none was read.
///
/// The one reader of such a store: the font's own tables' (`HVAR`,
/// `MVAR`) and, through `VariationDelta`, a caller's.
pub fn deltaIn(store: []const u8, coords: []const i16, outer: u32, inner: u32, regions: ?*u32) f64 {
    if (regions) |into| into.* = 0;
    if (coords.len == 0) return 0;
    if (store.len < 8 or wordOf(store, 0) != 1) return 0;
    const list = tailOf(store, longOf(store, 2)) orelse return 0;
    if (wordOf(list, 0) != coords.len) return 0;
    const region_count = regionCount(list, @intCast(coords.len));
    if (outer >= wordOf(store, 6) or outer >= (store.len - 8) / 4) return 0;
    const data = tailOf(store, longOf(store, 8 + outer * 4)) orelse return 0;
    if (inner >= wordOf(data, 0)) return 0;
    // A row: the first deltas wide, the rest narrow; words and bytes, or
    // with the high bit long words and words.
    const widths: u32 = wordOf(data, 2);
    const wide_count = widths & 0x7FFF;
    const wide: u32 = if (widths & 0x8000 != 0) 4 else 2;
    const index_count: u32 = wordOf(data, 4);
    if (wide_count > index_count) return 0;
    const row_size = wide_count * wide + (index_count - wide_count) * (wide / 2);
    var at = (6 + index_count * 2) +| inner *| row_size;
    if (at > data.len or data.len - at < row_size) return 0;
    if (regions) |into| into.* = index_count;
    var delta: f64 = 0;
    var index: u32 = 0;
    while (index < index_count) : (index += 1) {
        const size = if (index < wide_count) wide else wide / 2;
        const value: i32 = switch (size) {
            4 => @bitCast(longOf(data, at)),
            2 => signedOf(data, at),
            else => @as(i8, @bitCast(data[at])),
        };
        at += size;
        const region: u32 = wordOf(data, 6 + index * 2);
        if (region >= region_count) continue;
        const part = regionPart(list, coords, region);
        if (part == 0) continue;
        delta += @as(f64, @floatFromInt(value)) * part;
    }
    return delta;
}

/// The same for the item `item` - its data in the high 16 bits, its row
/// in the low - rounded to a whole unit, a half upward.
pub fn wholeDelta(store: []const u8, coords: []const i16, item: u32, regions: ?*u32) i32 {
    return rounded(deltaIn(store, coords, item >> 16, item & 0xFFFF, regions));
}

/// The delta of an item of the font's own store `store` at the font's
/// coordinates, not rounded.
pub fn storeDelta(font: *const Font, store: Table, outer: u32, inner: u32) f64 {
    return deltaIn(bytesOf(font, store), placeOf(font), outer, inner, null);
}

/// How many regions data `outer` of an item variation store has a delta
/// each for; null for a store that has no such data.
pub fn storeRegions(font: *const Font, store: Table, outer: u32) ?u32 {
    if (store.len < 8 or wordIn(font, store, 0) != 1) return null;
    if (outer >= wordIn(font, store, 6)) return null;
    const data = partOf(store, longIn(font, store, 8 + outer * 4)) orelse return null;
    if (data.len < 6) return null;
    const count: u32 = wordIn(font, data, 4);
    if (count * 2 > data.len - 6) return null;
    return count;
}

/// How much the region counts at the font's coordinates that delta
/// `index` of a row of the store's data `outer` is for. 0 at the font's
/// default, for a store that is not for this font's axes, and for a
/// region its list does not have.
pub fn storePart(font: *const Font, store: Table, outer: u32, index: u32) f64 {
    if (!font.vary.varied) return 0;
    if (store.len < 8 or wordIn(font, store, 0) != 1) return 0;
    const list = partOf(store, longIn(font, store, 2)) orelse return 0;
    if (wordIn(font, list, 0) != font.vary.axis_count) return 0;
    if (outer >= wordIn(font, store, 6)) return 0;
    const data = partOf(store, longIn(font, store, 8 + outer * 4)) orelse return 0;
    if (index >= wordIn(font, data, 4)) return 0;
    const region: u32 = wordIn(font, data, 6 + index * 2);
    const coords = placeOf(font);
    if (region >= regionCount(bytesOf(font, list), @intCast(coords.len))) return 0;
    return regionPart(bytesOf(font, list), coords, region);
}

/// The delta of a glyph's advance from `HVAR`: the store's item the
/// table's map names for the glyph - a glyph past the map's end has its
/// last entry's - or, without a map, row `glyph` of the first data.
fn advanceDelta(font: *const Font, glyph: u32) f64 {
    const hvar = font.vary.hvar;
    const store = partOf(hvar, longIn(font, hvar, 4)) orelse return 0;
    var outer: u32 = 0;
    var inner: u32 = glyph;
    const map_at = longIn(font, hvar, 8);
    if (map_at != 0) {
        const map = partOf(hvar, map_at) orelse return 0;
        const form = byteIn(font, map, 0);
        const entry_form: u32 = byteIn(font, map, 1);
        const count: u32, const entries_at: u32 = switch (form) {
            0 => .{ wordIn(font, map, 2), 4 },
            1 => .{ longIn(font, map, 2), 6 },
            else => return 0,
        };
        if (count == 0) return 0;
        const entry_size = ((entry_form & 0x30) >> 4) + 1;
        const inner_bits: u5 = @intCast((entry_form & 0x0F) + 1);
        const at = entries_at +| @min(glyph, count - 1) *| entry_size;
        if (at >= map.len or map.len - at < entry_size) return 0;
        var entry: u32 = 0;
        var byte: u32 = 0;
        while (byte < entry_size) : (byte += 1) entry = entry << 8 | byteIn(font, map, at + byte);
        outer = entry >> inner_bits;
        inner = entry & ((@as(u32, 1) << inner_bits) - 1);
    }
    return storeDelta(font, store, outer, inner);
}

// --- a glyph's deltas ----------------------------------------------------------

/// The point numbers a group of deltas names, read one at a time: a
/// count, then runs of bytes or of words, each number the step from the
/// one before it. A count of 0 is every point, and then none is given.
const Numbers = struct {
    font: *const Font,
    data: Table,
    /// Where the next byte is read, in `data`.
    at: u32,
    all: bool = false,
    /// The numbers not yet given, and those left of the run being read.
    left: u32 = 0,
    run: u32 = 0,
    words: bool = false,
    number: u32 = 0,
    /// The data ended before the numbers did.
    damaged: bool = false,

    fn start(font: *const Font, data: Table, from: u32) Numbers {
        var numbers = Numbers{ .font = font, .data = data, .at = from };
        if (from >= data.len) {
            numbers.damaged = true;
            return numbers;
        }
        var count: u32 = byteIn(font, data, from);
        numbers.at += 1;
        if (count & 0x80 != 0) {
            if (numbers.at >= data.len) {
                numbers.damaged = true;
                return numbers;
            }
            count = (count & 0x7F) << 8 | byteIn(font, data, numbers.at);
            numbers.at += 1;
        }
        numbers.all = count == 0;
        numbers.left = count;
        return numbers;
    }

    fn next(numbers: *Numbers) ?u32 {
        if (numbers.left == 0) return null;
        if (numbers.run == 0) {
            if (numbers.at >= numbers.data.len) return numbers.cut();
            const control = byteIn(numbers.font, numbers.data, numbers.at);
            numbers.at += 1;
            numbers.words = control & 0x80 != 0;
            numbers.run = @as(u32, control & 0x7F) + 1;
        }
        const size: u32 = if (numbers.words) 2 else 1;
        if (numbers.at >= numbers.data.len or numbers.data.len - numbers.at < size) return numbers.cut();
        const step: u32 = if (numbers.words) wordIn(numbers.font, numbers.data, numbers.at) else byteIn(numbers.font, numbers.data, numbers.at);
        numbers.at += size;
        numbers.run -= 1;
        numbers.left -= 1;
        numbers.number +%= step;
        return numbers.number;
    }

    fn cut(numbers: *Numbers) ?u32 {
        numbers.damaged = true;
        numbers.left = 0;
        return null;
    }
};

/// A group's deltas, read one at a time: runs of zeroes, of bytes, of
/// words or of long words. 0, and `damaged`, once the data has ended.
const Deltas = struct {
    font: *const Font,
    data: Table,
    at: u32,
    run: u32 = 0,
    kind: u8 = 0,
    damaged: bool = false,

    fn next(deltas: *Deltas) i32 {
        if (deltas.damaged) return 0;
        if (deltas.run == 0) {
            if (deltas.at >= deltas.data.len) return deltas.cut();
            const control = byteIn(deltas.font, deltas.data, deltas.at);
            deltas.at += 1;
            deltas.kind = control & 0xC0;
            deltas.run = @as(u32, control & 0x3F) + 1;
        }
        deltas.run -= 1;
        const size: u32 = switch (deltas.kind) {
            0x80 => return 0,
            0x00 => 1,
            0x40 => 2,
            else => 4,
        };
        if (deltas.at >= deltas.data.len or deltas.data.len - deltas.at < size) return deltas.cut();
        defer deltas.at += size;
        return switch (size) {
            1 => @as(i8, @bitCast(byteIn(deltas.font, deltas.data, deltas.at))),
            2 => signedIn(deltas.font, deltas.data, deltas.at),
            else => @bitCast(longIn(deltas.font, deltas.data, deltas.at)),
        };
    }

    fn cut(deltas: *Deltas) i32 {
        deltas.damaged = true;
        return 0;
    }
};

/// One group of a glyph's deltas: how much it counts, the points it
/// names (null for a group that names none and shares none), and its
/// deltas, the x of every point it names and then the y.
const Group = struct {
    part: f64,
    numbers: ?Numbers = null,
    deltas: Deltas,
};

/// The groups of one glyph's deltas, given one at a time in the file's
/// order.
const Groups = struct {
    font: *const Font,
    /// The glyph's variation data.
    data: Table,
    /// The groups not yet given, where the next one's header is and
    /// where its deltas are, in `data`.
    left: u32,
    header: u32,
    serial: u32,
    /// The point numbers the groups share, if they share any.
    shared: ?Numbers = null,
    damaged: bool = false,

    /// The groups of `glyph`; null for a glyph that has none.
    fn of(font: *const Font, glyph: u32) ?Groups {
        const gvar = font.vary.gvar;
        if (gvar.len < 20 or glyph >= wordIn(font, gvar, 12)) return null;
        const array = longIn(font, gvar, 16);
        const start, const end = if (wordIn(font, gvar, 14) & 1 != 0)
            .{ longIn(font, gvar, 20 + glyph * 4), longIn(font, gvar, 24 + glyph * 4) }
        else
            .{ @as(u32, wordIn(font, gvar, 20 + glyph * 2)) * 2, @as(u32, wordIn(font, gvar, 22 + glyph * 2)) * 2 };
        if (end <= start or end - start < 4) return null;
        if (array > gvar.len or end > gvar.len - array) return null;
        const data = Table{ .at = gvar.at + array + start, .len = end - start };
        const counted = wordIn(font, data, 0);
        var groups = Groups{
            .font = font,
            .data = data,
            .left = counted & 0x0FFF,
            .header = 4,
            .serial = wordIn(font, data, 2),
        };
        if (counted & 0x8000 != 0) {
            // The shared numbers stand before the first group's deltas.
            const shared = Numbers.start(font, data, groups.serial);
            var past = shared;
            while (past.next()) |_| {}
            groups.shared = shared;
            groups.serial = past.at;
            groups.damaged = past.damaged;
        }
        return groups;
    }

    fn next(groups: *Groups) ?Group {
        if (groups.left == 0 or groups.damaged) return null;
        groups.left -= 1;
        const font = groups.font;
        const data = groups.data;
        const axes = font.vary.axis_count;
        var at = groups.header;
        if (at > data.len or data.len - at < 4) return groups.cut();
        const size: u32 = wordIn(font, data, at);
        const index: u32 = wordIn(font, data, at + 2);
        at += 4;
        // The peak: the group's own, or one of the table's shared ones.
        var peak: Table = undefined;
        if (index & 0x8000 != 0) {
            peak = partOf(data, at) orelse return groups.cut();
            at += axes * 2;
        } else {
            const gvar = font.vary.gvar;
            const shared = index & 0x0FFF;
            if (shared >= wordIn(font, gvar, 6)) return groups.cut();
            peak = partOf(gvar, longIn(font, gvar, 8) +| shared * axes * 2) orelse return groups.cut();
        }
        if (peak.len < axes * 2) return groups.cut();
        var bounds: ?[2]Table = null;
        if (index & 0x4000 != 0) {
            const starts = partOf(data, at) orelse return groups.cut();
            const ends = partOf(data, at + axes * 2) orelse return groups.cut();
            if (ends.len < axes * 2) return groups.cut();
            bounds = .{ starts, ends };
            at += axes * 4;
        }
        if (at > data.len) return groups.cut();
        groups.header = at;
        if (groups.serial > data.len or size > data.len - groups.serial) return groups.cut();
        const own = Table{ .at = data.at + groups.serial, .len = size };
        groups.serial += size;

        var group = Group{ .part = groupPart(font, peak, bounds), .deltas = .{ .font = font, .data = own, .at = 0 } };
        // A group that counts nothing is not read further.
        if (group.part == 0) return group;
        if (index & 0x2000 != 0) {
            const numbers = Numbers.start(font, own, 0);
            var past = numbers;
            while (past.next()) |_| {}
            if (past.damaged) return groups.cut();
            group.numbers = numbers;
            group.deltas.at = past.at;
        } else {
            group.numbers = groups.shared;
        }
        return group;
    }

    fn cut(groups: *Groups) ?Group {
        groups.damaged = true;
        return null;
    }
};

/// The deltas of `glyph`'s points at the font's coordinates, summed into
/// `scratch.sums`: one for each of its `count` points, or of a
/// composite's `count` parts, and for the four after them. `points` are
/// a simple glyph's points as the file has them and `ends` the index
/// after each contour's last, counted from `base`; a composite gives
/// neither. All 0 for a glyph without deltas. False when the room is
/// too short or the data damaged.
pub fn glyphDeltas(font: *const Font, glyph: u32, scratch: *Scratch, points: []const Point, ends: []const u32, base: u32, count: u32) bool {
    if (count > scratch.sums.len or scratch.sums.len - count < 4) return false;
    const total = count + 4;
    const sums = scratch.sums[0..total];
    const deltas = scratch.deltas[0..total];
    const touched = scratch.touched[0..total];
    @memset(sums, .{ 0, 0 });
    var groups = Groups.of(font, glyph) orelse return true;
    while (groups.next()) |found| {
        var group = found;
        if (group.part == 0) continue;
        const numbers = group.numbers orelse continue;
        if (numbers.all) {
            for (0..2) |axis| {
                for (deltas) |*delta| delta[axis] = group.deltas.next();
            }
            if (group.deltas.damaged) return false;
            for (sums, deltas) |*sum, delta| add(sum, delta, group.part);
            continue;
        }
        @memset(touched, false);
        for (0..2) |axis| {
            var pass = numbers;
            while (pass.next()) |number| {
                const value = group.deltas.next();
                if (number >= total) continue;
                touched[number] = true;
                deltas[number][axis] = value;
            }
            if (pass.damaged) return false;
        }
        if (group.deltas.damaged) return false;
        // The points the group does not name follow the named ones of
        // their contour.
        var from: u32 = 0;
        for (ends) |end| {
            if (end < base + from or end - base > count or end - base > points.len) return false;
            const to = end - base;
            follow(sums, deltas, touched, points, from, to, group.part);
            from = to;
        }
        // What is past the contours stands alone: the four points after
        // the glyph's, and each part of a composite.
        for (from..total) |index| {
            if (touched[index]) add(&sums[index], deltas[index], group.part);
        }
    }
    return !groups.damaged;
}

fn add(sum: *[2]f64, delta: [2]i32, part: f64) void {
    sum[0] += part * @as(f64, @floatFromInt(delta[0]));
    sum[1] += part * @as(f64, @floatFromInt(delta[1]));
}

/// One contour's points, `from` up to `to`: a named point's delta added
/// to its sum, and for each one not named the delta it has from the
/// named points before and after it, round the contour. None for a
/// contour without a named point.
fn follow(sums: [][2]f64, deltas: []const [2]i32, touched: []const bool, points: []const Point, from: u32, to: u32, part: f64) void {
    var first: ?u32 = null;
    var last: u32 = 0;
    for (from..to) |index| {
        if (!touched[index]) continue;
        if (first == null) first = @intCast(index);
        last = @intCast(index);
    }
    const start = first orelse return;
    var before = last;
    var index = from;
    while (index < to) {
        if (touched[index]) {
            add(&sums[index], deltas[index], part);
            before = index;
            index += 1;
            continue;
        }
        var next = index + 1;
        while (next < to and !touched[next]) next += 1;
        const after = if (next < to) next else start;
        for (index..next) |free| {
            sums[free][0] += part * between(points[free].x, points[before].x, deltas[before][0], points[after].x, deltas[after][0]);
            sums[free][1] += part * between(points[free].y, points[before].y, deltas[before][1], points[after].y, deltas[after][1]);
        }
        index = next;
    }
}

/// The delta of a coordinate `place` that no group names, from the two
/// named points beside it, at `one` and `other` with the deltas
/// `one_delta` and `other_delta`: between the two, between their deltas
/// in a straight line; outside them, the nearer one's delta. Two at one
/// place give their delta if it is the same, and none if not.
fn between(place: f32, one: f32, one_delta: i32, other: f32, other_delta: i32) f64 {
    var low: f64 = one;
    var high: f64 = other;
    var low_delta: f64 = @floatFromInt(one_delta);
    var high_delta: f64 = @floatFromInt(other_delta);
    if (low == high) return if (low_delta == high_delta) low_delta else 0;
    if (low > high) {
        low = other;
        high = one;
        low_delta = @floatFromInt(other_delta);
        high_delta = @floatFromInt(one_delta);
    }
    const slope = (high_delta - low_delta) / (high - low);
    const here: f64 = place;
    if (here <= low) return low_delta;
    if (here >= high) return high_delta;
    return low_delta + (here - low) * slope;
}

/// The x deltas of the two points after a glyph's `count` own - its
/// left and its right side - at the font's coordinates, read without
/// room to work in. Both 0 for a glyph without deltas; null when the
/// data is damaged.
fn sideDeltas(font: *const Font, glyph: u32, count: u32) ?[2]f64 {
    var sides = [2]f64{ 0, 0 };
    var groups = Groups.of(font, glyph) orelse return sides;
    while (groups.next()) |found| {
        var group = found;
        if (group.part == 0) continue;
        var numbers = group.numbers orelse continue;
        var moved = [2]i32{ 0, 0 };
        if (numbers.all) {
            var index: u32 = 0;
            while (index < count + 2) : (index += 1) {
                const value = group.deltas.next();
                if (index >= count) moved[index - count] = value;
            }
        } else {
            while (numbers.next()) |number| {
                const value = group.deltas.next();
                if (number == count) moved[0] = value;
                if (number == count + 1) moved[1] = value;
            }
            if (numbers.damaged) return null;
        }
        if (group.deltas.damaged) return null;
        sides[0] += group.part * @as(f64, @floatFromInt(moved[0]));
        sides[1] += group.part * @as(f64, @floatFromInt(moved[1]));
    }
    if (groups.damaged) return null;
    return sides;
}

// --- a glyph's measures ---------------------------------------------------------

/// A glyph's advance at the font's instance, `plain` being the one
/// `hmtx` has: plus `HVAR`'s delta, rounded, when the font has that
/// table; else the distance between the glyph's two side points as
/// `gvar` moves them, rounded. Never less than 0. `plain` for a font
/// with neither, and where `gvar`'s data is damaged.
pub fn advanceOf(font: *const Font, glyph: u32, plain: i32) i32 {
    if (font.vary.hvar.len != 0) return @max(0, plain + rounded(advanceDelta(font, glyph)));
    if (font.vary.gvar.len == 0) return plain;
    const sides = _outline.sidesOf(font, glyph);
    const moved = sideDeltas(font, glyph, sides.points) orelse return plain;
    const left = @as(f64, @floatFromInt(sides.left)) + moved[0];
    const right = @as(f64, @floatFromInt(sides.left + plain)) + moved[1];
    return @max(0, rounded(right - left));
}

/// Where a glyph's origin is at the font's instance, in the x its
/// points are in: its left side point as `gvar` moves it, rounded. A
/// glyph's left side bearing is its box's left less this.
pub fn originOf(font: *const Font, glyph: u32) i32 {
    const sides = _outline.sidesOf(font, glyph);
    const moved = sideDeltas(font, glyph, sides.points) orelse return sides.left;
    return rounded(@as(f64, @floatFromInt(sides.left)) + moved[0]);
}

// --- the axes and the instances, as the calls give them ------------------------

/// Axis `index` of the font, with the value this outline was opened at.
pub fn axisOf(font: *const Font, index: u32) truetype.Axis {
    const vary = &font.vary;
    const record = vary.axes_at + index * vary.axis_size;
    const default: f32 = @floatCast(fixed(longIn(font, vary.fvar, record + 8)));
    return .{
        .tag = longIn(font, vary.fvar, record),
        .minimum = @floatCast(fixed(longIn(font, vary.fvar, record + 4))),
        .default = default,
        .maximum = @floatCast(fixed(longIn(font, vary.fvar, record + 12))),
        .value = if (vary.axis_count <= max_axes) vary.values[index] else default,
        .name = wordIn(font, vary.fvar, record + 18),
        .hidden = wordIn(font, vary.fvar, record + 16) & 1 != 0,
    };
}

/// The name of the font's named instance `number`, counted from 0, as
/// the number `FontName` takes; 0 when it has none of that number, or
/// one whose name the file gives as 0. Its value on each axis goes into
/// `values`, up to `room` of them, and nothing when the answer is 0.
pub fn instanceOf(font: *const Font, number: u32, values: ?[*]truetype.AxisValue, room: u32) u32 {
    const vary = &font.vary;
    if (number >= vary.instance_count) return 0;
    const record = vary.instances_at + number * vary.instance_size;
    const name = wordIn(font, vary.fvar, record);
    if (name == 0) return 0;
    if (values) |into| {
        var axis: u32 = 0;
        while (axis < vary.axis_count and axis < room) : (axis += 1) {
            into[axis] = .{
                .tag = longIn(font, vary.fvar, vary.axes_at + axis * vary.axis_size),
                .value = @floatCast(fixed(longIn(font, vary.fvar, record + 4 + axis * 4))),
            };
        }
    }
    return name;
}

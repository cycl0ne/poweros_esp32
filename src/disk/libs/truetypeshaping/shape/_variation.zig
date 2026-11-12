// SPDX-License-Identifier: MIT
//! A variable font's place, and what a layout table's numbers are there.
//!
//! A variable font is one font at every place of its axes - of its
//! weights, of its widths. Its layout tables hold their numbers for the
//! default place. A number that is another one elsewhere - a kerning, an
//! anchor - names an item of a store of deltas, which `GDEF` holds, and
//! the item says by how much the number changes towards each of the
//! store's regions.
//!
//! `Place` is a font's place - a coordinate an axis, in 14 bits of
//! fraction, as truetype.library hands them out - and that store. A font
//! at its default has no coordinates, and nothing here is read for it.
//! `delta` answers what an item adds at the place.
//!
//! A region is a stretch of each axis with a peak in it: at the peak its
//! deltas count in full, at the stretch's ends and outside it not at
//! all, in between in proportion (`partOn`); the parts of a region's
//! axes are multiplied. An item's deltas, each times its region's part,
//! are summed in the order they are stored, and the sum is rounded to a
//! whole unit, a half upward - the rule a glyph's advance is varied by,
//! so that one store's delta is one number wherever it is asked for.
//!
//! The store is read as every layout table is: a count cut to what the
//! table holds, a read past its end 0. A store that is not for the
//! font's number of axes, an item it does not have, a row that does not
//! lie within it: each adds 0. A delta is held to what a 16-bit number
//! holds, which is what a layout table's own number is. And a region of
//! a row is a piece of the table's work on the run, so a font whose rows
//! are long cannot make a run slow.

const _tables = @import("_tables.zig");
const Table = _tables.Table;

/// The format of a device table that names an item of the store. The
/// other formats adjust a number for one size in pixels.
const VARIATION_INDEX: u32 = 0x8000;

/// In a row's count of wide deltas: the wide ones have 32 bits and the
/// others 16, not 16 and 8.
const LONG_WORDS: u32 = 0x8000;

/// How far a delta goes either way.
const delta_limit = 0x7FFF;

/// A font's place on its axes, and the store its layout tables' numbers
/// are varied by.
pub const Place = struct {
    /// A coordinate an axis, -16384 to 16384. Empty at the default.
    coords: []const i16 = &.{},
    /// `GDEF`'s store of deltas.
    store: Table = Table.none,

    /// What the device table `device` adds to its number at this place,
    /// in the font's units: 0 at the default, and for a table that names
    /// no item of the store. Takes a piece off `work` for every region
    /// of the item's row, and answers 0 once none is left.
    pub fn delta(place: Place, device: Table, work: *u32) i32 {
        if (place.coords.len == 0 or device.word(4) != VARIATION_INDEX) return 0;
        const store = place.store;
        if (store.word(0) != 1) return 0;
        const regions = store.partAtLong(2);
        const axes: u32 = @intCast(place.coords.len);
        if (regions.word(0) != axes) return 0;
        const region_count = regions.count(2, 4, axes * 6);

        const outer = device.word(0);
        if (outer >= store.count(6, 8, 4)) return 0;
        const data = store.partAtLong(8 + outer * 4);
        const inner = device.word(2);
        if (inner >= data.word(0)) return 0;
        const listed = data.count(4, 6, 2);
        if (listed != data.word(4)) return 0;
        const said = data.word(2);
        const long_words = said & LONG_WORDS != 0;
        const wide = said & ~LONG_WORDS;
        if (wide > listed) return 0;
        const wide_size: u32 = if (long_words) 4 else 2;
        const narrow_size: u32 = if (long_words) 2 else 1;
        const row_size = wide * wide_size + (listed - wide) * narrow_size;
        const row = 6 + @as(u64, listed) * 2 + @as(u64, inner) * row_size;
        if (row + row_size > data.bytes.len) return 0;

        var sum: f64 = 0;
        var at: u32 = @intCast(row);
        var index: u32 = 0;
        while (index < listed) : (index += 1) {
            if (work.* == 0) return 0;
            work.* -= 1;
            const size = if (index < wide) wide_size else narrow_size;
            const value: i32 = switch (size) {
                4 => @bitCast(data.long(at)),
                2 => data.signed(at),
                else => @as(i8, @bitCast(data.bytes[at])),
            };
            at += size;
            const region = data.word(6 + index * 2);
            if (region >= region_count) continue;
            sum += @as(f64, @floatFromInt(value)) * place.partOf(regions, region);
        }
        const whole = @floor(sum + 0.5);
        if (whole >= delta_limit) return delta_limit;
        if (whole <= -delta_limit) return -delta_limit;
        return @intFromFloat(whole);
    }

    /// How far the region `region` of the list `regions` counts at this
    /// place: the parts of its axes multiplied.
    fn partOf(place: Place, regions: Table, region: u32) f64 {
        const axes: u32 = @intCast(place.coords.len);
        const first = 4 + region * axes * 6;
        var whole: f64 = 1;
        for (place.coords, 0..) |coord, axis| {
            const at = first + @as(u32, @intCast(axis)) * 6;
            const part = partOn(coord, regions.signed(at), regions.signed(at + 2), regions.signed(at + 4));
            if (part == 0) return 0;
            whole *= part;
        }
        return whole;
    }
};

/// How far a region counts on one axis for the coordinate `value`: in
/// full at its peak, not at all at `lower`, at `upper` and outside them,
/// in proportion between. A region that says nothing of the axis - a
/// peak of 0 - counts in full, and so does one whose three numbers are
/// out of order or lie on both sides of 0.
fn partOn(value: i32, lower: i32, peak: i32, upper: i32) f64 {
    if (peak == 0 or value == peak) return 1;
    if (lower > peak or peak > upper) return 1;
    if (lower < 0 and upper > 0) return 1;
    if (value <= lower or upper <= value) return 0;
    const from: f64 = @floatFromInt(if (value < peak) value - lower else upper - value);
    const over: f64 = @floatFromInt(if (value < peak) peak - lower else upper - peak);
    return from / over;
}

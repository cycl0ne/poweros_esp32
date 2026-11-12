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
//! `Place` is what the shaping needs of that: whether the font is away
//! from its default, the store, and the font's reader of it. A font at
//! its default has nothing read. `delta` answers what the item a device
//! table names adds at the place.
//!
//! The store is not read here. The font reads it (`Font.deltaFn`): for
//! an outline that is truetype.library's `VariationDelta`, the reader
//! that library varies a glyph's advance by, so that one store's delta
//! is one number wherever it is asked for - each of the row's deltas as
//! far as its region counts at the place, summed in the order they are
//! stored and rounded to a whole unit, a half upward. A store that is
//! not for the font's number of axes, an item it does not have, a row
//! that does not lie within it: each adds 0.
//!
//! What is done here: a device table is told from the ones that adjust
//! a number for one size in pixels; the delta is held to what a 16-bit
//! number holds, which is what a layout table's own number is; and a
//! region of the row read is a piece of the table's work on the run, so
//! a font whose rows are long cannot make a run slow. The reader says
//! how many regions the row had, and they are taken off after it: with
//! fewer pieces left than that the item adds 0 and none is left.

const _tables = @import("_tables.zig");
const Table = _tables.Table;

/// The format of a device table that names an item of the store. The
/// other formats adjust a number for one size in pixels.
const VARIATION_INDEX: u32 = 0x8000;

/// How far a delta goes either way.
const delta_limit = 0x7FFF;

/// A font's reader of a store of deltas: what the item `item` of
/// `store` - its data's number in the high 16 bits, its row's in the
/// low - adds at the font's place, rounded to a whole unit, and into
/// `regions` how many deltas the row has, 0 when none was read.
pub const DeltaFn = *const fn (context: *anyopaque, store: []const u8, item: u32, regions: *u32) i32;

/// What a variable font's layout numbers are varied by.
pub const Place = struct {
    /// Whether the font is away from its default.
    varied: bool = false,
    /// `GDEF`'s store of deltas.
    store: Table = Table.none,
    /// The font and its reader of the store; without one nothing is
    /// added.
    context: ?*anyopaque = null,
    deltaFn: ?DeltaFn = null,

    /// What the device table `device` adds to its number at this place,
    /// in the font's units: 0 at the default, and for a table that names
    /// no item of the store. Takes a piece off `work` for every region
    /// of the item's row, and answers 0 once none is left.
    pub fn delta(place: Place, device: Table, work: *u32) i32 {
        if (!place.varied or device.word(4) != VARIATION_INDEX) return 0;
        const context = place.context orelse return 0;
        const read = place.deltaFn orelse return 0;
        if (place.store.empty()) return 0;
        const item = @as(u32, device.word(0)) << 16 | device.word(2);
        var regions: u32 = 0;
        const whole = read(context, place.store.bytes, item, &regions);
        if (regions > work.*) {
            work.* = 0;
            return 0;
        }
        work.* -= regions;
        if (whole >= delta_limit) return delta_limit;
        if (whole <= -delta_limit) return -delta_limit;
        return whole;
    }
};

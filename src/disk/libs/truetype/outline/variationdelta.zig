// SPDX-License-Identifier: MIT
//! VariationDelta: what an item of a store of deltas adds at the
//! outline's place on its axes.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("_outline.zig");
const _variation = @import("_variation.zig");

/// What an item of a store of deltas adds at the outline's place.
///
/// SYNOPSIS:
/// ```zig
/// fn VariationDelta(tb: *TrueTypeBase, outline: *truetype.Outline, store: [*]const u8, size: u32, item: u32, regions: ?*u32) i32
/// ```
///
/// SINCE: 1.11. LVO -84.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `store` - an item variation store: the bytes of one, wherever
///   they are.
/// - `size` - how many bytes the store has; a store that is the rest of
///   a table has the bytes to the table's end.
/// - `item` - the item asked for: the number of its data in the high 16
///   bits, of its row there in the low 16. `truetype.variationItem`
///   puts the two together.
/// - `regions` - where the number of deltas the row has goes, one a
///   region: how much the call read. Null for a caller that does not
///   count it.
///
/// RESULT:
/// What the item adds to its number at the place the outline was
/// opened at, in the font's units, rounded to a whole unit, a half
/// upward. 0 at the font's default and for a font without axes, for an
/// item the store does not have, and for a store that is not for the
/// font's number of axes.
///
/// BEHAVIOR:
/// A variable font's tables hold their numbers for its default place.
/// A number that is another one elsewhere - an advance, a measure, a
/// kerning, an anchor - names an item of a store of deltas, and the
/// item says by how much the number changes towards each of the store's
/// regions. A region is a stretch of each axis with a peak in it: at
/// the peak its delta counts in full, at the stretch's ends and outside
/// it not at all, in between in proportion; the parts of a region's
/// axes are multiplied. An axis whose peak is 0 takes no part in the
/// region, and one whose three numbers are out of order, or lie on both
/// sides of 0, counts in full.
///
/// The row's deltas, each times its region's part, are summed in the
/// order they are stored, in 64-bit floating point, and the sum is
/// rounded once. It is the rule the library varies a glyph's advance
/// and the font's measures by, with the same code: one store's item is
/// one number wherever it is asked for, on every machine.
///
/// The store is read within its `size` bytes and nowhere else: a count
/// is cut to what the bytes hold, an offset of 0 or past them names
/// nothing, a row that does not lie within them adds 0, and a delta for
/// a region the store's list does not hold is left out. The answer is
/// held to 30 bits either way.
///
/// `regions` gets 0 where no row was read - at the default, for an item
/// that is not there. A caller that bounds its work by what a font can
/// make it read takes the number off its count.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. The store's bytes are the caller's and are
/// only read.
///
/// NOTES:
/// The stores of the font's own tables need no call: `GlyphAdvance` and
/// `FontMetrics` answer at the outline's place already. The call is for
/// the tables the library hands out with `FontTable` and does not read
/// itself - `GDEF`'s store, which `GPOS`'s value records and anchors
/// name their items in.
///
/// BUGS:
/// A store whose regions are for another number of axes than the font
/// has adds 0 for every item, also where the two share their first
/// axes.
///
/// SEE ALSO:
/// `FontTable`, `FontCoordinates`, `GlyphAdvance`, `OpenOutline`
///
/// EXAMPLES:
/// ```zig
/// // GDEF 1.3 has the offset of its store at byte 14.
/// var length: u32 = 0;
/// const gdef = tb.FontTable(outline, truetype.tableTag("GDEF"), &length) orelse return;
/// if (length < 18) return;
/// const at = @as(u32, gdef[14]) << 24 | @as(u32, gdef[15]) << 16 | @as(u32, gdef[16]) << 8 | gdef[17];
/// if (at == 0 or at >= length) return;
/// const more = tb.VariationDelta(outline, gdef + at, length - at, truetype.variationItem(0, 3), null);
/// ```
pub fn VariationDelta(tb: *TrueTypeBase, outline: *truetype.Outline, store: [*]const u8, size: u32, item: u32, regions: ?*u32) i32 {
    _ = tb;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    if (!font.vary.varied) {
        if (regions) |into| into.* = 0;
        return 0;
    }
    return _variation.wholeDelta(store[0..size], _variation.placeOf(font), item, regions);
}

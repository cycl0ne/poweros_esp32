// SPDX-License-Identifier: MIT
//! FontCoordinates: where an outline is on its font's axes, as the
//! font's tables count it.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("_outline.zig");
const _variation = @import("_variation.zig");

/// Where an outline is on its font's axes, as the font's tables count
/// it.
///
/// SYNOPSIS:
/// ```zig
/// fn FontCoordinates(tb: *TrueTypeBase, outline: *truetype.Outline, coords: ?[*]i16, room: u32) u32
/// ```
///
/// SINCE: 1.8. LVO -76.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `coords` - where they go; null to ask only how many there are.
/// - `room` - how many `coords` has room for.
///
/// RESULT:
/// How many axes the font has, whatever `room` is; 0 for a font that is
/// not a variable one.
///
/// BEHAVIOR:
/// A font's tables do not speak of an axis in its own units but in
/// coordinates: -1 at the axis' least value, 0 at its default, 1 at
/// its most, kept as a number of 14 bits of fraction, -16384 to 16384.
/// A coordinate is the value's distance from the default as a part of
/// the range on that side, bent as the font's `avar` table says for
/// the axis, and rounded. The first `room` of them are written, in the
/// axes' order.
///
/// These are what a table of the font that varies is read with: the
/// positions and the choice of features a shaper takes from `GPOS`,
/// `GSUB` and `GDEF`, got through `FontTable`. The outlines, advances
/// and measures this library gives are already at them.
///
/// Every coordinate is 0 for an outline at its font's default, and for
/// a font of more than 32 axes, which is read at its default.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `coords` is the caller's.
///
/// SEE ALSO:
/// `FontAxes`, `OpenOutline`, `FontTable`
///
/// EXAMPLES:
/// ```zig
/// var coords: [32]i16 = undefined;
/// const axes = tb.FontCoordinates(outline, &coords, coords.len);
/// const at_default = for (coords[0..@min(axes, coords.len)]) |coord| {
///     if (coord != 0) break false;
/// } else true;
/// ```
pub fn FontCoordinates(tb: *TrueTypeBase, outline: *truetype.Outline, coords: ?[*]i16, room: u32) u32 {
    _ = tb;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    const count = font.vary.axis_count;
    if (coords) |into| {
        var index: u32 = 0;
        while (index < count and index < room) : (index += 1) {
            into[index] = if (count <= _variation.max_axes) font.vary.coords[index] else 0;
        }
    }
    return count;
}

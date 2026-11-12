// SPDX-License-Identifier: MIT
//! FontAxes: the axes a variable font has.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("_outline.zig");
const _variation = @import("_variation.zig");

/// The axes a variable font has.
///
/// SYNOPSIS:
/// ```zig
/// fn FontAxes(tb: *TrueTypeBase, outline: *truetype.Outline, axes: ?[*]truetype.Axis, room: u32) u32
/// ```
///
/// SINCE: 1.8. LVO -68.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `axes` - where they go; null to ask only how many there are.
/// - `room` - how many `axes` has room for.
///
/// RESULT:
/// How many axes the font has, whatever `room` is; 0 for a font that is
/// not a variable one.
///
/// BEHAVIOR:
/// The axes are the font's `fvar` table's, in its order, which is the
/// order every other table counts them in. Each is given with its tag,
/// the range of its values in its own units, the value a font opened
/// without `TTA_Axes` is at, and the value this outline was opened at:
/// the one asked for, cut to the range. The first `room` of them are
/// written; a caller with less room than the answer asks again with
/// more.
///
/// An axis' name is a number of the font's `name` table, for
/// `FontName`. An axis marked `hidden` is one the font asks not to be
/// offered for choosing; it is set as any other.
///
/// A font of more than 32 axes is read at its default instance: its
/// axes are listed, each with its default as its value.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `axes` is the caller's.
///
/// SEE ALSO:
/// `OpenOutline`, `FontInstance`, `FontCoordinates`, `FontName`
///
/// EXAMPLES:
/// ```zig
/// var axes: [8]sdk.truetype.Axis = undefined;
/// const count = tb.FontAxes(outline, &axes, axes.len);
/// for (axes[0..@min(count, axes.len)]) |axis| {
///     if (axis.tag == sdk.truetype.tableTag("wght")) heaviest = axis.maximum;
/// }
/// ```
pub fn FontAxes(tb: *TrueTypeBase, outline: *truetype.Outline, axes: ?[*]truetype.Axis, room: u32) u32 {
    _ = tb;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    const count = font.vary.axis_count;
    if (axes) |into| {
        var index: u32 = 0;
        while (index < count and index < room) : (index += 1) into[index] = _variation.axisOf(font, index);
    }
    return count;
}

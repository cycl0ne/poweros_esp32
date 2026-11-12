// SPDX-License-Identifier: MIT
//! FontInstance: one of the places on its axes a variable font names.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("_outline.zig");
const _variation = @import("_variation.zig");

/// One of the places on its axes a variable font names.
///
/// SYNOPSIS:
/// ```zig
/// fn FontInstance(tb: *TrueTypeBase, outline: *truetype.Outline, number: u32, values: ?[*]truetype.AxisValue, room: u32) u32
/// ```
///
/// SINCE: 1.8. LVO -72.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `number` - which instance, counted from 0.
/// - `values` - where its value on each axis goes; null for its name
///   only.
/// - `room` - how many `values` has room for.
///
/// RESULT:
/// The instance's name - "Semibold" - as the number `FontName` takes; 0
/// when the font has no instance of that number, and nothing is written
/// then.
///
/// BEHAVIOR:
/// A variable font's designer names some places on its axes, the faces
/// the family would have as separate files: Light, Regular, Bold. They
/// are the `fvar` table's instances, in its order. The values are
/// written an axis each, in the axes' order, with the axis' tag: the
/// first `room` of them, of as many as `FontAxes` answers. They are in
/// the form `TTA_Axes` takes, so the instance is opened by handing them
/// to `OpenOutline`.
///
/// Which instance an outline was opened at does not matter: every
/// outline of a font answers the same.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `values` is the caller's.
///
/// NOTES:
/// The numbers have no gap: a caller lists a font's instances by
/// counting up from 0 until the answer is 0. A name number is never 0
/// for an instance, 0 being the font's copyright; a file that says so
/// all the same has its instances end there.
///
/// SEE ALSO:
/// `FontAxes`, `OpenOutline`, `FontName`
///
/// EXAMPLES:
/// ```zig
/// // Every instance the font names, opened in turn.
/// var values: [8]sdk.truetype.AxisValue = undefined;
/// var number: u32 = 0;
/// while (tb.FontInstance(outline, number, &values, values.len) != 0) : (number += 1) {
///     const tags = [_]utility.TagItem{
///         .{ .tag = sdk.truetype.TTA_Axes, .data = @intFromPtr(&values) },
///         .{ .tag = sdk.truetype.TTA_AxisCount, .data = @min(tb.FontAxes(outline, null, 0), values.len) },
///         .{ .tag = utility.TAG_DONE, .data = 0 },
///     };
///     const face = tb.OpenOutline(file, size, &tags) orelse continue;
///     defer tb.CloseOutline(face);
/// }
/// ```
pub fn FontInstance(tb: *TrueTypeBase, outline: *truetype.Outline, number: u32, values: ?[*]truetype.AxisValue, room: u32) u32 {
    _ = tb;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    return _variation.instanceOf(font, number, values, room);
}

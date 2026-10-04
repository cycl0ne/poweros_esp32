// SPDX-License-Identifier: MIT
//! SetDTAttrsA: attributes set on an object.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const _base = @import("../datatypes_base.zig");
const _class = @import("../class/_class.zig");
const DataTypesBase = _base.DataTypesBase;

/// Sets attributes on an object.
///
/// SYNOPSIS:
/// ```zig
/// fn SetDTAttrsA(db: *DataTypesBase, object: ?*classusr.Object, window: ?*intuition.Window, requester: ?*intuition.Requester, attrs: ?[*]const utility.TagItem) u32
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `object` - a data type object; null does nothing.
/// - `window`, `requester` - where it is, so that it can draw itself
///   again; null when it is in neither.
/// - `attrs` - what to set.
///
/// RESULT:
/// Nonzero when something changed that shows.
///
/// BEHAVIOR:
/// It is `SetGadgetAttrsTagList` with the object's own attributes: a
/// scroller's new `DTA_TopVert` set here moves the view and draws it.
/// Without a window the attributes are set and nothing is drawn.
///
/// CONTEXT:
/// - Waits: whatever the object waits for.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands; what the tags point at stays the caller's.
///
/// SEE ALSO:
/// `GetDTAttrsA`, `RefreshDTObjectA`
///
/// EXAMPLES:
/// ```zig
/// _ = dt.SetDTAttrsA(picture, window, null, &.{
///     .{ .tag = dtc.DTA_TopVert, .data = @bitCast(@as(isize, top)) },
///     .{},
/// });
/// ```
pub fn SetDTAttrsA(db: *DataTypesBase, object: ?*classusr.Object, window: ?*intuition.Window, requester: ?*intuition.Requester, attrs: ?[*]const utility.TagItem) u32 {
    _ = requester;
    const it = object orelse return 0;
    return @truncate(db.intuition_base.SetGadgetAttrsTagList(it, window, attrs));
}

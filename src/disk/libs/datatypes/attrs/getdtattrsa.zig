// SPDX-License-Identifier: MIT
//! GetDTAttrsA: attributes read from an object.

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

/// Reads attributes from an object.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDTAttrsA(db: *DataTypesBase, object: ?*classusr.Object, attrs: ?[*]const utility.TagItem) u32
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `object` - a data type object; null answers 0.
/// - `attrs` - each tag's data is a pointer to where the value goes.
///
/// RESULT:
/// How many were answered.
///
/// BEHAVIOR:
/// A tag the object does not know is left alone and not counted, so a
/// program can ask for more than a class may have.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// What is answered - a name, a font - belongs to the object and lasts
/// as long as it does.
///
/// SEE ALSO:
/// `SetDTAttrsA`
///
/// EXAMPLES:
/// ```zig
/// var total: usize = 0;
/// var visible: usize = 0;
/// _ = dt.GetDTAttrsA(picture, &.{
///     .{ .tag = dtc.DTA_TotalVert, .data = @intFromPtr(&total) },
///     .{ .tag = dtc.DTA_VisibleVert, .data = @intFromPtr(&visible) },
///     .{},
/// });
/// ```
pub fn GetDTAttrsA(db: *DataTypesBase, object: ?*classusr.Object, attrs: ?[*]const utility.TagItem) u32 {
    const it = object orelse return 0;
    const ib = db.intuition_base;
    const ub = db.utility_base;
    var answered: u32 = 0;
    var state = attrs;
    while (ub.NextTagItem(&state)) |item| {
        const storage: ?*usize = @ptrFromInt(item.data);
        if (storage) |where| {
            if (ib.GetAttr(item.tag, it, where) != 0) answered += 1;
        }
    }
    return answered;
}

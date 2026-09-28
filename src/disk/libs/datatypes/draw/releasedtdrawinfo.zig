// SPDX-License-Identifier: MIT
//! ReleaseDTDrawInfo: what ObtainDTDrawInfoA answered, given back.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const _base = @import("../datatypes_base.zig");
const DataTypesBase = _base.DataTypesBase;

/// Gives back what `ObtainDTDrawInfoA` answered.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseDTDrawInfo(db: *DataTypesBase, object: *classusr.Object, handle: ?*anyopaque) void
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `object` - the object it came from.
/// - `handle` - what `ObtainDTDrawInfoA` answered; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// It is `DTM_RELEASEDRAWINFO` sent to the object, which frees whatever
/// it got ready.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle must not be used afterwards.
///
/// SEE ALSO:
/// `ObtainDTDrawInfoA`, `DrawDTObjectA`
///
/// EXAMPLES:
/// ```zig
/// dt.ReleaseDTDrawInfo(picture, handle);
/// ```
pub fn ReleaseDTDrawInfo(db: *DataTypesBase, object: *classusr.Object, handle: ?*anyopaque) void {
    if (handle == null) return;
    var msg = dtc.DtDrawInfo{ .method_id = dtc.DTM_RELEASEDRAWINFO, .handle = handle };
    _ = db.intuition_base.SendMessage(object, @ptrCast(&msg));
}

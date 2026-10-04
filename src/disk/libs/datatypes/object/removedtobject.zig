// SPDX-License-Identifier: MIT
//! RemoveDTObject: an object taken out of its window.

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

/// Takes an object out of its window.
///
/// SYNOPSIS:
/// ```zig
/// fn RemoveDTObject(db: *DataTypesBase, window: ?*intuition.Window, object: ?*classusr.Object) i32
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `window` - the window it is in.
/// - `object` - a data type object.
///
/// RESULT:
/// How many gadgets are left in the window, or -1 when there was
/// nothing to take out.
///
/// BEHAVIOR:
/// The object is told first (`DTM_REMOVEDTOBJECT`), which is where a
/// class stops whatever it had running - a sound playing, an animation
/// - and then it is taken off the window's gadget list. It is not
/// disposed of: it can be put into another window.
///
/// CONTEXT:
/// - Waits: for the window's layer, and for whatever the object stops.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The object stays the caller's.
///
/// SEE ALSO:
/// `AddDTObject`, `DisposeDTObject`
///
/// EXAMPLES:
/// ```zig
/// _ = dt.RemoveDTObject(window, picture);
/// ```
pub fn RemoveDTObject(db: *DataTypesBase, window: ?*intuition.Window, object: ?*classusr.Object) i32 {
    const it = object orelse return -1;
    const w = window orelse return -1;
    var gone = dtc.DtGeneral{ .method_id = dtc.DTM_REMOVEDTOBJECT };
    _ = db.intuition_base.DoGadgetMethodA(it, w, null, @ptrCast(&gone));
    return db.intuition_base.RemoveGList(w, it, 1);
}

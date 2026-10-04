// SPDX-License-Identifier: MIT
//! DoDTMethodA: a method sent to an object.

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

/// Sends a method to an object.
///
/// SYNOPSIS:
/// ```zig
/// fn DoDTMethodA(db: *DataTypesBase, object: *classusr.Object, window: ?*intuition.Window, requester: ?*intuition.Requester, msg: *classusr.Msg) u32
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `object` - a data type object.
/// - `window`, `requester` - where it is; null when it is in neither.
/// - `msg` - the method and whatever goes with it.
///
/// RESULT:
/// What the object answered.
///
/// BEHAVIOR:
/// The window and requester are put into the message's `GadgetInfo`
/// where it has one, so that a method that draws or scrolls knows where
/// the object is. That is the difference between this and sending the
/// message by hand.
///
/// CONTEXT:
/// - Waits: whatever the method waits for.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do, unless the method needs more.
///
/// OWNERSHIP:
/// The message stays the caller's.
///
/// SEE ALSO:
/// `GetDTMethods`, `GetDTTriggerMethods`
///
/// EXAMPLES:
/// ```zig
/// var copy = dtc.DtGeneral{ .method_id = dtc.DTM_COPY };
/// _ = dt.DoDTMethodA(text_object, window, null, @ptrCast(&copy));
/// ```
pub fn DoDTMethodA(db: *DataTypesBase, object: *classusr.Object, window: ?*intuition.Window, requester: ?*intuition.Requester, msg: *classusr.Msg) u32 {
    return @truncate(db.intuition_base.DoGadgetMethodA(object, window, requester, msg));
}

// SPDX-License-Identifier: MIT
//! AddDTObject: an object put into a window.

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

/// Puts an object into a window.
///
/// SYNOPSIS:
/// ```zig
/// fn AddDTObject(db: *DataTypesBase, window: ?*intuition.Window, requester: ?*intuition.Requester, object: ?*classusr.Object, position: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `window` - the window it goes in.
/// - `requester` - the requester in that window, or null.
/// - `object` - a data type object.
/// - `position` - where in the window's gadget list, as `AddGList`
///   takes it; -1 for the end.
///
/// RESULT:
/// Where it went in the list, or -1 when there was nothing to add.
///
/// BEHAVIOR:
/// The object becomes a gadget of the window and is laid out and drawn
/// from then on like any other. A program that puts the object in a
/// layout instead does not call this: the layout adds it.
///
/// CONTEXT:
/// - Waits: for the window's layer.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The object stays the caller's; it must be taken out again with
/// `RemoveDTObject` before it is disposed of.
///
/// SEE ALSO:
/// `RemoveDTObject`, `RefreshDTObjectA`, `NewDTObjectA`
///
/// EXAMPLES:
/// ```zig
/// _ = dt.AddDTObject(window, null, picture, -1);
/// dt.RefreshDTObjectA(picture, window, null, null);
/// ```
pub fn AddDTObject(db: *DataTypesBase, window: ?*intuition.Window, requester: ?*intuition.Requester, object: ?*classusr.Object, position: i32) i32 {
    _ = requester;
    const it = object orelse return -1;
    const w = window orelse return -1;
    return @bitCast(db.intuition_base.AddGList(w, it, position, 1));
}

// SPDX-License-Identifier: MIT
//! RefreshDTObjectA: an object drawn again.

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

/// Draws an object again.
///
/// SYNOPSIS:
/// ```zig
/// fn RefreshDTObjectA(db: *DataTypesBase, object: ?*classusr.Object, window: ?*intuition.Window, requester: ?*intuition.Requester, attrs: ?[*]const utility.TagItem) void
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `object` - a data type object, in a window.
/// - `window`, `requester` - where it is.
/// - `attrs` - set on the object first; null for none.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The attributes are set and the object is drawn whole. It is what a
/// program calls after adding an object to a window, and after anything
/// it did to the window that the object would not have heard about.
///
/// CONTEXT:
/// - Waits: for the window's layer.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// SEE ALSO:
/// `AddDTObject`, `SetDTAttrsA`
///
/// EXAMPLES:
/// ```zig
/// dt.RefreshDTObjectA(picture, window, null, null);
/// ```
pub fn RefreshDTObjectA(db: *DataTypesBase, object: ?*classusr.Object, window: ?*intuition.Window, requester: ?*intuition.Requester, attrs: ?[*]const utility.TagItem) void {
    _ = requester;
    const it = object orelse return;
    const w = window orelse return;
    if (attrs != null) _ = db.intuition_base.SetGadgetAttrsTagList(it, w, attrs);
    db.intuition_base.RefreshGList(it, w, 1);
}

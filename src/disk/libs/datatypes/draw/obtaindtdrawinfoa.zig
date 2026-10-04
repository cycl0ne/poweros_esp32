// SPDX-License-Identifier: MIT
//! ObtainDTDrawInfoA: an object made ready to draw elsewhere.

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

/// Makes an object ready to draw somewhere that is not its window.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainDTDrawInfoA(db: *DataTypesBase, object: *classusr.Object, attrs: ?[*]const utility.TagItem) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `object` - a data type object.
/// - `attrs` - what the drawing will need; null for the object's own
///   idea.
///
/// RESULT:
/// A handle to give to `DrawDTObjectA` and back to
/// `ReleaseDTDrawInfo`, or null when the object cannot be drawn that
/// way.
///
/// BEHAVIOR:
/// It is `DTM_OBTAINDRAWINFO` sent to the object. A class that has to
/// get ready - a picture that must be turned into the screen's pixels -
/// does it here, once, so that drawing the object many times costs that
/// work once.
///
/// CONTEXT:
/// - Waits: whatever the class waits for; a picture waits for memory.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// What is answered is the object's and is given back with
/// `ReleaseDTDrawInfo`.
///
/// SEE ALSO:
/// `DrawDTObjectA`, `ReleaseDTDrawInfo`
///
/// EXAMPLES:
/// ```zig
/// const handle = dt.ObtainDTDrawInfoA(picture, null) orelse return;
/// defer dt.ReleaseDTDrawInfo(picture, handle);
/// ```
pub fn ObtainDTDrawInfoA(db: *DataTypesBase, object: *classusr.Object, attrs: ?[*]const utility.TagItem) ?*anyopaque {
    var msg = dtc.DtDrawInfo{ .method_id = dtc.DTM_OBTAINDRAWINFO, .attrs = attrs };
    if (db.intuition_base.SendMessage(object, @ptrCast(&msg)) == 0) return null;
    return msg.handle;
}

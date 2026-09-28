// SPDX-License-Identifier: MIT
//! DrawDTObjectA: an object drawn into a RastPort.

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

/// Draws an object into a RastPort of the caller's.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawDTObjectA(db: *DataTypesBase, rast_port: *graphics.RastPort, object: *classusr.Object, left: i32, top: i32, width: i32, height: i32, top_horiz: i32, top_vert: i32, attrs: ?[*]const utility.TagItem) bool
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// - `rast_port` - where to draw.
/// - `object` - a data type object, made ready with
///   `ObtainDTDrawInfoA`.
/// - `left`, `top`, `width`, `height` - the box to draw into.
/// - `top_horiz`, `top_vert` - where in the object to start, in its own
///   units.
/// - `attrs` - anything more the class understands; null for none.
///
/// RESULT:
/// True when it drew.
///
/// BEHAVIOR:
/// It is `DTM_DRAW` sent to the object. This is how an object is drawn
/// somewhere other than its own window - into a bitmap, into another
/// window, into a part of one - and it does not need the object to be a
/// gadget of anything.
///
/// CONTEXT:
/// - Waits: whatever the class waits for.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// `ObtainDTDrawInfoA` first, or a class that has work to do before it
/// can draw will refuse.
///
/// SEE ALSO:
/// `ObtainDTDrawInfoA`, `ReleaseDTDrawInfo`
///
/// EXAMPLES:
/// ```zig
/// _ = dt.DrawDTObjectA(rp, picture, 0, 0, 320, 200, 0, 0, null);
/// ```
pub fn DrawDTObjectA(db: *DataTypesBase, rast_port: *graphics.RastPort, object: *classusr.Object, left: i32, top: i32, width: i32, height: i32, top_horiz: i32, top_vert: i32, attrs: ?[*]const utility.TagItem) bool {
    var msg = dtc.DtDraw{
        .rast_port = rast_port,
        .left = left,
        .top = top,
        .width = width,
        .height = height,
        .top_horiz = top_horiz,
        .top_vert = top_vert,
        .attrs = attrs,
    };
    return db.intuition_base.SendMessage(object, @ptrCast(&msg)) != 0;
}

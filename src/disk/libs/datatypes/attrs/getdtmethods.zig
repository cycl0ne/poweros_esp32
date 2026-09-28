// SPDX-License-Identifier: MIT
//! GetDTMethods: what an object answers.

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

/// Answers the methods an object knows.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDTMethods(db: *DataTypesBase, object: *classusr.Object) ?[*]const u32
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `object` - a data type object.
///
/// RESULT:
/// An array of method numbers ending in `~0`, or null when the object
/// does not say.
///
/// BEHAVIOR:
/// It is `DTA_Methods` read. A program uses it to grey out what an
/// object cannot do - no Copy for an object that does not answer
/// `DTM_COPY`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The array belongs to the object.
///
/// SEE ALSO:
/// `GetDTTriggerMethods`, `DoDTMethodA`
///
/// EXAMPLES:
/// ```zig
/// var at = dt.GetDTMethods(object);
/// while (at) |list| : (at = list + 1) { if (list[0] == ~@as(u32, 0)) break; }
/// ```
pub fn GetDTMethods(db: *DataTypesBase, object: *classusr.Object) ?[*]const u32 {
    var storage: usize = 0;
    if (db.intuition_base.GetAttr(dtc.DTA_Methods, object, &storage) == 0) return null;
    return @ptrFromInt(storage);
}

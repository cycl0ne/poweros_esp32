// SPDX-License-Identifier: MIT
//! GetDTTriggerMethods: what an object can be told to do.

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

/// Answers what an object can be told to do, with a name for each.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDTTriggerMethods(db: *DataTypesBase, object: *classusr.Object) ?[*]const dtc.DTMethod
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `object` - a data type object.
///
/// RESULT:
/// An array of `DTMethod` ending in one with a null label, or null when
/// the object says nothing.
///
/// BEHAVIOR:
/// It is `DTA_TriggerMethods` read. Each entry carries a name to put in
/// a menu and the `STM_` number to send with `DTM_TRIGGER`, so a
/// program shows what an object offers - Play, Pause, Rewind - without
/// knowing what kind of object it is.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The array belongs to the object.
///
/// SEE ALSO:
/// `GetDTMethods`, `DoDTMethodA`
///
/// EXAMPLES:
/// ```zig
/// var at = dt.GetDTTriggerMethods(object);
/// while (at) |list| : (at = list + 1) { const label = list[0].label orelse break; }
/// ```
pub fn GetDTTriggerMethods(db: *DataTypesBase, object: *classusr.Object) ?[*]const dtc.DTMethod {
    var storage: usize = 0;
    if (db.intuition_base.GetAttr(dtc.DTA_TriggerMethods, object, &storage) == 0) return null;
    return @ptrFromInt(storage);
}

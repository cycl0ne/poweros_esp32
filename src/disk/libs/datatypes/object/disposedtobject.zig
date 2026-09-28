// SPDX-License-Identifier: MIT
//! DisposeDTObject: an object given back.

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

const ReleaseDataType = @import("../type/releasedatatype.zig").ReleaseDataType;

/// Gives an object back.
///
/// SYNOPSIS:
/// ```zig
/// fn DisposeDTObject(db: *DataTypesBase, object: ?*classusr.Object) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `object` - what `NewDTObjectA` answered; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The object is disposed of, which closes the source it was reading
/// from and lets go of its data type. It must have been taken out of
/// its window first (`RemoveDTObject`), and anything laying it out is
/// waited for.
///
/// The class library the object belongs to has nothing holding it once
/// its last object is gone, so it is unloaded when memory runs short.
///
/// CONTEXT:
/// - Waits: for the object's layout to finish.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: needed - closing a file is dos's.
///
/// OWNERSHIP:
/// Everything the object held goes with it.
///
/// SEE ALSO:
/// `NewDTObjectA`, `RemoveDTObject`
///
/// EXAMPLES:
/// ```zig
/// _ = dt.RemoveDTObject(window, picture);
/// dt.DisposeDTObject(picture);
/// ```
pub fn DisposeDTObject(db: *DataTypesBase, object: ?*classusr.Object) void {
    const it = object orelse return;
    if (_class.dataOf(db, it)) |own| {
        const kind = own.data_type;
        own.data_type = null;
        db.intuition_base.DisposeObject(it);
        ReleaseDataType(db, kind);
        return;
    }
    db.intuition_base.DisposeObject(it);
}

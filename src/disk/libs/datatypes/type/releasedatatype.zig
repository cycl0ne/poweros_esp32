// SPDX-License-Identifier: MIT
//! ReleaseDataType: a data type let go of.

const sdk = @import("sdk");
const datatypes = sdk.datatypes;
const _base = @import("../datatypes_base.zig");
const DataTypesBase = _base.DataTypesBase;

/// Lets go of a data type.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseDataType(db: *DataTypesBase, dt: ?*datatypes.DataType) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `dt` - what `ObtainDataTypeA` answered; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The descriptor is not freed - it belongs to the list `C:AddDataTypes`
/// published - but it is no longer counted as held, and once nothing
/// holds it it may be taken off the list again.
///
/// CONTEXT:
/// - Waits: on the list's lock, briefly.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. The pointer must not be used afterwards.
///
/// NOTES:
/// An object made by `NewDTObjectA` holds its data type for as long as
/// it lives and lets go of it when it is disposed of, so a program that
/// only makes objects never calls this.
///
/// SEE ALSO:
/// `ObtainDataTypeA`, `DisposeDTObject`
///
/// EXAMPLES:
/// ```zig
/// dt.ReleaseDataType(kind);
/// ```
pub fn ReleaseDataType(db: *DataTypesBase, dt: ?*datatypes.DataType) void {
    const given = dt orelse return;
    const list = db.list orelse return;
    const sys = db.sys_base;
    sys.ObtainSemaphore(&list.lock);
    defer sys.ReleaseSemaphore(&list.lock);
    if (given.uses != 0) given.uses -= 1;
}

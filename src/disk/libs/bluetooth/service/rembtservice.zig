// SPDX-License-Identifier: MIT
//! RemBTService: a program's record served no more.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _service = @import("_service.zig");

/// Gives back a record AddBTService served.
///
/// SYNOPSIS:
/// ```zig
/// fn RemBTService(base: *BluetoothBase, record: ?*bluetooth.BTRecord) void
/// ```
///
/// SINCE: 1.9. LVO -176.
///
/// INPUTS:
/// - `record` - from AddBTService; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The SDP server answers with the record no more - a device's search
/// does not find it, its handle is not known - and its copy is freed.
///
/// CONTEXT:
/// - Waits: yes, for the records' list.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle is gone.
///
/// BUGS:
/// An answer in parts is made again from the records for each part: a
/// device that reads one while a record is added or given back reads the
/// parts after that from the records as they are then.
///
/// SEE ALSO:
/// `AddBTService`
///
/// EXAMPLES:
/// ```zig
/// bt.RemBTService(served);
/// ```
pub fn RemBTService(base: *BluetoothBase, record: ?*bluetooth.BTRecord) void {
    const sys = base.sys_base;
    const kept: *_service.Record = @ptrCast(@alignCast(record orelse return));
    // Under the lock the server's copies are made under: none after it.
    sys.ObtainSemaphore(&base.records_lock);
    sys.Remove(&kept.node);
    sys.ReleaseSemaphore(&base.records_lock);
    sys.FreeVec(kept);
}

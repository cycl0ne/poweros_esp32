// SPDX-License-Identifier: MIT
//! RemBTNotify: no more signals.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _notify = @import("_notify.zig");

/// Ends what AddBTNotify asked for.
///
/// SYNOPSIS:
/// ```zig
/// fn RemBTNotify(base: *BluetoothBase, notify: ?*bluetooth.BTNotify) void
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `notify` - from AddBTNotify; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// No signal is sent after it returns.
///
/// CONTEXT:
/// - Waits: yes, for the notification list.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle is gone.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddBTNotify`
///
/// EXAMPLES:
/// ```zig
/// bt.RemBTNotify(handle);
/// ```
pub fn RemBTNotify(base: *BluetoothBase, notify: ?*bluetooth.BTNotify) void {
    const sys = base.sys_base;
    const record: *_notify.Record = @ptrCast(@alignCast(notify orelse return));
    sys.ObtainSemaphore(&base.notify_lock);
    sys.Remove(&record.node);
    sys.ReleaseSemaphore(&base.notify_lock);
    sys.FreeMem(record, @sizeOf(_notify.Record));
}

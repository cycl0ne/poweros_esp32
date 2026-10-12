// SPDX-License-Identifier: MPL-2.0
//! RemBatteryNotify: no more of that.

const sdk = @import("sdk");
const battery = sdk.resources.battery;
const BatteryBase = @import("../battery_base.zig").BatteryBase;
const _notify = @import("_notify.zig");

/// A request of AddBatteryNotify's given back.
///
/// SYNOPSIS:
/// ```zig
/// fn RemBatteryNotify(bb: *BatteryBase, notify: ?*battery.BatteryNotify) void
/// ```
///
/// SINCE: 1.0. LVO -12.
///
/// INPUTS:
/// - `notify` - what AddBatteryNotify answered; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The request leaves the list and is freed. Once this returns no signal
/// of it is sent; one sent just before may still be pending in the
/// task's signals.
///
/// CONTEXT:
/// - Waits: for the resource's semaphore.
/// - Interrupts: no.
/// - Locks: takes the resource's semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The request is gone; its signals are the task's again.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddBatteryNotify`
///
/// EXAMPLES:
/// ```zig
/// bb.RemBatteryNotify(notify);
/// sys.FreeSignal(bit);
/// ```
pub fn RemBatteryNotify(bb: *BatteryBase, notify: ?*battery.BatteryNotify) void {
    const sys = bb.sys_base;
    const record: *_notify.Record = @ptrCast(@alignCast(notify orelse return));
    sys.ObtainSemaphore(&bb.lock);
    sys.Remove(&record.node);
    sys.ReleaseSemaphore(&bb.lock);
    sys.FreeMem(record, @sizeOf(_notify.Record));
}

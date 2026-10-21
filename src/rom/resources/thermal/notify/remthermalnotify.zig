// SPDX-License-Identifier: MPL-2.0
//! RemThermalNotify: no more of that.

const sdk = @import("sdk");
const thermal = sdk.resources.thermal;
const ThermalBase = @import("../thermal_base.zig").ThermalBase;
const _notify = @import("_notify.zig");

/// A request of AddThermalNotify's given back.
///
/// SYNOPSIS:
/// ```zig
/// fn RemThermalNotify(tb: *ThermalBase, notify: ?*thermal.ThermalNotify) void
/// ```
///
/// SINCE: 1.0. LVO -12.
///
/// INPUTS:
/// - `notify` - what AddThermalNotify answered; null does nothing.
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
/// `AddThermalNotify`
///
/// EXAMPLES:
/// ```zig
/// tb.RemThermalNotify(notify);
/// sys.FreeSignal(bit);
/// ```
pub fn RemThermalNotify(tb: *ThermalBase, notify: ?*thermal.ThermalNotify) void {
    const sys = tb.sys_base;
    const record: *_notify.Record = @ptrCast(@alignCast(notify orelse return));
    sys.ObtainSemaphore(&tb.lock);
    sys.Remove(&record.node);
    sys.ReleaseSemaphore(&tb.lock);
    sys.FreeMem(record, @sizeOf(_notify.Record));
}

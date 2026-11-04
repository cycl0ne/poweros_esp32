// SPDX-License-Identifier: MPL-2.0
//! RemPowerNotify: no more of that.

const sdk = @import("sdk");
const power = sdk.resources.power;
const PowerBase = @import("../power_base.zig").PowerBase;
const _notify = @import("_notify.zig");

/// A request of AddPowerNotify's given back.
///
/// SYNOPSIS:
/// ```zig
/// fn RemPowerNotify(pb: *PowerBase, notify: ?*power.PowerNotify) void
/// ```
///
/// SINCE: 1.0. LVO -16.
///
/// INPUTS:
/// - `notify` - what AddPowerNotify answered; null does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The request leaves the list and is freed. Once this returns no signal
/// of it is sent; one sent just before may still be pending in the task's
/// signals. Where it was the last request, the press is the resource's
/// again: the next one stops the drives and turns the machine off.
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
/// `AddPowerNotify`
///
/// EXAMPLES:
/// ```zig
/// pb.RemPowerNotify(notify);
/// sys.FreeSignal(bit);
/// ```
pub fn RemPowerNotify(pb: *PowerBase, notify: ?*power.PowerNotify) void {
    const sys = pb.sys_base;
    const record: *_notify.Record = @ptrCast(@alignCast(notify orelse return));
    sys.ObtainSemaphore(&pb.lock);
    sys.Remove(&record.node);
    sys.ReleaseSemaphore(&pb.lock);
    sys.FreeMem(record, @sizeOf(_notify.Record));
}

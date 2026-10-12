// SPDX-License-Identifier: MPL-2.0
//! AddBatteryNotify: a task told when the battery's state changes.

const sdk = @import("sdk");
const exec = sdk.exec;
const battery = sdk.resources.battery;
const BatteryBase = @import("../battery_base.zig").BatteryBase;
const _notify = @import("_notify.zig");

/// `signals` sent to `task` whenever the battery's state changes.
///
/// SYNOPSIS:
/// ```zig
/// fn AddBatteryNotify(bb: *BatteryBase, task: *exec.Task, signals: u32) ?*battery.BatteryNotify
/// ```
///
/// SINCE: 1.0. LVO -8.
///
/// INPUTS:
/// - `task` - the task to tell: usually the caller, `FindTask(null)`.
/// - `signals` - the signal bits to send it, from its own AllocSignal.
///
/// RESULT:
/// The request, to be given back with RemBatteryNotify; null without
/// memory for it.
///
/// BEHAVIOR:
/// From now on the resource's task sends `signals` whenever a flag of
/// BATTF_CHANGES changes after a measurement: a cell found or lost,
/// external power coming or going, charging starting or ending, the
/// charge passing BATTERY_LOW or BATTERY_CRITICAL. The voltage and the
/// charge moving within those bounds are no change. The signal says only
/// that something changed: the program reads the state with ReadBattery.
///
/// CONTEXT:
/// - Waits: for memory, and the resource's semaphore.
/// - Interrupts: no.
/// - Locks: takes the resource's semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The request is the resource's. The signals stay the task's: it frees
/// them after RemBatteryNotify, not before.
///
/// NOTES:
/// Nothing is sent on a board with nothing to measure.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemBatteryNotify`, `ReadBattery`
///
/// EXAMPLES:
/// ```zig
/// const bit = sys.AllocSignal(-1);
/// const notify = bb.AddBatteryNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(bit));
/// ```
pub fn AddBatteryNotify(bb: *BatteryBase, task: *exec.Task, signals: u32) ?*battery.BatteryNotify {
    const sys = bb.sys_base;
    const memory = sys.AllocMem(@sizeOf(_notify.Record), exec.MEMF_CLEAR) orelse return null;
    const record: *_notify.Record = @ptrCast(@alignCast(memory));
    record.* = .{ .task = task, .signals = signals };
    sys.ObtainSemaphore(&bb.lock);
    sys.AddTail(&bb.notify, &record.node);
    sys.ReleaseSemaphore(&bb.lock);
    return @ptrCast(record);
}

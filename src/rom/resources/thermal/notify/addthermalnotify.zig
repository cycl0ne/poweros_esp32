// SPDX-License-Identifier: MPL-2.0
//! AddThermalNotify: a task told when a sensor passes a limit.

const sdk = @import("sdk");
const exec = sdk.exec;
const thermal = sdk.resources.thermal;
const ThermalBase = @import("../thermal_base.zig").ThermalBase;
const _notify = @import("_notify.zig");

/// `signals` sent to `task` whenever a sensor passes its hot or its
/// critical temperature.
///
/// SYNOPSIS:
/// ```zig
/// fn AddThermalNotify(tb: *ThermalBase, task: *exec.Task, signals: u32) ?*thermal.ThermalNotify
/// ```
///
/// SINCE: 1.0. LVO -8.
///
/// INPUTS:
/// - `task` - the task to tell: usually the caller, `FindTask(null)`.
/// - `signals` - the signal bits to send it, from its own AllocSignal.
///
/// RESULT:
/// The request, to be given back with RemThermalNotify; null without
/// memory for it.
///
/// BEHAVIOR:
/// From now on the resource's task sends `signals` whenever a flag of
/// THERMF_CHANGES changes for any sensor after a reading: THERMF_HOT or
/// THERMF_CRITICAL set as the reading reaches the limit, or cleared as it
/// falls THERMAL_HYSTERESIS below it - or as the sensor stops giving
/// readings. The temperature moving between the limits is no change. The
/// signal says only that something changed: the program reads the
/// sensors with ReadTemperature.
///
/// CONTEXT:
/// - Waits: for memory, and the resource's semaphore.
/// - Interrupts: no.
/// - Locks: takes the resource's semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The request is the resource's. The signals stay the task's: it frees
/// them after RemThermalNotify, not before.
///
/// NOTES:
/// Nothing is sent on a board without a sensor, nor for a sensor whose
/// chip names no limits.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemThermalNotify`, `ReadTemperature`
///
/// EXAMPLES:
/// ```zig
/// const bit = sys.AllocSignal(-1);
/// const notify = tb.AddThermalNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(bit));
/// ```
pub fn AddThermalNotify(tb: *ThermalBase, task: *exec.Task, signals: u32) ?*thermal.ThermalNotify {
    const sys = tb.sys_base;
    const memory = sys.AllocMem(@sizeOf(_notify.Record), exec.MEMF_CLEAR) orelse return null;
    const record: *_notify.Record = @ptrCast(@alignCast(memory));
    record.* = .{ .task = task, .signals = signals };
    sys.ObtainSemaphore(&tb.lock);
    sys.AddTail(&tb.notify, &record.node);
    sys.ReleaseSemaphore(&tb.lock);
    return @ptrCast(record);
}

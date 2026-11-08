// SPDX-License-Identifier: MPL-2.0
//! AddPowerNotify: a task told when the power button is pressed.

const sdk = @import("sdk");
const exec = sdk.exec;
const power = sdk.resources.power;
const PowerBase = @import("../power_base.zig").PowerBase;
const _notify = @import("_notify.zig");

/// `signals` sent to `task` when the machine's power button is pressed.
///
/// SYNOPSIS:
/// ```zig
/// fn AddPowerNotify(pb: *PowerBase, task: *exec.Task, signals: u32) ?*power.PowerNotify
/// ```
///
/// SINCE: 1.0. LVO -12.
///
/// INPUTS:
/// - `task` - the task to tell: usually the caller, `FindTask(null)`.
/// - `signals` - the signal bits to send it, from its own AllocSignal.
///
/// RESULT:
/// The request, to be given back with RemPowerNotify; null on a machine
/// whose button says nothing (PowerAbilities without POWERF_BUTTON), and
/// without memory for the request.
///
/// BEHAVIOR:
/// From now on `signals` reaches `task` whenever the button is pressed.
/// The signal says that it was pressed and nothing else; two presses
/// before the task looks are one.
///
/// **It takes the press over.** While anything is asking, the resource
/// does no more than tell: whether the machine is then turned off, and
/// what is asked of whoever is in front of it first, is the program's.
/// The resource's own answer - the drives stopped and the machine turned
/// off - is for a machine where nobody is asking, and comes back as soon
/// as the last request is given back.
///
/// CONTEXT:
/// - Waits: for memory, and the resource's semaphore.
/// - Interrupts: no.
/// - Locks: takes the resource's semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The request is the resource's. The signals stay the task's: it frees
/// them after RemPowerNotify, not before. A task that ends without
/// giving its request back leaves the resource signalling a task that is
/// gone, so it gives it back first.
///
/// NOTES:
/// What reaches the task is a request, not a machine already going down:
/// it has as long as it likes to answer it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemPowerNotify`, `PowerOff`, `PowerAbilities`
///
/// EXAMPLES:
/// ```zig
/// const bit = sys.AllocSignal(-1);
/// const notify = pb.AddPowerNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(bit));
/// ```
pub fn AddPowerNotify(pb: *PowerBase, task: *exec.Task, signals: u32) ?*power.PowerNotify {
    if (pb.abilities & power.POWERF_BUTTON == 0) return null;
    const sys = pb.sys_base;
    const memory = sys.AllocMem(@sizeOf(_notify.Record), exec.MEMF_CLEAR) orelse return null;
    const record: *_notify.Record = @ptrCast(@alignCast(memory));
    record.* = .{ .task = task, .signals = signals };
    sys.ObtainSemaphore(&pb.lock);
    sys.AddTail(&pb.notify, &record.node);
    sys.ReleaseSemaphore(&pb.lock);
    return @ptrCast(record);
}

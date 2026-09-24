// SPDX-License-Identifier: MPL-2.0
//! RemTask: ends a task. Another task is taken off its list and its memory
//! freed; the running task cannot free the stack it is running on, so it
//! is marked removed and the dispatcher frees it once nothing runs there.

const sdk = @import("sdk");
const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;

/// Ends a task, and frees what `CreateTask` allocated for it.
///
/// SYNOPSIS:
/// ```zig
/// fn RemTask(base: *ExecBase, task: ?*Task) void
/// ```
///
/// SINCE: 1.0. LVO -164.
///
/// INPUTS:
/// - `task` - the task to end, or **null for the calling task**.
///
/// RESULT:
/// Nothing, and for null it does not return at all.
///
/// BEHAVIOR:
/// **Removing yourself** cannot free your own stack, because you are still
/// running on it. The task is marked and the processor given up, and the
/// scheduler frees the memory once nothing is running on it any more.
///
/// **Removing another task** takes it off whichever list it is on and frees
/// its memory there and then.
///
/// Either way, only what `CreateTask` allocated is freed. A task the caller
/// laid out by hand has its own memory back and nothing has been done to
/// it.
///
/// CONTEXT:
/// - Waits: no. For null it never returns, which is not the same thing.
/// - Interrupts: no. It takes Disable and may free memory.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Memory from `CreateTask` goes back to the system. Anything the task
/// itself allocated is not freed - signals, ports, memory - so a task that
/// is removed from outside leaks whatever it was holding. That is why a
/// task is normally asked to end itself.
///
/// NOTES:
/// It does not warn the task or give it a chance to clean up. `Signal` with
/// `SIGBREAKF_CTRL_C` is how a task is asked rather than told.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddTask`, `CreateTask`, `Signal`
///
/// EXAMPLES:
/// ```zig
/// sys.RemTask(null); // does not return
/// ```
pub fn RemTask(base: *ExecBase, task: ?*Task) void {
    const sys = base.iface();
    const current = sys.FindTask(null).?;
    const ending = task orelse current;
    sys.Disable();
    if (ending == current) {
        // Freed by reschedule once it no longer runs on it.
        ending.state = .removed;
        base.sys_flags |= _task.SFF_SAR;
        _task.task_hardware.switch_now();
        sys.Enable(); // only reached without task hardware
        return;
    }
    if (ending.state == .ready or ending.state == .wait) sys.Remove(&ending.node);
    ending.state = .removed;
    sys.Enable();
    _task.freeTaskMemory(base, ending);
}

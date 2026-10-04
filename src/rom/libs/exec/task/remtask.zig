// SPDX-License-Identifier: MPL-2.0
//! RemTask: ends a task. Another task is taken off its list and its memory
//! freed - one running on the other core stopped there first; the running
//! task cannot free the stack it is running on, so it is marked removed and
//! the dispatcher frees it once nothing runs there.

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
/// **First, its end hooks** (`AddTaskEndHook`) run, in the order they were
/// put on, on the task calling this and with nothing held - what libraries
/// held for the task is let go while the task is still there.
///
/// **Removing yourself** cannot free your own stack, because you are still
/// running on it. The task is marked and the processor given up, and the
/// scheduler frees the memory once nothing is running on it any more.
///
/// **Removing another task** takes it off whichever list it is on and frees
/// its memory there and then. One running on the other core is stopped
/// first: that core switches it out at its next switch point - outside
/// Forbid and Disable - and the caller waits for that, in `Wait`, before
/// the end hooks run.
///
/// Either way, only what `CreateTask` allocated is freed. A task the caller
/// laid out by hand has its own memory back and nothing has been done to
/// it.
///
/// CONTEXT:
/// - Waits: for a task running on the other core, until that core has
///   switched it out (its `SIGF_SINGLE`). For null it never returns, which
///   is not the same thing.
/// - Interrupts: no. It takes Disable, may free memory, and runs the
///   task's end hooks.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Memory from `CreateTask` goes back to the system, and what a library
/// held for the task through an end hook goes back to that library.
/// Anything else the task itself allocated is not freed - signals, ports, memory - so a task that
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
/// `AddTask`, `CreateTask`, `Signal`, `AddTaskEndHook`
///
/// EXAMPLES:
/// ```zig
/// sys.RemTask(null); // does not return
/// ```
pub fn RemTask(base: *ExecBase, task: ?*Task) void {
    const sys = base.iface();
    const current = sys.FindTask(null).?;
    const ending = task orelse current;
    if (ending != current) _task.stopElsewhere(base, ending);
    _task.runEndHooks(base, ending);
    sys.Disable();
    if (ending == current) {
        // Freed by reschedule once it no longer runs on it.
        ending.state = .removed;
        base.cpu().sys_flags |= _task.SFF_SAR;
        _task.task_hardware.switch_now();
        sys.Enable(); // only reached without task hardware
        return;
    }
    if (ending.state == .ready or ending.state == .wait) sys.Remove(&ending.node);
    ending.state = .removed;
    sys.Enable();
    _task.freeTaskMemory(base, ending);
}

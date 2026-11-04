// SPDX-License-Identifier: MPL-2.0
//! SetTaskAffinity: the core a task keeps to, and the task moved when it
//! is somewhere it may no longer be.

const sdk = @import("sdk");
const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;

/// Sets the core a task keeps to.
///
/// SYNOPSIS:
/// ```zig
/// fn SetTaskAffinity(base: *ExecBase, task: ?*Task, core: u32) u32
/// ```
///
/// SINCE: 1.4. LVO -516.
///
/// INPUTS:
/// - `task` - the task; null for the caller.
/// - `core` - the core's own number, counted from 0, to keep it there;
///   `ANY_CORE` for whichever core is free.
///
/// RESULT:
/// The core it kept to before, as `core`.
///
/// BEHAVIOR:
/// The core is the task's `core` field. Every dispatcher reads it each
/// time it picks a task, so the change holds from the next pick on: a
/// ready task is offered to the core it belongs on now, and a running one
/// on a core it may no longer use is switched out at that core's next
/// switch point and taken up by the right one.
///
/// The idle tasks keep to a core each, and so does the code that must -
/// the Wi-Fi vendor code to core 0.
///
/// A task kept to a core that is not running never runs, and so does one
/// kept to a core the machine does not have: `CoreTask` answers null past
/// the last core there is, which is how many there are.
///
/// CONTEXT:
/// - Waits: no, but the caller may switch - to the other core, when it
///   pinned itself away from this one.
/// - Interrupts: no. It takes Disable.
/// - Locks: takes Disable. With a spinlock held the move waits for the
///   `ReleaseLock`, as every switch does.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// A task that is to keep to a core from its first instruction has that
/// core in the `Task` handed to `AddTask`; dos's `NP_Affinity` does it for
/// a process.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetTaskPri`, `CreateTask`, `AddTask`
///
/// EXAMPLES:
/// ```zig
/// // A task made already, moved to core 0.
/// _ = sys.SetTaskAffinity(task, 0);
///
/// // One that keeps to a core from its first instruction: it is in the
/// // Task before AddTask.
/// radio.task = .{ .node = .{ .name = "radio", .pri = 5 }, .core = 0, .sp_lower = lower, .sp_upper = upper };
/// _ = sys.AddTask(&radio.task, &radioCode, null);
///
/// // Back to whichever core is free.
/// _ = sys.SetTaskAffinity(task, sdk.exec.ANY_CORE);
/// ```
pub fn SetTaskAffinity(base: *ExecBase, task: ?*Task, core: u32) u32 {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable(); // where a move of the caller is taken
    const target = task orelse base.cpu().this_task;
    const old = target.core;
    target.core = core;
    switch (target.state) {
        .ready => _task.wakeFor(base, target),
        .run => _task.askCoreOf(base, target),
        else => {},
    }
    return old;
}

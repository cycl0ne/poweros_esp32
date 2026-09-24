// SPDX-License-Identifier: MPL-2.0
//! SetTaskPri: changes a task's priority, moving it on the ready list and
//! asking for a switch when the change means someone else should run.

const sdk = @import("sdk");
const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;

/// Changes a task's priority, and reschedules if that changed who should
/// run.
///
/// SYNOPSIS:
/// ```zig
/// fn SetTaskPri(base: *ExecBase, task: *Task, pri: i8) i8
/// ```
///
/// SINCE: 1.0. LVO -172.
///
/// INPUTS:
/// - `task` - the task to change. Its own, or another's.
/// - `pri` - the new priority, -128 to 127. Higher runs first.
///
/// RESULT:
/// The priority it had.
///
/// BEHAVIOR:
/// A ready task is requeued, so it takes its new place among its equals -
/// and since `Enqueue` puts it behind the ones already there, raising a
/// task to a priority it already had moves it to the back of that group.
///
/// A switch is asked for when the change made one right: the task lowered
/// itself below a ready task, or another task was raised above the running
/// one. It is taken at the `Enable` here, or postponed by a Forbid.
///
/// CONTEXT:
/// - Waits: no, but it may switch.
/// - Interrupts: no. It takes Disable.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// Priority is not a share of the processor. A higher-priority task that is
/// ready runs, and the ones below it do not run at all until it waits - so
/// a busy task at a high priority starves everything under it rather than
/// being favoured over it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddTask`, `FindTask`, `Wait`
///
/// EXAMPLES:
/// ```zig
/// const old = sys.SetTaskPri(sys.FindTask(null).?, 5);
/// defer _ = sys.SetTaskPri(sys.FindTask(null).?, old);
/// ```
pub fn SetTaskPri(base: *ExecBase, task: *Task, pri: i8) i8 {
    const sys = base.iface();
    sys.Disable();
    const current = sys.FindTask(null).?;
    const old = task.node.pri;
    task.node.pri = pri;
    if (task.state == .ready) {
        sys.Remove(&task.node);
        sys.Enqueue(&base.task_ready, &task.node);
    }
    if (task == current) {
        if (_task.firstReady(base)) |best| {
            if (best.node.pri > pri) base.sys_flags |= _task.SFF_SAR;
        }
    } else if (task.state == .ready and pri > current.node.pri) {
        base.sys_flags |= _task.SFF_SAR;
    }
    sys.Enable();
    return old;
}

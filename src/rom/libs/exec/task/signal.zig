// SPDX-License-Identifier: MPL-2.0
//! Signal: sets signals in a task. A task waiting for one of them is made
//! ready - and takes the processor at once if it outranks the caller - and
//! one with exception code for them gets its exception.

const sdk = @import("sdk");
const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;

/// Sends signals to a task, waking it if it was waiting for one of them.
///
/// SYNOPSIS:
/// ```zig
/// fn Signal(base: *ExecBase, task: *Task, signals: u32) void
/// ```
///
/// SINCE: 1.0. LVO -176.
///
/// INPUTS:
/// - `task` - who to signal. It must still exist, which is the caller's to
///   be sure of.
/// - `signals` - a mask of bits to set. Several at once is fine.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The bits are set in the task's received set. If it was waiting for any
/// of them it becomes ready, and **runs at once if its priority is higher
/// than the caller's** - so this call may cost the caller the processor.
///
/// A bit that is in the task's exception set raises its exception instead,
/// which also wakes a waiting task.
///
/// Signalling a task that is not waiting simply leaves the bits set, and
/// its next `Wait` for them returns immediately. Nothing is lost by
/// signalling early; what is lost is the second of two signals on a bit
/// that was already set.
///
/// CONTEXT:
/// - Waits: no, but it may switch.
/// - Interrupts: **safe, and this is the main way out of one.** An
///   interrupt cannot wait, allocate or reach a handler; what it can do is
///   signal the task that can.
/// - Forbid: not needed; it takes Disable. Under Forbid the switch is
///   postponed to the `Permit`.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// Signalling a task that has ended writes through a freed pointer. Where
/// the task may end on its own, what is signalled is a port it owns and the
/// arrangement to take it down is made between the two.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Wait`, `AllocSignal`, `SetExcept`, `PutMsg`
///
/// EXAMPLES:
/// ```zig
/// sys.Signal(waiting_task, @as(u32, 1) << @intCast(bit));
/// ```
pub fn Signal(base: *ExecBase, task: *Task, signals: u32) void {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    const current = sys.FindTask(null).?;
    task.sig_recvd |= signals;
    const except = _task.exceptionPending(task);
    if (task.state == .wait and (task.sig_recvd & task.sig_wait != 0 or except)) {
        sys.Remove(&task.node);
        task.state = .ready;
        sys.Enqueue(&base.task_ready, &task.node);
        if (task.node.pri > current.node.pri) base.sys_flags |= _task.SFF_SAR;
    } else if (task == current and except) {
        base.sys_flags |= _task.SFF_SAR; // raised at the next exception exit
    }
}

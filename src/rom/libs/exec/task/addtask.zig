// SPDX-License-Identifier: MPL-2.0
//! AddTask: starts a task the caller laid out - its context built so that
//! it begins in its code, and on the ready list by priority. One of higher
//! priority than the caller takes the processor at once.

const sdk = @import("sdk");
const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const vec = sdk.exec.vec;
const Task = sdk.exec.Task;
const TaskFn = sdk.exec.TaskFn;

/// Starts a task the caller has laid out, and makes it ready to run.
///
/// SYNOPSIS:
/// ```zig
/// fn AddTask(base: *ExecBase, task: *Task, init_pc: TaskFn,
///     final_pc: ?TaskFn) *Task
/// ```
///
/// SINCE: 1.0. LVO -160.
///
/// INPUTS:
/// - `task` - a `Task` the caller has filled in: its name and priority, and
///   its stack in `sp_lower`/`sp_upper`. The memory must outlive the task.
/// - `init_pc` - where it starts. It is handed the SDK's `ExecBase`, which
///   is how a task reaches the system without a global.
/// - `final_pc` - run when `init_pc` returns, or null. The task is removed
///   afterwards either way, so this is the last chance to clean up.
///
/// RESULT:
/// The task, so that `CreateTask` can hand it straight on.
///
/// BEHAVIOR:
/// The node's type becomes a task unless it is already a process, which is
/// how dos's processes stay processes through the call that starts them.
///
/// The new task is enqueued as ready, and **if its priority is higher than
/// the running task's it runs at once** - before this call returns, since
/// the `Enable` at the end of it is a point at which a switch is taken.
///
/// CONTEXT:
/// - Waits: no, but it may switch, so the caller may lose the processor
///   here.
/// - Interrupts: no. It takes Disable and touches the scheduler's lists.
/// - Forbid: not needed. Under Forbid the switch is postponed to the
///   matching `Permit`, which is a way to add several tasks before any of
///   them runs.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The `Task` and its stack stay the caller's to free, and must not be
/// freed while the task can still run. `CreateTask` is the call that owns
/// them instead.
///
/// NOTES:
/// The stack has to be big enough for the register windows the ABI spills
/// into it, which is why `CreateTask`'s smallest is 8 KiB rather than
/// something nominal.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateTask`, `RemTask`, `FindTask`, `SetTaskPri`
///
/// EXAMPLES:
/// ```zig
/// task.node.name = "my task";
/// task.node.pri = 0;
/// task.sp_lower = @intFromPtr(stack);
/// task.sp_upper = task.sp_lower + stack_size;
/// _ = sys.AddTask(task, &myTask, null);
/// ```
pub fn AddTask(base: *ExecBase, task: *Task, init_pc: TaskFn, final_pc: ?TaskFn) *Task {
    if (task.node.type != .process) task.node.type = .task;
    task.init_pc = init_pc;
    task.final_pc = final_pc;
    task.sig_alloc |= sdk.exec.tasks.system_signals;
    task.td_nest_cnt = -1;
    task.id_nest_cnt = -1;
    task.sp_reg = _task.task_hardware.init_context(task.sp_upper, vec(_task.taskEntry), task);

    const sys = base.iface();
    sys.Disable();
    task.state = .ready;
    sys.Enqueue(&base.task_ready, &task.node);
    if (task.node.pri > sys.FindTask(null).?.node.pri) base.sys_flags |= _task.SFF_SAR;
    sys.Enable(); // switches now if needed
    return task;
}

// SPDX-License-Identifier: MPL-2.0
//! AddTask: starts a task the caller laid out - its context built so that
//! it begins in its code, and on the ready list by priority. One of higher
//! priority than the caller takes the processor at once.

const sdk = @import("sdk");
const _task = @import("_task.zig");
const _memory = @import("../memory/_memory.zig");

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
/// - `task` - a `Task` the caller has filled in from the struct's defaults
///   (`.{}`): its name and priority, and its stack in `sp_lower`/
///   `sp_upper`. The memory must outlive the task.
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
/// Its time (`timeRun`) counts from 0.
///
/// **It gets its number** (`Task.id`), the next since the system started:
/// what the memory it allocates is marked with - unless `SetMemOwner`
/// gave it one already, before it started, which it keeps. A task its
/// creator allocated with one block - `CreateTask`'s, dos's processes - has
/// that block (`mem_block`) marked as its own from here, not the
/// creator's.
///
/// **The bottom four words of its stack become its guard** (from
/// `sp_lower`): a pattern the dispatcher looks at each time it switches
/// away from the task. Written over - the stack ran past its end - is a
/// dead-end alert, `AN_StackProbe`, in that task, before what the overflow
/// wrote over is used by anyone else. Those words are not the task's to
/// use. While memory debugging is on (`MemDebug`), a task whose stack
/// is 4 KiB or more gets a wide guard instead, 64 words (TF_WIDEGUARD), so
/// that a frame larger than four words still lands in it.
///
/// CONTEXT:
/// - Waits: no, but it may switch, so the caller may lose the processor
///   here.
/// - Interrupts: no. It takes Disable and touches the scheduler's lists.
/// - Locks: takes Disable. Tasks that must not start before one another are
///   made to wait for a signal before they start their work.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The `Task` and its stack stay the caller's to free, and must not be
/// freed while the task can still run. `CreateTask` is the call that owns
/// them instead.
///
/// NOTES:
/// The stack has to be big enough for the register windows the ABI spills
/// into it, which is why `CreateTask` gives 8 KiB when it is asked for no
/// size, and never less than 1 KiB, rather than something nominal.
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
    task.id_nest_cnt = -1;
    task.time_run_low = 0;
    task.time_run_high = 0;
    // Started while memory debugging is on, a task with room for it gets a
    // wide guard: a frame larger than the narrow one lands in it.
    task.flags &= ~sdk.exec.TF_WIDEGUARD;
    if (base.mem_debug.on and task.sp_upper - task.sp_lower >= _task.wide_guard_stack) task.flags |= sdk.exec.TF_WIDEGUARD;
    _task.guardStack(task);
    task.sp_reg = _task.task_hardware.init_context(task.sp_upper, vec(_task.taskEntry), task);

    const sys = base.iface();
    sys.Disable();
    // A number SetMemOwner gave the task before it started is kept; a
    // task that ran before gets a new one.
    if (task.state != .invalid or task.id == sdk.exec.MEMOWNER_SYSTEM) task.id = _task.nextTaskId(base);
    task.system_memory_nest = 0;
    // The task's own block - its TCB and stack, from newTask or its
    // creator - is its own from here, not its creator's.
    if (task.mem_block) |block| _memory.setOwner(block, task.id);
    task.state = .ready;
    sys.Enqueue(&base.task_ready, &task.node);
    _task.wakeFor(base, task);
    sys.Enable(); // switches now if needed
    return task;
}

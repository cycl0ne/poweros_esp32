// SPDX-License-Identifier: MPL-2.0
//! CreateTask: a task in one block - Task, name and stack together - and
//! started with `AddTask`, so that `RemTask` frees all of it at once.

const sdk = @import("sdk");
const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;
const TaskFn = sdk.exec.TaskFn;

/// Allocates a task with a stack of its own, and starts it.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateTask(base: *ExecBase, name: [:0]const u8, pri: i8,
///     init_pc: TaskFn, stack_size: usize) ?*Task
/// ```
///
/// SINCE: 1.0. LVO -196.
///
/// INPUTS:
/// - `name` - what the task is called. **Copied** into the task's own
///   memory, so the caller's string need not outlive the call.
/// - `pri` - its priority.
/// - `init_pc` - where it starts, handed the SDK's `ExecBase`.
/// - `stack_size` - bytes of stack, or 0 for the default 8 KiB. Rounded up
///   to at least a task's smallest.
///
/// RESULT:
/// The task, already running or ready, or null if there was no memory.
///
/// BEHAVIOR:
/// The `Task`, its name and its stack are one allocation, so `RemTask`
/// frees the whole of it in one call - which is what makes this the pair to
/// use when nothing else owns the task's memory.
///
/// As with `AddTask`, a task of higher priority than the caller's runs
/// before this returns.
///
/// CONTEXT:
/// - Waits: no, but it may switch.
/// - Interrupts: no. It allocates.
/// - Forbid: not needed.
/// - Process: a Task will do. This makes a Task and not a Process - dos's
///   `CreateNewProc` is what makes one of those, and only a Process may
///   reach a file system.
///
/// OWNERSHIP:
/// The task owns its memory and `RemTask` frees it. The caller must not
/// free anything, and must not use the pointer after the task has ended.
///
/// NOTES:
/// The pointer is worth only as much as the task's life. A task that ends
/// on its own leaves the caller holding freed memory, so either the caller
/// outlives the task or the two arrange something between them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddTask`, `RemTask`, `SetTaskPri`
///
/// EXAMPLES:
/// ```zig
/// const task = sys.CreateTask("my task", 0, &myTask, 0) orelse return;
/// ```
pub fn CreateTask(base: *ExecBase, name: [:0]const u8, pri: i8, init_pc: TaskFn, stack_size: usize) ?*Task {
    const task = _task.newTask(base, name, pri, if (stack_size == 0) _task.default_stack_size else stack_size) orelse return null;
    return base.iface().AddTask(task, init_pc, null);
}

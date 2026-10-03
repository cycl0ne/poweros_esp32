// SPDX-License-Identifier: MPL-2.0
//! AddTaskEndHook: something run when a task ends, for what a library
//! holds for it.

const sdk = @import("sdk");
const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;
const TaskEndHook = sdk.exec.TaskEndHook;
const _task = @import("_task.zig");

/// Have a hook run when a task ends.
///
/// SYNOPSIS:
/// ```zig
/// fn AddTaskEndHook(base: *ExecBase, task: ?*Task, hook: *TaskEndHook) void
/// ```
///
/// SINCE: 1.1. LVO -480.
///
/// INPUTS:
/// - `task` - the task whose end it waits for, or **null for the caller**.
/// - `hook` - `code` set, `data` as the caller likes, on no task's list.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The hook goes on the task's own list, in its TCB (`Task.end_hooks`),
/// after the ones put on before it. When the task ends - its code returns,
/// it calls `RemTask(null)`, or another task removes it - `RemTask` takes
/// each hook off in that order and runs it, before the task is taken away.
/// A hook runs once; `hook.task` is null again before it runs.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed; it takes Forbid for the list itself.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The hook stays the caller's memory, and must stay valid until it has
/// run or been taken off with `RemTaskEndHook`.
///
/// NOTES:
/// - What it is for: a library that hands a task something - an
///   animation, a timer, a socket - lets it go when the task ends without
///   giving it back, so nothing is left calling into code that is gone.
/// - The hook runs on the task that called `RemTask`, with nothing held:
///   it may take semaphores and free memory, and should not wait long,
///   since the task's end waits for it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemTaskEndHook`, `RemTask`
///
/// EXAMPLES:
/// ```zig
/// fn ended(sys: *ExecBase, task: *Task, hook: *TaskEndHook) callconv(.c) void {
///     const owner: *Owner = @ptrCast(@alignCast(hook.data.?));
///     owner.letGo(sys, task);
/// }
///
/// owner.hook = .{ .code = &ended, .data = owner };
/// sys.AddTaskEndHook(null, &owner.hook);
/// ```
pub fn AddTaskEndHook(base: *ExecBase, task: ?*Task, hook: *TaskEndHook) void {
    const sys = base.iface();
    const owner = task orelse sys.FindTask(null).?;
    sys.Forbid();
    defer sys.Permit();
    _task.endHooks(owner);
    hook.task = owner;
    sys.AddTail(@ptrCast(&owner.end_hooks), @ptrCast(&hook.node));
}

// SPDX-License-Identifier: MPL-2.0
//! RemTaskEndHook: a hook taken off its task before it runs.

const sdk = @import("sdk");
const ExecBase = @import("../exec.zig").ExecBase;
const TaskEndHook = sdk.exec.TaskEndHook;

/// Take a hook off the task it waits on, so it does not run.
///
/// SYNOPSIS:
/// ```zig
/// fn RemTaskEndHook(base: *ExecBase, hook: *TaskEndHook) void
/// ```
///
/// SINCE: 1.1. LVO -484.
///
/// INPUTS:
/// - `hook` - a hook put on with `AddTaskEndHook`, or one that has run or
///   was never put on.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A hook on a task's list is taken off it and will not run; its `task` is
/// null again. A hook on no list - one that has run, or never was put on -
/// is left as it is, so a library may call this whatever has happened.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: takes Disable, which the hooks are kept under.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The hook is the caller's again, to free or put on another task.
///
/// NOTES:
/// What a library calls when a task gives back what it held: nothing is
/// left for the task's end to do.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddTaskEndHook`, `RemTask`
///
/// EXAMPLES:
/// ```zig
/// sys.RemTaskEndHook(&owner.hook);
/// sys.FreeVec(owner);
/// ```
pub fn RemTaskEndHook(base: *ExecBase, hook: *TaskEndHook) void {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    if (hook.task == null) return;
    sys.Remove(@ptrCast(&hook.node));
    hook.task = null;
}

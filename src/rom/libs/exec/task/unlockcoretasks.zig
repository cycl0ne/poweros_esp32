// SPDX-License-Identifier: MPL-2.0
//! UnlockCoreTasks: gives back the lock LockCoreTasks took on a core's
//! tasks.

const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Gives back the lock `LockCoreTasks` took on core `core`.
///
/// SYNOPSIS:
/// ```zig
/// fn UnlockCoreTasks(base: *ExecBase, core: u32) void
/// ```
///
/// SINCE: 1.31. LVO -588.
///
/// INPUTS:
/// - `core` - the core `LockCoreTasks` was given.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The core's lists are let go, the caller's interrupts are put back as
/// they were, and a switch that came due meanwhile is taken - so this is
/// a point at which the caller may lose the processor. A core past the
/// last one the machine runs does nothing, as `LockCoreTasks` took
/// nothing for it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Locks: gives back what `LockCoreTasks` took.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// No node of the lists may be read after this.
///
/// NOTES:
/// One `UnlockCoreTasks` for every `LockCoreTasks` that answered a core,
/// with the same number.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LockCoreTasks`
///
/// EXAMPLES:
/// ```zig
/// const tasks = sys.LockCoreTasks(0) orelse return;
/// const first = tasks.ready.first();
/// sys.UnlockCoreTasks(0);
/// ```
pub fn UnlockCoreTasks(base: *ExecBase, core: u32) void {
    if (core >= base.cores_running) return;
    _task.unlockTaskLists(base);
}

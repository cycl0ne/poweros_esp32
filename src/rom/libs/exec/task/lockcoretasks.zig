// SPDX-License-Identifier: MPL-2.0
//! LockCoreTasks: one core's ready and waiting tasks, with that core's
//! lock taken.

const sdk = @import("sdk");
const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Core `core`'s tasks, with that core's lock taken.
///
/// SYNOPSIS:
/// ```zig
/// fn LockCoreTasks(base: *ExecBase, core: u32) ?*CoreTasks
/// ```
///
/// SINCE: 1.31. LVO -584.
///
/// INPUTS:
/// - `core` - the core, counted from 0.
///
/// RESULT:
/// That core's `CoreTasks` - its `ready` list, by priority, and its
/// `wait` list - with the core's lock held, or null past the last core
/// the machine runs, and then nothing is held.
///
/// BEHAVIOR:
/// Each core has its own ready and waiting tasks: a task is on the lists
/// of the core that owns it, and a core with nothing ready takes work
/// from another's. So there is no one list of the machine's tasks, and a
/// program that wants them all walks the cores from 0 until this answers
/// null, locking and unlocking each in turn.
///
/// The lock is a spinlock, held with the caller's interrupts masked: what
/// is done under it must be short and must not wait. Only one core's
/// lists are held at a time - the next core's are taken after this one's
/// are given back.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Locks: takes the core's task lists; no waiting and no allocation
///   while they are held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The lists and their nodes are exec's. No node may be read after
/// `UnlockCoreTasks`: a task may end as soon as the lock is let go.
///
/// NOTES:
/// `ThisTask` is on neither list while it runs: a core's running task is
/// read with `CoreTask`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnlockCoreTasks`, `CoreTask`, `LockExecList`
///
/// EXAMPLES:
/// ```zig
/// var core: u32 = 0;
/// while (sys.LockCoreTasks(core)) |tasks| : (core += 1) {
///     defer sys.UnlockCoreTasks(core);
///     var it = tasks.ready.iterator();
///     while (it.next()) |node| count += 1;
/// }
/// ```
pub fn LockCoreTasks(base: *ExecBase, core: u32) ?*sdk.exec.CoreTasks {
    if (core >= base.cores_running) return null;
    _task.lockTasksOf(base, core);
    return &base.cpus_at[core].tasks;
}

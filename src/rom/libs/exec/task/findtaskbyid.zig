// SPDX-License-Identifier: MPL-2.0
//! FindTaskById: a task found by its number, the one `Task.id` holds and
//! the listings of tasks and memory show. The work is `_task.findById`.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const _task = @import("_task.zig");
const Task = sdk.exec.Task;

/// Finds a task by its number.
///
/// SYNOPSIS:
/// ```zig
/// fn FindTaskById(base: *ExecBase, id: u32) ?*Task
/// ```
///
/// SINCE: 1.46. LVO -620.
///
/// INPUTS:
/// - `id` - a task's number (`Task.id`), as `C:dbg/Tasks`, `s3> tasks`
///   and the memory listings show it.
///
/// RESULT:
/// The task, running, ready or waiting, on whichever core; null when no
/// task has that number.
///
/// BEHAVIOR:
/// The tasks running on the cores are looked at first, then each core's
/// ready and waiting tasks under that core's lists. A number is given to
/// one task only and never again, so a task found is the one meant, not
/// a later one that took its place.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: never.
/// - Locks: takes each core's lists in turn; the caller holds none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The task is its own: it may end as soon as the call returns, as one
/// FindTask answers may.
///
/// NOTES:
/// The cores' lists are taken one after another, not at once: a task
/// that moves to another core just then may be missed, and is found when
/// asked again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindTask`, `GetTaskSpot`, `KillTask`
///
/// EXAMPLES:
/// ```zig
/// if (sys.FindTaskById(12)) |task| {
///     // task.name()
/// }
/// ```
pub fn FindTaskById(base: *ExecBase, id: u32) ?*Task {
    return _task.findById(base, id);
}

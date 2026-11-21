// SPDX-License-Identifier: MPL-2.0
//! KillTask: a task made to end from outside it, as Kill on the Software
//! Failure requester and `s3> kill` end one. The work is
//! `_task.killTask`.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const _task = @import("_task.zig");
const Task = sdk.exec.Task;

/// Ends a task from outside it, whatever it is doing.
///
/// SYNOPSIS:
/// ```zig
/// fn KillTask(base: *ExecBase, task: *Task) bool
/// ```
///
/// SINCE: 1.46. LVO -616.
///
/// INPUTS:
/// - `task` - the task to end; not the caller, and not one of exec's own.
///
/// RESULT:
/// True when the task goes; false for the caller itself, one of exec's own
/// tasks (the system's number, `MEMOWNER_SYSTEM`), and one that has ended.
///
/// BEHAVIOR:
/// The task is taken from wherever it is - waiting, ready, held by the
/// Software Failure requester, or running on another core, which stops it
/// first - and started again at its end on its own stack: what it was
/// doing is dropped, its frames with it. It leaves the semaphore queue it
/// waited in and lets go of the semaphores it holds, its end hooks run,
/// its private memory is freed, and its Task and name stay where they
/// are, since a port or a request may still name it. A task killed
/// before whose end failed again is removed as it is.
///
/// CONTEXT:
/// - Waits: yes, for a task running on another core to leave it.
/// - Interrupts: never.
/// - Locks: takes the task's core's lists; the caller holds none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// What the task allocated and did not free stays allocated, marked with
/// its number: `s3> memowners` shows it as an ended task's.
///
/// NOTES:
/// Nothing the task meant to do on its way out happens: a file it had
/// open stays open, a request it had sent may still come back to its
/// port. It is the way out of a task that is stuck, not a way to stop
/// one that can be asked (Ctrl-C, `Signal`).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetTaskSpot`, `RemTask`, `Signal`
///
/// EXAMPLES:
/// ```zig
/// if (!sys.KillTask(task)) {
///     // the caller, exec's own, or ended already
/// }
/// ```
pub fn KillTask(base: *ExecBase, task: *Task) bool {
    return _task.killTask(base, task);
}

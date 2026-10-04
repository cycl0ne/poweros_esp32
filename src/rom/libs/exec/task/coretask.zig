// SPDX-License-Identifier: MPL-2.0
//! CoreTask: the task a core is running now - what `FindTask(null)` says
//! of the caller's own core, asked of any core.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;

/// The task core `core` is running now.
///
/// SYNOPSIS:
/// ```zig
/// fn CoreTask(base: *ExecBase, core: u32) ?*Task
/// ```
///
/// SINCE: 1.4. LVO -520.
///
/// INPUTS:
/// - `core` - the core: 0 is the one the system starts on.
///
/// RESULT:
/// The task running there - its idle task when it has nothing else - or
/// null for a core that is not running, which is every core from the
/// first null on.
///
/// BEHAVIOR:
/// A running task is on neither of exec's queues (`EXECLIST_TASK_READY`,
/// `EXECLIST_TASK_WAIT`): it is each core's own. This is how a listing of
/// every task finds the ones running - asking from core 0 up until the
/// answer is null - and the caller's own core answers what `FindTask(null)`
/// does.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Locks: Disable, not a lock: the other core switches on its own, so the
///   answer holds only inside `Disable`: ask there, and copy what is wanted of
///   the task before the `Enable` - the task may end once it is let go.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The task is its own; nothing is handed over.
///
/// NOTES:
/// A task's `TF_CORE0` and `TF_CORE1` flags say which cores it may run
/// on (`SetTaskAffinity`); this says where it runs.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindTask`, `SetTaskAffinity`, `LockExecList`, `Disable`
///
/// EXAMPLES:
/// ```zig
/// var core: u32 = 0;
/// while (true) : (core += 1) {
///     sys.Disable();
///     const pri = if (sys.CoreTask(core)) |task| task.node.pri else null;
///     sys.Enable();
///     const running = pri orelse break;
///     // ... print core and running ...
/// }
/// ```
pub fn CoreTask(base: *ExecBase, core: u32) ?*Task {
    if (core >= base.cores_running) return null;
    return base.cpus[core].this_task;
}

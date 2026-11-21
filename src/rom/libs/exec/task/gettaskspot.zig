// SPDX-License-Identifier: MPL-2.0
//! GetTaskSpot: where a task stands - the instruction it runs at or goes
//! on from, and the calls it came through - asked from another task,
//! without stopping it. The work is `_task.spotOf`; the reading of a
//! context is each CPU's own (`TaskHardware.spot`).

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const _task = @import("_task.zig");
const Task = sdk.exec.Task;
const TaskSpot = sdk.exec.TaskSpot;

/// Where a task stands: its instruction, its stack pointer and the calls
/// it came through.
///
/// SYNOPSIS:
/// ```zig
/// fn GetTaskSpot(base: *ExecBase, task: *Task, spot: *TaskSpot) bool
/// ```
///
/// SINCE: 1.46. LVO -612.
///
/// INPUTS:
/// - `task` - the task to look at; not the caller. It may have ended
///   since the caller found it.
/// - `spot` - filled in: `pc`, `sp`, `link`, the return addresses in
///   `calls` and how many in `depth`, the ROM's ones in `in_rom`, and the
///   core it ran on in `core`.
///
/// RESULT:
/// True with `spot` filled in; false, `spot` empty, for the caller itself
/// and for a task that has ended or is being taken away. True with only
/// `core` set and `pc` 0 for a task running on a core that holds its
/// interrupts off: it is not read.
///
/// BEHAVIOR:
/// A task that is not running - waiting, ready, held by a failure - is
/// read from the context its last switch saved: `pc` is where it goes on
/// once it runs again, which for a task that waits is inside `Wait`, and
/// `calls` say who waits. A task running on another core is read there,
/// at that core's next exception exit, as the exception saved it, and
/// runs on as if nothing had asked; `core` names that core. The caller
/// spins for that answer, an interrupt of that core away, and looks again
/// when the task left that core first. A core that does not answer within
/// 100 ms holds its interrupts off - the task runs inside Disable, or
/// spins for a lock with its interrupts masked - and the request is taken
/// back: the spot names the core, and nothing of the task.
///
/// The task is looked for on the lists of the core it names before
/// anything of it is read, so one that has ended since the caller found
/// it - its memory given back, perhaps another's - answers false.
///
/// The calls are found up the task's frame pointers, from the frame `pc`
/// is in, and none is read outside the task's stack; `link` is the
/// return address the CPU keeps in a register, which a function that has
/// made no frame of its own returns to. The ROM's addresses are marked in
/// `in_rom` - bit 0 `pc`, bit 1 `link`, bit 2 + i `calls[i]` - and any
/// other is in a file loaded from disk: dos's `FindLoadedCode` names it.
///
/// CONTEXT:
/// - Waits: no; it spins for a running task until its core has read it,
///   100 ms at most.
/// - Interrupts: never.
/// - Locks: takes the task's core's lists for the moment of the reading;
///   the caller holds none (`LockCoreTasks` included).
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `spot` is the caller's; the addresses in it are the task's code, named
/// for as long as that code stays loaded.
///
/// NOTES:
/// What it answers is a moment: the task may be elsewhere by the time the
/// caller reads it. Asked several times, a task that loops shows the same
/// few places, and one that waits the same one each time.
///
/// BUGS:
/// On the ESP32-S3 a task's frames are in its register windows until it
/// switches, so `calls` stays empty there: `pc` and `link` are all it
/// gets. Code built without frame pointers ends the chain early.
///
/// SEE ALSO:
/// `KillTask`, `CoreTask`, `LockCoreTasks`, dos's `FindLoadedCode`
///
/// EXAMPLES:
/// ```zig
/// var spot = exec.TaskSpot{};
/// if (sys.GetTaskSpot(task, &spot)) {
///     // spot.pc, then spot.calls[0..spot.depth], innermost first
/// }
/// ```
pub fn GetTaskSpot(base: *ExecBase, task: *Task, spot: *TaskSpot) bool {
    return _task.spotOf(base, task, spot);
}

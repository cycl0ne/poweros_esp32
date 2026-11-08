// SPDX-License-Identifier: MPL-2.0
//! Disable: masks interrupts, nesting. Only the outermost Disable saves
//! the state the matching `Enable` puts back, and takes the system's
//! interrupt lock, which keeps every other core's interrupts and
//! Disables out as well.

const _interrupt = @import("_interrupt.zig");
const _task = @import("../task/_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Masks every interrupt until the matching `Enable`.
///
/// SYNOPSIS:
/// ```zig
/// fn Disable(base: *ExecBase) void
/// ```
///
/// SINCE: 1.0. LVO -140.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It nests, and the state from before the **outermost** Disable is what
/// the outermost Enable puts back - so a Disable/Enable pair inside an
/// interrupt leaves interrupts masked, which is what they already were.
///
/// It guards what interrupts themselves touch: the interrupt vectors, the
/// server chains and the software interrupt queues. What only tasks touch
/// has locks of its own - exec's lists each theirs - and Disable is
/// heavier than any of them because it stops the machine responding to
/// its hardware.
///
/// **The task lists are not among them.** Each core's ready and wait
/// lists, the state and signals of the tasks on them, and its running
/// task are under that core's own lock, which `LockCoreTasks` takes and
/// the calls that move a task take for themselves: a `Signal` waits for
/// no interrupt handler, and a core choosing what to run next waits for
/// no Disable.
///
/// **Every core.** The outermost Disable takes the system's interrupt
/// lock, which the dispatch of an interrupt number and of the software
/// interrupts takes as well. So while a task is inside Disable no
/// interrupt runs on any core and no task on another core gets into
/// Disable: a core that wants the lock waits for it with its own
/// interrupts masked.
///
/// CONTEXT:
/// - Waits: no. Never `Wait` while holding it: what it guards is not
///   guarded across the wait.
/// - Interrupts: safe, and the nesting is what makes it so.
/// - Locks: none. Disable and a spinlock are separate: neither implies the
///   other. Task switching is not stopped by Disable itself, except that a
///   switch cannot be delivered while interrupts are masked.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The caller owes an `Enable`.
///
/// NOTES:
/// Hold it for as short a span as will do. Every interrupt the machine has
/// is late by however long it is held - on both cores - and on this board
/// that includes the panel's refill, which has 460 microseconds to do 230
/// microseconds of work before the picture tears.
///
/// The count starts at -1, so one Disable brings it to 0, which is the
/// point at which the state to be put back is saved.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Enable`, `AcquireLock`, `Cause`
///
/// EXAMPLES:
/// ```zig
/// sys.Disable();
/// defer sys.Enable();
/// ```
pub fn Disable(base: *ExecBase) void {
    const state = _interrupt.mask();
    // Masked, the caller stays on this core.
    const cpu = base.cpu();
    cpu.id_nest_cnt += 1;
    if (cpu.id_nest_cnt != 0) return;
    cpu.id_saved = state;
    // Inside the dispatcher the core holds the task lists, which come
    // after this lock: taking it there would be the lock order the wrong
    // way round. Its interrupts are masked all the same.
    if (_task.taskListsHeld(base)) return;
    _interrupt.takeSystemInterrupts(base, @returnAddress());
}

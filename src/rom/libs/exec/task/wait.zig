// SPDX-License-Identifier: MPL-2.0
//! Wait: sleeps until one of a set of signals arrives, and answers and
//! clears the ones that did. A task's exception code runs while it waits.
//!
//! A task holding a spinlock may not wait: that is a dead end, since the
//! core's count of locks held is the core's and not the task's.

const _task = @import("_task.zig");
const _interrupt = @import("../interrupt/_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const _locks = @import("../locks/_locks.zig");

/// Sleeps until one of a set of signals arrives.
///
/// SYNOPSIS:
/// ```zig
/// fn Wait(base: *ExecBase, signal_set: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -180.
///
/// INPUTS:
/// - `signal_set` - the bits to wait for. Any one of them wakes the task.
///   A set of 0 waits for ever.
///
/// RESULT:
/// Which of `signal_set` arrived - possibly more than one - and those bits
/// are **cleared** as they are answered. Bits outside the set are left
/// alone for a later Wait.
///
/// BEHAVIOR:
/// It returns at once if one of the bits is already set, so a task that
/// checks its port before waiting never sleeps through a message that
/// arrived while it was working.
///
/// The task's exception code runs here when an exception signal has
/// arrived, before the wait is considered.
///
/// CONTEXT:
/// - Waits: **yes - this is the call that does.** Everything that waits in
///   this system waits here in the end.
/// - Interrupts: no, and it is fatal to try. An interrupt has no task to
///   suspend, so there would be nothing to wake.
/// - Locks: no spinlock may be held: Wait with one held is a dead end, since
///   the core's count of locks held is the core's and not the task's.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// Wait for everything that can wake you in one call, not in several one
/// after another: a task waiting on its port alone will not hear Ctrl-C,
/// and one waiting on Ctrl-C alone will not hear its port. `SIGBREAKF_CTRL_C`
/// belongs in nearly every set.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Signal`, `SetSignal`, `WaitPort`, `WaitIO`
///
/// EXAMPLES:
/// ```zig
/// const got = sys.Wait(port_mask | exec.SIGBREAKF_CTRL_C);
/// if (got & exec.SIGBREAKF_CTRL_C != 0) return;
/// while (sys.GetMsg(port)) |msg| { ... }
/// ```
pub fn Wait(base: *ExecBase, signal_set: u32) u32 {
    _locks.checkWait(base, @returnAddress());
    const sys = base.iface();
    const task = sys.FindTask(null).?;
    // The interrupts as the caller had them, in this task's own word: the
    // task lists are held across the switch below, and a task that comes
    // back on another core would find that core's saved state, not its
    // own.
    const state = _interrupt.mask();
    _task.takeTaskLists(base, @returnAddress());
    while (true) {
        _task.runExceptions(base, task, state);
        if (task.sig_recvd & signal_set != 0) break;
        _task.blockCurrent(base, task, signal_set);
        // Held across the switch, as every other core's dispatcher and
        // Signal take it: until the task's context is saved it is this
        // core's, however its state reads. The exit lets the lock go once
        // the core runs another task, so it is taken again here.
        _task.task_hardware.switch_now(); // back here once signalled
        _task.takeTaskLists(base, @returnAddress());
    }
    const got = task.sig_recvd & signal_set;
    task.sig_recvd &= ~got;
    task.sig_wait = 0;
    _task.dropTaskLists(base);
    const due = _task.switchDue(base);
    _interrupt.unmask(state);
    if (due) _task.task_hardware.switch_now();
    return got;
}

// SPDX-License-Identifier: MPL-2.0
//! SetExcept: chooses which signals run the running task's exception code.
//! One already received runs it at once.

const _task = @import("_task.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Chooses which of the calling task's signals raise its exception code.
///
/// SYNOPSIS:
/// ```zig
/// fn SetExcept(base: *ExecBase, new_signals: u32, signal_set: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -200.
///
/// INPUTS:
/// - `new_signals` - the values to write, for the bits in `signal_set`.
/// - `signal_set` - which bits to change.
///
/// RESULT:
/// The exception set as it was before the change.
///
/// BEHAVIOR:
/// A signal in the exception set runs the task's exception code rather than
/// waking it in the ordinary way - so it interrupts the task wherever it
/// is, instead of waiting for it to come round to a `Wait`.
///
/// The task's exception code must already be set when this is called: if
/// one of the chosen signals is **already** present, the exception runs
/// straight away.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no - it is the running task's.
/// - Forbid: not needed; it takes Disable. Under Forbid the exception is
///   postponed to the `Permit`.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// The exception code runs on the task's own stack, in the middle of
/// whatever it was doing, so it is under an interrupt's constraints rather
/// than a task's: it must not wait, and what it touches must be safe to
/// touch at any point in the task's own code.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Signal`, `Wait`, `SetTrapCode`
///
/// EXAMPLES:
/// ```zig
/// const old = sys.SetExcept(exec.SIGBREAKF_CTRL_C, exec.SIGBREAKF_CTRL_C);
/// ```
pub fn SetExcept(base: *ExecBase, new_signals: u32, signal_set: u32) u32 {
    const sys = base.iface();
    sys.Disable();
    const task = sys.FindTask(null).?;
    const old = task.sig_except;
    task.sig_except = (old & ~signal_set) | (new_signals & signal_set);
    if (_task.exceptionPending(task)) base.sys_flags |= _task.SFF_SAR;
    sys.Enable(); // raises it now if pending
    return old;
}

// SPDX-License-Identifier: MPL-2.0
//! SetSignal: reads the running task's received signals and changes some
//! of them, in one step.

const ExecBase = @import("../exec.zig").ExecBase;

/// Reads or changes the calling task's signals without waiting.
///
/// SYNOPSIS:
/// ```zig
/// fn SetSignal(base: *ExecBase, new_signals: u32, signal_mask: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -184.
///
/// INPUTS:
/// - `new_signals` - the values to write, for the bits in `signal_mask`.
/// - `signal_mask` - which bits to change. 0 changes nothing.
///
/// RESULT:
/// The whole received set as it was **before** the change.
///
/// BEHAVIOR:
/// `SetSignal(0, 0)` changes nothing and answers the current signals, which
/// is how a program checks for Ctrl-C without waiting and without taking
/// the signal away from anyone.
///
/// `SetSignal(0, mask)` clears those bits and says what they were, which is
/// how one is consumed.
///
/// CONTEXT:
/// - Waits: no. It is the call for when waiting is what you do not want.
/// - Interrupts: no - it reads the running task, and an interrupt has none
///   of its own.
/// - Forbid: not needed; it takes Disable.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Wait`, `Signal`
///
/// EXAMPLES:
/// ```zig
/// if (sys.SetSignal(0, 0) & exec.SIGBREAKF_CTRL_C != 0) {
///     // asked to stop; the signal is still set for whoever else looks
/// }
/// ```
pub fn SetSignal(base: *ExecBase, new_signals: u32, signal_mask: u32) u32 {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    const task = sys.FindTask(null).?;
    const old = task.sig_recvd;
    task.sig_recvd = (old & ~signal_mask) | (new_signals & signal_mask);
    return old;
}

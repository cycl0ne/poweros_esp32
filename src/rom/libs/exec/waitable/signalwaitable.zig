// SPDX-License-Identifier: MPL-2.0
//! SignalWaitable: signals a waitable, and wakes every task waiting on it.

const sdk = @import("sdk");
const _waitable = @import("_waitable.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Waitable = sdk.exec.Waitable;

/// Signals a waitable: it stays signalled until it is reset, and every
/// task waiting on it in WaitForAny is woken.
///
/// SYNOPSIS:
/// ```zig
/// fn SignalWaitable(base: *ExecBase, waitable: *Waitable) void
/// ```
///
/// SINCE: 1.14. LVO -564.
///
/// INPUTS:
/// - `waitable` - the waitable.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A waitable signalled while nobody waits stays signalled, so a task
/// that comes to wait for it later returns at once: there is no moment
/// between looking and waiting in which the signal could be lost.
/// Signalling one that is signalled already changes nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes. This is how a driver's interrupt says that what a
///   task waits for has happened.
/// - Locks: takes Disable.
/// - Process: a Task or an interrupt.
///
/// OWNERSHIP:
/// Nothing is allocated. The waitable stays its owner's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ResetWaitable`, `WaitForAny`, `Signal`
///
/// EXAMPLES:
/// ```zig
/// // In the interrupt that ends a job:
/// sys.SignalWaitable(&job.done);
/// ```
pub fn SignalWaitable(base: *ExecBase, waitable: *Waitable) void {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    @atomicStore(u32, &waitable.signalled, 1, .release);
    _waitable.wake(base, waitable);
}

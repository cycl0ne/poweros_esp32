// SPDX-License-Identifier: MPL-2.0
//! ResetWaitable: makes a waitable unsignalled again.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Waitable = sdk.exec.Waitable;

/// Makes a waitable unsignalled again, for the next time it is waited on.
///
/// SYNOPSIS:
/// ```zig
/// fn ResetWaitable(base: *ExecBase, waitable: *Waitable) void
/// ```
///
/// SINCE: 1.14. LVO -568.
///
/// INPUTS:
/// - `waitable` - the waitable.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Only the state changes: a task waiting on it goes on waiting. A
/// waitable is reset before the thing it stands for is started - the job
/// handed out, the frame asked for - so that a signal from it cannot come
/// before the reset and be lost.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Locks: none.
/// - Process: a Task or an interrupt.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SignalWaitable`, `WaitForAny`
///
/// EXAMPLES:
/// ```zig
/// sys.ResetWaitable(&job.done);
/// startJob(&job);
/// _ = sys.WaitForAny(&.{&job.done}, 1, exec.WAIT_FOREVER);
/// ```
pub fn ResetWaitable(base: *ExecBase, waitable: *Waitable) void {
    _ = base;
    @atomicStore(u32, &waitable.signalled, 0, .release);
}

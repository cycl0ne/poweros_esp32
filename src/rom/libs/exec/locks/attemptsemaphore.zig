// SPDX-License-Identifier: MPL-2.0
//! AttemptSemaphore: holds a semaphore exclusively if that can be done
//! without waiting, and otherwise leaves it alone - nothing is queued.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const SemaphoreRequest = sdk.exec.SemaphoreRequest;
const SignalSemaphore = sdk.exec.SignalSemaphore;

/// Takes a semaphore exclusively if that can be done without waiting.
///
/// SYNOPSIS:
/// ```zig
/// fn AttemptSemaphore(base: *ExecBase, sem: *SignalSemaphore) bool
/// ```
///
/// SINCE: 1.0. LVO -252.
///
/// INPUTS:
/// - `sem` - an initialised semaphore.
///
/// RESULT:
/// True if it is now the caller's - and then it must be released - or false
/// if someone else holds it, in which case nothing was taken.
///
/// BEHAVIOR:
/// It succeeds if the semaphore is free or this task already holds it, so
/// it nests like `ObtainSemaphore`.
///
/// CONTEXT:
/// - Waits: **no, and that is the point of it.** This is how a lock is
///   taken from somewhere that must not block - an interrupt's task, or
///   code holding another lock.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, and not broken, since nothing waits.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// On true, the caller holds it until `ReleaseSemaphore`. On false it owes
/// nothing.
///
/// NOTES:
/// Releasing after a false is the mistake this call invites, and it raises
/// `AN_SemCorrupt` rather than passing quietly.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainSemaphore`, `AttemptSemaphoreShared`, `ReleaseSemaphore`
///
/// EXAMPLES:
/// ```zig
/// if (!sys.AttemptSemaphore(&self.lock)) return false;
/// defer sys.ReleaseSemaphore(&self.lock);
/// ```
pub fn AttemptSemaphore(base: *ExecBase, sem: *SignalSemaphore) bool {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    const task = sys.FindTask(null).?;
    if (sem.queue_count >= 0 and sem.owner != task) return false;
    var request: SemaphoreRequest = .{ .waiter = task };
    return _locks.enter(base, sem, &request);
}

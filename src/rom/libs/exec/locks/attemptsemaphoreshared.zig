// SPDX-License-Identifier: MPL-2.0
//! AttemptSemaphoreShared: holds a semaphore shared if that can be done
//! without waiting, and otherwise leaves it alone - nothing is queued.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const SemaphoreRequest = sdk.exec.SemaphoreRequest;
const SignalSemaphore = sdk.exec.SignalSemaphore;

/// Takes a semaphore shared if that can be done without waiting.
///
/// SYNOPSIS:
/// ```zig
/// fn AttemptSemaphoreShared(base: *ExecBase, sem: *SignalSemaphore) bool
/// ```
///
/// SINCE: 1.0. LVO -280.
///
/// INPUTS:
/// - `sem` - an initialised semaphore.
///
/// RESULT:
/// True if it is now the caller's to read, false if someone holds it
/// exclusively.
///
/// BEHAVIOR:
/// It succeeds if the semaphore is free, held shared, or held by this task.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, and not broken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// On true, until `ReleaseSemaphore`. On false, nothing.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainSemaphoreShared`, `AttemptSemaphore`
///
/// EXAMPLES:
/// ```zig
/// if (!sys.AttemptSemaphoreShared(&self.lock)) return null;
/// defer sys.ReleaseSemaphore(&self.lock);
/// ```
pub fn AttemptSemaphoreShared(base: *ExecBase, sem: *SignalSemaphore) bool {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    const task = sys.FindTask(null).?;
    if (sem.queue_count >= 0 and sem.owner != task and sem.owner != null) return false;
    var request: SemaphoreRequest = .{ .waiter = task, .shared = true };
    return _locks.enter(base, sem, &request);
}

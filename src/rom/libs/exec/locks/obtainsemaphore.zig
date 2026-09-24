// SPDX-License-Identifier: MPL-2.0
//! ObtainSemaphore: holds a semaphore exclusively, and waits in the queue
//! until it is granted when it cannot be had at once. A holder may obtain
//! it again; each obtain is matched by a `ReleaseSemaphore`.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const SignalSemaphore = sdk.exec.SignalSemaphore;

/// Takes a semaphore exclusively, waiting until it is free.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainSemaphore(base: *ExecBase, sem: *SignalSemaphore) void
/// ```
///
/// SINCE: 1.0. LVO -244.
///
/// INPUTS:
/// - `sem` - an initialised semaphore.
///
/// RESULT:
/// Nothing. It returns when the semaphore is the caller's.
///
/// BEHAVIOR:
/// The owner may obtain it again and again; **every obtain needs its
/// release**, which is what makes it safe for one of a module's functions
/// to call another that also takes the lock.
///
/// A waiter is queued in order and handed the semaphore directly when it
/// comes free, so it cannot be overtaken.
///
/// CONTEXT:
/// - Waits: yes, whenever another task holds it.
/// - Interrupts: no. It waits.
/// - Forbid: it takes Forbid, and the `Wait` inside breaks it while
///   waiting - so a caller must **not** hold Forbid across this expecting
///   it to be held throughout.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller holds it until `ReleaseSemaphore`. An error path that returns
/// without releasing locks the semaphore for good, which is why every use
/// in this tree is `defer`red.
///
/// NOTES:
/// A task already holding it shared must not then ask for it exclusively:
/// that waits for a release that only it can do. Two locks must be taken in
/// the same order by everyone, for the same reason.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseSemaphore`, `AttemptSemaphore`,
/// `ObtainSemaphoreShared`, `Procure`
///
/// EXAMPLES:
/// ```zig
/// sys.ObtainSemaphore(&self.lock);
/// defer sys.ReleaseSemaphore(&self.lock);
/// ```
pub fn ObtainSemaphore(base: *ExecBase, sem: *SignalSemaphore) void {
    _locks.obtain(base, sem, false);
}

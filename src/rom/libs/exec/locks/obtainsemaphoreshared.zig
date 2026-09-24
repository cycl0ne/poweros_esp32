// SPDX-License-Identifier: MPL-2.0
//! ObtainSemaphoreShared: holds a semaphore shared, beside other shared
//! holders, and waits in the queue until it is granted when it cannot be
//! had at once. A holder may obtain it again; each obtain is matched by a
//! `ReleaseSemaphore`.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const SignalSemaphore = sdk.exec.SignalSemaphore;

/// Takes a semaphore shared, alongside other shared holders.
///
/// SYNOPSIS:
/// ```zig
/// fn ObtainSemaphoreShared(base: *ExecBase, sem: *SignalSemaphore) void
/// ```
///
/// SINCE: 1.0. LVO -276.
///
/// INPUTS:
/// - `sem` - an initialised semaphore.
///
/// RESULT:
/// Nothing. It returns when the semaphore is the caller's to read.
///
/// BEHAVIOR:
/// Several tasks may hold it shared at once, and none may hold it
/// exclusively while they do - which is what makes it the lock for
/// something read often and written rarely.
///
/// **A shared request is granted while the semaphore is held shared, even
/// with exclusive waiters queued ahead of it.** So a steady stream of
/// readers can keep a writer waiting indefinitely, and that is a property
/// of the lock rather than a bug in it.
///
/// The exclusive owner asking for it shared simply nests.
///
/// CONTEXT:
/// - Waits: yes, whenever someone holds it exclusively.
/// - Interrupts: no. It waits.
/// - Forbid: taken here and broken by the waiting.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller holds it until `ReleaseSemaphore` - the same release for
/// both kinds.
///
/// NOTES:
/// A shared holder must not then ask for it exclusively. That waits for
/// every shared holder to let go, itself included, so it never returns.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ObtainSemaphore`, `AttemptSemaphoreShared`, `ReleaseSemaphore`
///
/// EXAMPLES:
/// ```zig
/// sys.ObtainSemaphoreShared(&self.lock);
/// defer sys.ReleaseSemaphore(&self.lock);
/// ```
pub fn ObtainSemaphoreShared(base: *ExecBase, sem: *SignalSemaphore) void {
    _locks.obtain(base, sem, true);
}

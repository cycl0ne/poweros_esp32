// SPDX-License-Identifier: MPL-2.0
//! RemSemaphore: takes a public semaphore off exec's semaphore list, so
//! `FindSemaphore` no longer finds it.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const SignalSemaphore = sdk.exec.SignalSemaphore;

/// Takes a semaphore off the public list.
///
/// SYNOPSIS:
/// ```zig
/// fn RemSemaphore(base: *ExecBase, sem: *SignalSemaphore) void
/// ```
///
/// SINCE: 1.0. LVO -272.
///
/// INPUTS:
/// - `sem` - a semaphore that was added with `AddSemaphore`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Nothing new can find it. Whoever already holds it still does, and
/// whoever is queued is still queued - so this is not a way to take a lock
/// away from its holder.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. Making sure nobody holds or wants it before
/// freeing it is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddSemaphore`, `FindSemaphore`
///
/// EXAMPLES:
/// ```zig
/// sys.RemSemaphore(&sem);
/// ```
pub fn RemSemaphore(base: *ExecBase, sem: *SignalSemaphore) void {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    sys.Remove(&sem.link);
}

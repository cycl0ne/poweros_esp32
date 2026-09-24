// SPDX-License-Identifier: MPL-2.0
//! Vacate: withdraws a bid. A granted bid gives the semaphore up; one
//! still queued is taken off the queue and replied.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const SemaphoreMessage = sdk.exec.SemaphoreMessage;
const SignalSemaphore = sdk.exec.SignalSemaphore;

/// Withdraws a bid, or gives back the semaphore it won.
///
/// SYNOPSIS:
/// ```zig
/// fn Vacate(base: *ExecBase, sem: *SignalSemaphore,
///     bid: *SemaphoreMessage) void
/// ```
///
/// SINCE: 1.0. LVO -288.
///
/// INPUTS:
/// - `sem` - the semaphore the bid was made on.
/// - `bid` - the bid.
///
/// RESULT:
/// Nothing. The bid's semaphore field is cleared either way.
///
/// BEHAVIOR:
/// **One call for both cases**, which is what lets a caller give up without
/// having to know whether the bid was granted while it was deciding - the
/// race that would otherwise have no safe answer.
///
/// Still waiting: it is taken off the queue and replied with no semaphore,
/// so the waiter hears that it lost rather than waiting for ever.
///
/// Already granted: the semaphore is released. The bid was replied when it
/// was granted and is not replied again.
///
/// A bid never made, or vacated twice, does nothing.
///
/// CONTEXT:
/// - Waits: no, but releasing may signal and so may switch.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here.
/// - Process: a Task will do. **Any task may vacate a bid**, though the
///   lock belongs to whoever procured it.
///
/// OWNERSHIP:
/// The bid is the caller's again and may be freed.
///
/// NOTES:
/// A bid that was never procured, or vacated a second time, changes
/// nothing - which is what the waiter field is read for before anything
/// else is touched.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Procure`, `ReleaseSemaphore`
///
/// EXAMPLES:
/// ```zig
/// sys.Vacate(&sem, &bid);
/// ```
pub fn Vacate(base: *ExecBase, sem: *SignalSemaphore, bid: *SemaphoreMessage) void {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    bid.semaphore = null;
    const task = bid.request.waiter orelse return; // nothing to give back
    const granted = bid.request.granted;
    if (!granted) {
        sys.Remove(&bid.request.link);
        sem.queue_count -= 1;
    }
    bid.request = .{};
    if (granted) _locks.leave(base, sem, task) else sys.ReplyMsg(&bid.msg);
}

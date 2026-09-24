// SPDX-License-Identifier: MPL-2.0
//! Procure: bids for a semaphore with a message instead of waiting. The
//! bid is replied when the semaphore is granted, so a lock can be waited
//! for beside a port and a timer in one Wait.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;
const SemaphoreMessage = sdk.exec.SemaphoreMessage;
const SignalSemaphore = sdk.exec.SignalSemaphore;

/// Bids for a semaphore with a message, instead of waiting for it.
///
/// SYNOPSIS:
/// ```zig
/// fn Procure(base: *ExecBase, sem: *SignalSemaphore,
///     bid: *SemaphoreMessage) void
/// ```
///
/// SINCE: 1.0. LVO -284.
///
/// INPUTS:
/// - `sem` - an initialised semaphore.
/// - `bid` - a `SemaphoreMessage` with a reply port. Its name says whether
///   the bid is shared.
///
/// RESULT:
/// Nothing is answered here. **The bid comes back to its reply port** when
/// the semaphore is granted - at once if it is free - with its semaphore
/// field set to say which one was won.
///
/// BEHAVIOR:
/// This is how a task waits for a lock *and* for other things at the same
/// time: the bid arrives as a message, so it can be waited for beside a
/// port, a timer and Ctrl-C in one `Wait`.
///
/// A bid is granted at once only if the semaphore is free or its holder is
/// what the bid asks for. So, unlike `ObtainSemaphoreShared`, **a shared
/// bid from the exclusive owner waits** until that hold is released.
///
/// The lock belongs to the task that called this, whatever task later
/// receives the reply.
///
/// CONTEXT:
/// - Waits: no. Not waiting is the whole point.
/// - Interrupts: no. It takes Forbid and may reply a message.
/// - Forbid: taken here.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bid is the semaphore's until it is replied, and must not be touched
/// or freed before then. It is given back with `Vacate`, never with
/// `ReleaseSemaphore`.
///
/// NOTES:
/// A bid is granted at once only if the semaphore is free or its holder is
/// what the bid asks for: this task for an exclusive bid, the shared
/// holders for a shared one. That is why a shared bid from the exclusive
/// owner waits where `ObtainSemaphoreShared` would simply nest.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Vacate`, `ObtainSemaphore`, `Wait`
///
/// EXAMPLES:
/// ```zig
/// var bid: exec.SemaphoreMessage = .init(reply_port, false);
/// sys.Procure(&sem, &bid);
/// _ = sys.Wait(port_mask | exec.SIGBREAKF_CTRL_C);
/// ```
pub fn Procure(base: *ExecBase, sem: *SignalSemaphore, bid: *SemaphoreMessage) void {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    const task = sys.FindTask(null).?;
    const shared = bid.isShared();
    const holder: ?*Task = if (shared) null else task;
    bid.semaphore = null;
    bid.request = .{ .waiter = task, .shared = shared, .bid = bid };
    sem.queue_count += 1;
    if (sem.queue_count == 0 or sem.owner == holder) {
        if (sem.queue_count == 0) sem.owner = holder;
        sem.nest_count += 1;
        bid.request.granted = true;
        _locks.reply(base, sem, bid);
        return;
    }
    sys.AddTail(&sem.wait_queue, &bid.request.link);
}

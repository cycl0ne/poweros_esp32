// SPDX-License-Identifier: MPL-2.0
//! Signal semaphores: locks between tasks. They nest, they queue their
//! waiters in order, and they are held either by one task exclusively or
//! by several shared.
//!
//! A released semaphore goes **straight to the next waiter** rather than
//! being let go for whoever asks next, so a queue cannot be jumped and a
//! waiter cannot starve. Waiters sleep on SIGF_SINGLE.
//!
//! A list of them is obtained as a whole (ObtainSemaphoreList), which is
//! the answer to two tasks each ending up with half; public ones are found
//! by name (AddSemaphore, FindSemaphore); and Procure/Vacate bid with a
//! message instead of waiting, so a lock can be waited for beside a port
//! and a timer in one Wait.
//!
//! This is the lock for anywhere Forbid will not do - which is anywhere
//! the holder has to wait, since a task cannot wait under Forbid.
//!
//! The calls are a file each in this folder; this file is what they share:
//! taking a semaphore or queueing for it, giving it up and handing it to
//! the next waiter, and sleeping until that happens.
//!
//! All of it runs with the caller holding Forbid, which is what keeps a
//! semaphore's counts and queue consistent between tasks.

const sdk = @import("sdk");
const Alert = @import("../interrupt/alert.zig").Alert;

const ExecBase = @import("../exec.zig").ExecBase;
const Node = sdk.exec.Node;
const Task = sdk.exec.Task;
const SignalSemaphore = sdk.exec.SignalSemaphore;
const SemaphoreRequest = sdk.exec.SemaphoreRequest;
const SemaphoreMessage = sdk.exec.SemaphoreMessage;

/// The body both obtains share: builds a request on the caller's own
/// stack, tries to take the semaphore, and sleeps until it is granted if
/// not. The request may live on the stack because the caller does not
/// return until it has been granted and taken off the queue.
///
/// INPUTS:
/// - `base` - exec: the jump table the calls go through, `FindTask`
///   included.
/// - `sem` - the semaphore.
/// - `shared` - whether a shared hold is wanted rather than an exclusive
///   one.
pub fn obtain(base: *ExecBase, sem: *SignalSemaphore, shared: bool) void {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    var request: SemaphoreRequest = .{ .waiter = sys.FindTask(null).?, .shared = shared };
    if (!enter(base, sem, &request)) waitGranted(base, &request);
}

/// The semaphore a list node belongs to. Semaphores link through their own
/// node rather than a plain one, so this is the one place the conversion
/// is written.
///
/// INPUTS:
/// - `node` - a semaphore's `link`.
pub fn semaphoreOf(node: *Node) *SignalSemaphore {
    return @fieldParentPtr("link", node);
}

/// The first half of an obtain: takes the semaphore if it can be had now,
/// and queues the request if it cannot. The caller holds Forbid.
///
/// It is granted when the semaphore is free, when this task already holds
/// it, or when the request is shared and the semaphore is held shared -
/// that last case being why a reader never waits behind a queued writer.
///
/// INPUTS:
/// - `base` - exec: the jump table `AddTail` goes through.
/// - `sem` - the semaphore.
/// - `request` - the request: its `waiter` says for whom and its `shared`
///   which kind of hold.
///
/// RESULT:
/// True when it was granted - and then `request.granted` is set too, which
/// is what a sleeper watches.
pub fn enter(base: *ExecBase, sem: *SignalSemaphore, request: *SemaphoreRequest) bool {
    const task = request.waiter.?;
    request.granted = false;
    sem.queue_count += 1;
    if (sem.queue_count == 0) { // free
        sem.owner = if (request.shared) null else task;
        sem.nest_count = 1;
        request.granted = true;
        return true;
    }
    // Held: by this task, or shared and this request is shared too.
    if (sem.owner == task or (request.shared and sem.owner == null)) {
        sem.nest_count += 1;
        request.granted = true;
        return true;
    }
    base.iface().AddTail(&sem.wait_queue, &request.link);
    return false;
}

/// One release, for a named task rather than the running one - which is
/// what `Vacate` needs, since the lock belongs to whoever procured it. The
/// caller holds Forbid.
///
/// Releasing one that is not held, or held by someone else, raises
/// `AN_SemCorrupt`: a count that no longer means anything fails later and
/// somewhere else.
///
/// INPUTS:
/// - `base` - exec, passed on to the grant.
/// - `sem` - the semaphore.
/// - `task` - the holder.
pub fn leave(base: *ExecBase, sem: *SignalSemaphore, task: *Task) void {
    if (sem.nest_count <= 0 or (sem.owner != null and sem.owner != task)) {
        // Direct, not through the table: the path that reports a broken
        // machine must not depend on a vector something has replaced
        // (codex rule 1).
        Alert(base, sdk.exec.AN_SemCorrupt);
        return;
    }
    sem.nest_count -= 1;
    sem.queue_count -= 1;
    if (sem.nest_count > 0) return;
    sem.owner = null;
    grant(base, sem);
}

/// Hands a freed semaphore to its next waiter: an exclusive one alone, or
/// **every** shared one in the queue together. A semaphore is never left
/// free with a waiter queued, which is what stops a queue being jumped.
///
/// INPUTS:
/// - `base` - exec: the jump table `Remove` goes through.
/// - `sem` - the semaphore, which has just become free.
fn grant(base: *ExecBase, sem: *SignalSemaphore) void {
    const head = sem.wait_queue.first() orelse return;
    const first: *SemaphoreRequest = @fieldParentPtr("link", head);
    const sys = base.iface();
    if (!first.shared) {
        sys.Remove(head);
        sem.owner = first.waiter;
        sem.nest_count = 1;
        wake(base, sem, first);
        return;
    }
    var it = sem.wait_queue.iterator();
    while (it.next()) |node| {
        const request: *SemaphoreRequest = @fieldParentPtr("link", node);
        if (!request.shared) continue;
        sys.Remove(node);
        sem.nest_count += 1;
        wake(base, sem, request);
    }
}

/// Tells a waiter it has been granted the semaphore - by replying its bid
/// if it procured one, and otherwise by signalling the task.
///
/// INPUTS:
/// - `base` - exec: the jump table `Signal` goes through.
/// - `sem` - the semaphore.
/// - `request` - the request that won it.
fn wake(base: *ExecBase, sem: *SignalSemaphore, request: *SemaphoreRequest) void {
    request.granted = true;
    if (request.bid) |bid| return reply(base, sem, bid);
    base.iface().Signal(request.waiter.?, sdk.exec.tasks.SIGF_SINGLE);
}

/// Sends a granted bid back to its reply port, with the semaphore it won
/// written into it.
///
/// INPUTS:
/// - `base` - exec: the jump table `ReplyMsg` goes through.
/// - `sem` - the semaphore it won.
/// - `bid` - the message.
pub fn reply(base: *ExecBase, sem: *SignalSemaphore, bid: *SemaphoreMessage) void {
    bid.semaphore = sem;
    base.iface().ReplyMsg(&bid.msg);
}

/// Sleeps until a request is granted.
///
/// The flag is read through a volatile pointer because it is written by
/// another task - the one releasing the semaphore - and nothing in the
/// loop would otherwise make the compiler read it again. The `Wait` breaks
/// the caller's Forbid while it sleeps, which is how a semaphore can be
/// obtained under Forbid at all.
///
/// INPUTS:
/// - `base` - exec: the jump table `Wait` goes through.
/// - `request` - the request to watch.
pub fn waitGranted(base: *ExecBase, request: *SemaphoreRequest) void {
    const granted: *volatile bool = &request.granted;
    while (!granted.*) _ = base.iface().Wait(sdk.exec.tasks.SIGF_SINGLE);
}

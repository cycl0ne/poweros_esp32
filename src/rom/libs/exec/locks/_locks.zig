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
//! This is the lock for a holder that has to wait, since a task cannot
//! wait holding a spinlock.
//!
//! The calls are a file each in this folder; this file is what they share:
//! taking a semaphore or queueing for it, giving it up and handing it to
//! the next waiter, and sleeping until that happens.
//!
//! **A semaphore's state is one word** (`SignalSemaphore.state`): how
//! often it is held, whether exclusively, and whether tasks wait. What
//! can be had at once - a free semaphore, the owner's own again, a shared
//! one joined, a release that hands nothing on - is one compare-and-swap
//! on that word, with the caller's core's interrupts masked for the few
//! instructions it takes, and no lock: two tasks taking two semaphores
//! meet nowhere. It was exec's semaphore lock (`lock_semaphores`) for
//! every obtain and every release, a spinlock all cores took for every
//! semaphore there is - 1714 cycles for a pair with nothing in the way on
//! the VisionFive 2, and twice that with the cores busy.
//!
//! The lock is taken to queue for a semaphore and to hand one on: it
//! keeps the queues, the waiters' requests and the tables below
//! consistent between tasks, and a caller that has to sleep gives it back
//! first. What keeps the two halves apart: `SEMF_WAITERS` is set and
//! cleared only under the lock, with the request queued in the same hold,
//! and every change of the word is a compare-and-swap of all of it. A
//! release that finds the flag goes to the lock and hands the semaphore
//! on; one racing a task that is queueing either frees it first - and the
//! task, looking again, takes it - or finds the flag. So the word is never
//! 0 while a task is queued: the queue's order is the order of the grants,
//! but for a shared request, which joins a semaphore held shared as it
//! always did.
//!
//! **Every task keeps a table of what it holds** (`Task.holds`): a grant
//! counts the hold there, a release takes it out. It is what a task's end
//! gives back (`releaseHolds`) - a holder gone for good would keep
//! everyone queued behind it waiting forever - and what `s3> locks` shows.
//! A table rather than a link through the semaphore, because a semaphore
//! freed while it is held leaves a link pointing into freed memory in a
//! list that is written again; a stale entry is only read, and checked
//! before anything is let go. The table is written by the task itself,
//! with its interrupts masked, and by the task that grants it the
//! semaphore it sleeps for - never by anyone while it runs, which is why
//! it needs no lock, and why Procure's grants, which another task may make
//! or Vacate while the bidder runs, are counted in a table of their own
//! (`Task.bid_holds`), under the lock. A task queued for one
//! (`ObtainSemaphore`) names its request (`Task.waiting`), which is on its
//! stack: a task removed while it waits is taken out of the queue
//! (`withdraw`).
//!
//! **Spinlocks** (InitLock, AcquireLock, AttemptLock, ReleaseLock) share
//! the second half: the word taken atomically - S32C1I in internal memory,
//! under the base's guard word in PSRAM - task switching (or with
//! LOCKF_INTERRUPT the core's interrupts) stopped while one is held, and
//! the rules of sdk/libs/exec/locks.zig checked against the locks the
//! core holds.
//!
//! That list of the core's locks is written by its tasks and by its
//! interrupts alike: a task taking a plain lock runs with interrupts on,
//! and an interrupt's PutMsg takes and gives back the port lock in
//! between. So it is read and written with the core's interrupts masked.
//! Unmasked, an interrupt's entry laid where the task's was about to go
//! left the task's lock off the list: its release found it missing, left
//! it held, and the core's next take of it was a dead end.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const Alert = @import("../interrupt/alert.zig").Alert;
const _interrupt = @import("../interrupt/_interrupt.zig");
const _task = @import("../task/_task.zig");
const exec_base = @import("../exec_base.zig");
const map = sdk.hardware.map;
const lk = sdk.exec.locks;
const Lock = sdk.exec.Lock;

const ExecBase = @import("../exec.zig").ExecBase;
const Node = sdk.exec.Node;
const Task = sdk.exec.Task;
const SignalSemaphore = sdk.exec.SignalSemaphore;
const SemaphoreRequest = sdk.exec.SemaphoreRequest;
const SemaphoreMessage = sdk.exec.SemaphoreMessage;
const SemaphoreHold = sdk.exec.SemaphoreHold;

const SEM_HOLDS = sdk.exec.SEM_HOLDS;
const SEMF_EXCLUSIVE = sdk.exec.SEMF_EXCLUSIVE;
const SEMF_WAITERS = sdk.exec.SEMF_WAITERS;

/// The body both obtains share: the semaphore taken at once if it can be
/// (`obtainNow`), and else a request built on the caller's own stack,
/// queued under the semaphore lock - unless the semaphore came free
/// meanwhile - and slept on until it is granted. The request may live on
/// the stack because the caller does not return until it has been granted
/// and taken off the queue.
///
/// INPUTS:
/// - `base` - exec: the jump table the calls go through, `FindTask`
///   included.
/// - `sem` - the semaphore.
/// - `shared` - whether a shared hold is wanted rather than an exclusive
///   one.
pub fn obtain(base: *ExecBase, sem: *SignalSemaphore, shared: bool) void {
    if (obtainNow(base, sem, shared)) return;
    const sys = base.iface();
    const task = sys.FindTask(null).?;
    var request: SemaphoreRequest = .{ .waiter = task, .shared = shared };
    sys.AcquireLock(&base.lock_semaphores);
    const granted = enter(base, sem, &request);
    // Queued: the request named, as the task may be removed while it
    // waits and the request is on its stack.
    if (!granted) {
        task.waiting = &request;
        task.waiting_for = sem;
    }
    sys.ReleaseLock(&base.lock_semaphores);
    // Asleep without the lock: a grant made in between is in the request
    // and in the signal, so nothing is missed.
    if (!granted) waitGranted(base, &request);
}

/// `sem` taken for the running task if it can be had without waiting:
/// one compare-and-swap on its state, and the hold counted in the task's
/// table. This core's interrupts are masked meanwhile, so the task is
/// neither switched, nor moved to another core, nor removed between
/// taking it and counting it - the running task is read in the same
/// stretch, which is why this is no `FindTask`.
///
/// INPUTS:
/// - `base` - exec.
/// - `sem` - the semaphore.
/// - `shared` - whether a shared hold is wanted.
///
/// RESULT:
/// True when it is the task's; false, and nothing changed, when it would
/// have to wait.
pub fn obtainNow(base: *ExecBase, sem: *SignalSemaphore, shared: bool) bool {
    const hardware = _interrupt.interrupt_hardware;
    const mask = hardware.disable();
    defer hardware.restore(mask);
    const task = base.cpu().this_task;
    if (!take(base, sem, task, shared)) return false;
    noteHold(task, sem, shared);
    return true;
}

/// `sem`'s state changed for a grant to `task` that needs no queue; its
/// owner set when it is the exclusive hold of a free one. False when it
/// cannot be had without waiting.
fn take(base: *ExecBase, sem: *SignalSemaphore, task: *Task, shared: bool) bool {
    var state = load(sem);
    while (true) : (state = load(sem)) {
        const next = grantable(sem, state, task, shared) orelse return false;
        if (exchange(base, sem, state, next)) {
            if (next == SEMF_EXCLUSIVE | 1) sem.owner = task;
            return true;
        }
    }
}

/// What `sem`'s state becomes when `task` takes it now, or null when it
/// cannot be had without waiting. It can be when it is free, when `task`
/// holds it exclusively already - a nested hold, of either kind - or when
/// the request is shared and the semaphore is held shared, which is why a
/// reader never waits behind a queued writer.
///
/// The owner is read only to see whether it is `task`, which no other
/// task ever writes there: a moment's other value is no answer it acts
/// on.
fn grantable(sem: *const SignalSemaphore, state: u32, task: *Task, shared: bool) ?u32 {
    const holds = state & SEM_HOLDS;
    if (holds == SEM_HOLDS) return null; // nested as far as it counts
    if (state & SEMF_EXCLUSIVE != 0) return if (sem.owner == task) state + 1 else null;
    if (shared) return state + 1;
    return if (holds == 0) SEMF_EXCLUSIVE | 1 else null;
}

/// `sem`'s state, as it is now.
pub inline fn load(sem: *const SignalSemaphore) u32 {
    return @atomicLoad(u32, &sem.state, .acquire);
}

/// `sem`'s state changed from `expected` to `new`; false when it was
/// something else by then. Ordered both ways: what a holder did before it
/// let go is seen by whoever takes the semaphore next.
pub fn exchange(base: *ExecBase, sem: *SignalSemaphore, expected: u32, new: u32) bool {
    return compareAndSetOrdered(base, &sem.state, expected, new, .acq_rel);
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

/// The first half of an obtain, with the semaphore lock held: takes the
/// semaphore if it can be had now (`grantable`), and queues the request
/// if it cannot - `SEMF_WAITERS` set in the same compare-and-swap that
/// found it held, so a release that comes after it hands it on.
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
    var state = load(sem);
    while (true) : (state = load(sem)) {
        if (grantable(sem, state, task, request.shared)) |next| {
            if (!exchange(base, sem, state, next)) continue;
            if (next == SEMF_EXCLUSIVE | 1) sem.owner = task;
            request.granted = true;
            noteHold(task, sem, request.shared);
            return true;
        }
        // Flagged already, it stays held until this lock is let go: its
        // last release has to take it.
        if (state & SEMF_WAITERS == 0 and !exchange(base, sem, state, state | SEMF_WAITERS)) continue;
        // Nested as far as the count goes: a request that would wait for
        // itself, said before it does.
        if (state & SEM_HOLDS == SEM_HOLDS) Alert(base, sdk.exec.AN_SemCorrupt);
        base.iface().AddTail(&sem.wait_queue, &request.link);
        return false;
    }
}

/// One hold of `sem` given back by the running task when that hands
/// nothing on: counted down, or the semaphore freed, with one
/// compare-and-swap, and the task's table counted down - with this core's
/// interrupts masked, as in `obtainNow`.
///
/// INPUTS:
/// - `base` - exec.
/// - `sem` - the semaphore.
///
/// RESULT:
/// True when it was given back. False, and nothing changed, when its last
/// hold goes with tasks waiting, when the task's table has no entry for
/// it, or when it is not the task's: what `leave` does, or alerts, under
/// the lock.
pub fn releaseNow(base: *ExecBase, sem: *SignalSemaphore) bool {
    const hardware = _interrupt.interrupt_hardware;
    const mask = hardware.disable();
    defer hardware.restore(mask);
    const task = base.cpu().this_task;
    const hold = findHold(&task.holds, sem) orelse return false;
    var state = load(sem);
    while (true) : (state = load(sem)) {
        const holds = state & SEM_HOLDS;
        if (holds == 0 or (state & SEMF_EXCLUSIVE != 0 and sem.owner != task)) return false;
        if (holds > 1) {
            if (exchange(base, sem, state, state - 1)) break;
        } else {
            if (state & SEMF_WAITERS != 0) return false;
            if (free(base, sem, state, task)) break;
        }
    }
    hold.count -|= 1;
    if (hold.count == 0 or state & SEM_HOLDS == 1) hold.* = .{};
    return true;
}

/// One release, for a named task rather than the running one - which is
/// what `Vacate` and a task's end need, since the lock belongs to whoever
/// took it. The caller holds the semaphore lock.
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
    if (!heldBy(sem, task)) {
        // Direct, not through the table: the path that reports a broken
        // machine must not depend on a vector something has replaced
        // (codex rule 1).
        Alert(base, sdk.exec.AN_SemCorrupt);
        return;
    }
    dropHold(task, sem, letGo(base, sem, task));
}

/// Whether `sem` is held at all, and - held exclusively - by `task`.
pub fn heldBy(sem: *const SignalSemaphore, task: *Task) bool {
    const state = load(sem);
    return state & SEM_HOLDS != 0 and (state & SEMF_EXCLUSIVE == 0 or sem.owner == task);
}

/// One hold of `sem` given up for `task`, with the semaphore lock held:
/// counted down; or, the last one, the semaphore freed, or handed
/// straight to the tasks waiting (`handOn`). The tables are the caller's.
///
/// RESULT:
/// True when it was the last hold.
pub fn letGo(base: *ExecBase, sem: *SignalSemaphore, task: *Task) bool {
    var state = load(sem);
    while (true) : (state = load(sem)) {
        if (state & SEM_HOLDS > 1) {
            if (exchange(base, sem, state, state - 1)) return false;
        } else if (state & SEMF_WAITERS == 0) {
            if (free(base, sem, state, task)) return true;
        } else if (handOn(base, sem, state)) {
            return true;
        }
    }
}

/// `sem`, held once and with nobody queued, let go by `task`: its owner
/// cleared first, so whoever takes it next cannot have its name written
/// over, and put back when the state changed meanwhile - a task queued -
/// for the caller to look again.
fn free(base: *ExecBase, sem: *SignalSemaphore, state: u32, task: *Task) bool {
    const exclusive = state & SEMF_EXCLUSIVE != 0;
    if (exclusive) sem.owner = null;
    if (exchange(base, sem, state, 0)) return true;
    if (exclusive) sem.owner = task;
    return false;
}

/// `sem`'s last hold gone with tasks queued, under the semaphore lock:
/// handed straight on - to the first waiter alone when it wants it
/// exclusively, else to **every** shared waiter in the queue together -
/// with its state set for them in the same compare-and-swap, so it is
/// never free with a task queued.
///
/// INPUTS:
/// - `base` - exec: the jump table `Remove` goes through.
/// - `sem` - the semaphore.
/// - `state` - its state, held once and flagged.
///
/// RESULT:
/// False when the state was something else by then - a shared request
/// joined - for the caller to look again.
fn handOn(base: *ExecBase, sem: *SignalSemaphore, state: u32) bool {
    const sys = base.iface();
    const head = sem.wait_queue.first() orelse {
        // Flagged with nobody queued cannot be, and is no reason to keep
        // it held.
        _ = exchange(base, sem, state, state & ~SEMF_WAITERS);
        return false;
    };
    const first: *SemaphoreRequest = @fieldParentPtr("link", head);
    var it = sem.wait_queue.iterator();
    if (!first.shared) {
        _ = it.next();
        const more: u32 = if (it.next() != null) SEMF_WAITERS else 0;
        if (!exchange(base, sem, state, SEMF_EXCLUSIVE | 1 | more)) return false;
        sys.Remove(head);
        sem.owner = first.waiter;
        noteGrant(sem, first);
        wake(base, sem, first);
        return true;
    }
    var shared: u32 = 0;
    var exclusive_left = false;
    while (it.next()) |node| {
        const request: *SemaphoreRequest = @fieldParentPtr("link", node);
        if (request.shared) shared += 1 else exclusive_left = true;
    }
    // Cleared first: from a shared state the swap below can fail, and the
    // owner of one held shared is null all the same.
    sem.owner = null;
    if (!exchange(base, sem, state, shared | if (exclusive_left) SEMF_WAITERS else 0)) return false;
    it = sem.wait_queue.iterator();
    while (it.next()) |node| {
        const request: *SemaphoreRequest = @fieldParentPtr("link", node);
        if (!request.shared) continue;
        sys.Remove(node);
        noteGrant(sem, request);
        wake(base, sem, request);
    }
    return true;
}

/// A queued request's grant counted for its task: in the table of
/// Procure's grants for a bid, else in the task's own, which is still
/// while the task sleeps for this very grant.
fn noteGrant(sem: *SignalSemaphore, request: *SemaphoreRequest) void {
    const task = request.waiter.?;
    if (request.bid != null) noteBidHold(task, sem, request.shared) else noteHold(task, sem, request.shared);
}

/// `SEMF_WAITERS` taken off `sem` once its queue is empty: a waiter gone
/// without being granted it. The caller holds the semaphore lock.
pub fn queueChanged(base: *ExecBase, sem: *SignalSemaphore) void {
    if (!sem.wait_queue.isEmpty()) return;
    var state = load(sem);
    while (state & SEMF_WAITERS != 0) : (state = load(sem)) {
        if (exchange(base, sem, state, state & ~SEMF_WAITERS)) return;
    }
}

/// Tells a waiter it has been granted the semaphore - by replying its bid
/// if it procured one, and otherwise by signalling the task.
///
/// **The grant is the last thing read or written of the request.** A
/// sleeper's request is on its own stack, and the sleeper - on another
/// core, looking at `granted` without the lock - may see it set at once,
/// return from its obtain and use that stack for anything: the waiter
/// and the bid are taken out first, and the signal or the reply goes by
/// what was taken.
///
/// INPUTS:
/// - `base` - exec: the jump table `Signal` goes through.
/// - `sem` - the semaphore.
/// - `request` - the request that won it.
fn wake(base: *ExecBase, sem: *SignalSemaphore, request: *SemaphoreRequest) void {
    const waiter = request.waiter.?;
    const bid = request.bid;
    if (waiter.waiting == request) {
        waiter.waiting = null;
        waiter.waiting_for = null;
    }
    @atomicStore(bool, &request.granted, true, .release);
    if (bid) |procured| return reply(base, sem, procured);
    base.iface().Signal(waiter, sdk.exec.tasks.SIGF_SINGLE);
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
/// The flag is read atomically because it is written by another task -
/// the one releasing the semaphore, maybe on another core - and nothing
/// in the loop would otherwise make the compiler read it again; with
/// acquire, so what the releaser did before the grant is seen after it.
/// The caller holds no spinlock: `Wait` with one held is a dead end.
///
/// INPUTS:
/// - `base` - exec: the jump table `Wait` goes through.
/// - `request` - the request to watch.
pub fn waitGranted(base: *ExecBase, request: *SemaphoreRequest) void {
    while (!@atomicLoad(bool, &request.granted, .acquire)) _ = base.iface().Wait(sdk.exec.tasks.SIGF_SINGLE);
}

// --- what a task holds ----------------------------------------------------------

/// `task` granted `sem` once more, counted in its table: in the entry the
/// semaphore has there, or a free one, or in `holds_lost` when the table
/// is full. Written by the task itself, or by the one granting it what it
/// sleeps for.
///
/// INPUTS:
/// - `task` - the task granted it.
/// - `sem` - the semaphore.
/// - `shared` - whether the hold is shared; an entry keeps the kind of its
///   first hold, which a nested one of the other kind does not change.
pub fn noteHold(task: *Task, sem: *SignalSemaphore, shared: bool) void {
    note(&task.holds, &task.holds_lost, sem, shared);
}

/// A grant of Procure's counted, as `noteHold` counts the others, in the
/// task's table of them. The caller holds the semaphore lock.
pub fn noteBidHold(task: *Task, sem: *SignalSemaphore, shared: bool) void {
    note(&task.bid_holds, &task.bid_holds_lost, sem, shared);
}

fn note(table: []SemaphoreHold, lost: *u16, sem: *SignalSemaphore, shared: bool) void {
    var free_entry: ?*SemaphoreHold = null;
    for (table) |*hold| {
        if (hold.semaphore == sem) {
            hold.count +|= 1;
            return;
        }
        if (hold.semaphore == null and free_entry == null) free_entry = hold;
    }
    const entry = free_entry orelse {
        lost.* +|= 1;
        return;
    };
    entry.* = .{ .semaphore = sem, .count = 1, .shared = shared };
}

/// `sem`'s entry in `table`, or null.
fn findHold(table: []SemaphoreHold, sem: *SignalSemaphore) ?*SemaphoreHold {
    for (table) |*hold| {
        if (hold.semaphore == sem) return hold;
    }
    return null;
}

/// One hold of `sem` by `task` let go: its entry counted down, and freed
/// at 0 - or at once when the semaphore has left the task, which no count
/// the entry still has can stand for. Looked for in the task's own table,
/// then in Procure's - a procured hold may be given back with
/// ReleaseSemaphore. A hold neither has an entry for was a lost one. The
/// caller holds the semaphore lock.
///
/// INPUTS:
/// - `task` - the holder.
/// - `sem` - the semaphore.
/// - `free_now` - this was the task's last hold of it.
pub fn dropHold(task: *Task, sem: *SignalSemaphore, free_now: bool) void {
    if (drop(&task.holds, sem, free_now) or drop(&task.bid_holds, sem, free_now)) return;
    if (task.holds_lost > 0) {
        task.holds_lost -= 1;
    } else if (task.bid_holds_lost > 0) {
        task.bid_holds_lost -= 1;
    }
}

/// A procured hold let go (`Vacate`): from Procure's table only, which is
/// all another task may write of the bidder's. The caller holds the
/// semaphore lock.
pub fn dropBidHold(task: *Task, sem: *SignalSemaphore, free_now: bool) void {
    if (drop(&task.bid_holds, sem, free_now)) return;
    if (task.bid_holds_lost > 0) task.bid_holds_lost -= 1;
}

fn drop(table: []SemaphoreHold, sem: *SignalSemaphore, free_now: bool) bool {
    const hold = findHold(table, sem) orelse return false;
    hold.count -|= 1;
    if (hold.count == 0 or free_now) hold.* = .{};
    return true;
}

/// What `releaseHolds` gave back: how many semaphores, and the first few,
/// for the line the task's end prints.
pub const Released = struct {
    count: u32 = 0,
    first: [4]?*SignalSemaphore = @splat(null),
    /// Holds the table had no room for, which stay held.
    lost: u16 = 0,
};

/// Every semaphore `task` still holds let go, each as often as it holds
/// it - its own and those Procure won - so whoever is queued behind it
/// gets it. An entry is checked before anything is released - the
/// semaphore still one, held by this task (or held shared, at least as
/// often) - since the memory it names may have been freed with the lock
/// in it, and a stale entry is passed over. The task is ending: it does
/// not run on, holding them, after this.
///
/// INPUTS:
/// - `base` - exec: its semaphore lock, and what `letGo` hands the
///   semaphores on with.
/// - `task` - the ending task.
/// - `released` - filled in.
pub fn releaseHolds(base: *ExecBase, task: *Task, released: *Released) void {
    const sys = base.iface();
    sys.AcquireLock(&base.lock_semaphores);
    defer sys.ReleaseLock(&base.lock_semaphores);
    released.lost = task.holds_lost +| task.bid_holds_lost;
    task.holds_lost = 0;
    task.bid_holds_lost = 0;
    for ([_][]SemaphoreHold{ &task.holds, &task.bid_holds }) |table| {
        for (table) |*hold| {
            const sem = hold.semaphore orelse continue;
            const count = hold.count;
            const shared = hold.shared;
            hold.* = .{};
            const state = load(sem);
            if (sem.link.type != .signalsem or state & SEM_HOLDS < count or count == 0) continue;
            if (shared) {
                if (state & SEMF_EXCLUSIVE != 0) continue;
                for (0..count) |_| _ = letGo(base, sem, task);
            } else {
                if (state & SEMF_EXCLUSIVE == 0 or sem.owner != task) continue;
                while (load(sem) & SEMF_EXCLUSIVE != 0 and sem.owner == task) _ = letGo(base, sem, task);
            }
            if (released.count < released.first.len) released.first[released.count] = sem;
            released.count += 1;
        }
    }
}

/// A task removed while it waits for a semaphore taken out of the queue:
/// its request is on its stack, which goes with it. One granted meanwhile
/// is a hold, which `releaseHolds` gives back. Taking a waiter out hands
/// nothing on - a semaphore with waiters is held, and the waiter behind
/// waits for the holder, not for it.
///
/// INPUTS:
/// - `base` - exec: its semaphore lock.
/// - `task` - the task, which does not run.
pub fn withdraw(base: *ExecBase, task: *Task) void {
    const sys = base.iface();
    sys.AcquireLock(&base.lock_semaphores);
    defer sys.ReleaseLock(&base.lock_semaphores);
    const request = task.waiting orelse return;
    const sem = task.waiting_for.?;
    task.waiting = null;
    task.waiting_for = null;
    if (request.granted) return;
    sys.Remove(&request.link);
    queueChanged(base, sem);
}

// --- spinlocks ----------------------------------------------------------------

/// exec's own locks in the lock order: each after the ones a holder of it
/// may still go on to take.
pub const order_semaphores: u16 = lk.LOCKORDER_SYSTEM + 100;
pub const order_memory: u16 = lk.LOCKORDER_SYSTEM + 300;
pub const order_ports: u16 = lk.LOCKORDER_SYSTEM + 400;

/// What a held lock's state says on this core: the core's number and
/// one.
pub fn heldHere(_: *ExecBase) u32 {
    return exec_base.coreId() + 1;
}

/// Whether `address` is internal data memory, where S32C1I is atomic.
fn inInternalMemory(address: usize) bool {
    return address >= map.DRAM_START and address < map.DRAM_END;
}

/// `word` set to `new` if it holds `expected`; true when it was.
///
/// In internal memory it is one S32C1I. In PSRAM this chip has no atomic
/// store, so the change is made under the base's guard word - itself one
/// S32C1I away, in internal memory - with this core's interrupts masked
/// for the few instructions it takes. A guard held elsewhere fails the
/// try, which the caller makes again.
///
/// INPUTS:
/// - `base` - exec: its guard word.
/// - `word` - the word, 4-byte aligned.
/// - `expected` - what it has to hold.
/// - `new` - what it is set to.
pub fn compareAndSet(base: *ExecBase, word: *u32, expected: u32, new: u32) bool {
    return compareAndSetOrdered(base, word, expected, new, .acquire);
}

/// `compareAndSet` with the ordering of a success said: acquire to take
/// a lock, acquire and release both where one change may give it up.
pub fn compareAndSetOrdered(base: *ExecBase, word: *u32, expected: u32, new: u32, comptime order: std.builtin.AtomicOrder) bool {
    if (builtin.is_test or inInternalMemory(@intFromPtr(word))) {
        return @cmpxchgStrong(u32, word, expected, new, order, .monotonic) == null;
    }
    const hardware = _interrupt.interrupt_hardware;
    const state = hardware.disable();
    defer hardware.restore(state);
    if (@cmpxchgStrong(u32, &base.lock_guard, 0, 1, .acquire, .monotonic) != null) return false;
    defer @atomicStore(u32, &base.lock_guard, 0, .release);
    const value: *volatile u32 = word;
    if (value.* != expected) return false;
    value.* = new;
    return true;
}

/// Task switching on this core stopped for as long as `lock` is held or
/// tried - on this core alone: the holder keeps its core, the other core
/// goes on. A LOCKF_INTERRUPT lock is taken inside Disable as well, which
/// masks the core's interrupts and takes the system's interrupt lock: a
/// holder that signals a task takes that lock anyway, and an interrupt on
/// the other core that wants this lock holds it already, so it comes
/// first, always.
pub fn holdCore(base: *ExecBase, lock: *const Lock) void {
    if (lock.flags & lk.LOCKF_INTERRUPT != 0) base.iface().Disable();
    const hardware = _interrupt.interrupt_hardware;
    const state = hardware.disable();
    base.cpu().hold_count += 1;
    hardware.restore(state);
}

/// What `holdCore` stopped, going again, and a switch that came due
/// meanwhile taken.
pub fn releaseCore(base: *ExecBase, lock: *const Lock) void {
    const hardware = _interrupt.interrupt_hardware;
    const state = hardware.disable();
    const cpu = base.cpu();
    cpu.hold_count -= 1;
    const due = _task.switchDue(cpu);
    hardware.restore(state);
    if (lock.flags & lk.LOCKF_INTERRUPT != 0) {
        base.iface().Enable(); // which takes a switch due itself
    } else if (due) {
        _task.task_hardware.switch_now();
    }
}

/// A lock's name for an alert.
fn nameOf(lock: *const Lock) [*:0]const u8 {
    return lock.node.name orelse "a lock";
}

/// The rules for taking `lock` now: in an interrupt only a
/// LOCKF_INTERRUPT lock, and - for a lock that is waited for (`ordered`)
/// - only after every lock the core holds in the lock order. A broken
/// rule is a recoverable alert naming the locks; the lock is taken all the
/// same.
///
/// INPUTS:
/// - `where` - the caller's address, for the alert.
pub fn checkTake(base: *ExecBase, lock: *const Lock, ordered: bool, where: usize) void {
    // Read with the interrupts masked, alerted with them on: the alert
    // prints.
    const hardware = _interrupt.interrupt_hardware;
    const state = hardware.disable();
    const cpu = base.cpu();
    const in_interrupt = cpu.int_depth != 0;
    const full = cpu.lock_count == lk.LOCKS_HELD_MAX;
    var later: ?*const Lock = null;
    if (ordered and !full) {
        for (cpu.locks_held[0..cpu.lock_count]) |entry| {
            const held = entry orelse continue;
            if (held.order < lock.order) continue;
            later = held;
            break;
        }
    }
    hardware.restore(state);

    if (in_interrupt and lock.flags & lk.LOCKF_INTERRUPT == 0) {
        ruleBroken(base, "%.40s taken in an interrupt, without LOCKF_INTERRUPT", .{nameOf(lock)}, where);
    }
    if (full) {
        ruleBroken(base, "%.40s taken while the core holds %u locks already", .{ nameOf(lock), @as(u32, lk.LOCKS_HELD_MAX) }, where);
        return;
    }
    const held = later orelse return;
    ruleBroken(base, "%.40s (order %u) taken while %.40s (order %u) is held", .{
        nameOf(lock),
        @as(u32, lock.order),
        nameOf(held),
        @as(u32, held.order),
    }, where);
}

/// `lock` taken: on the core's list, and its holder noted.
pub fn noteTaken(base: *ExecBase, lock: *Lock) void {
    const hardware = _interrupt.interrupt_hardware;
    const state = hardware.disable();
    defer hardware.restore(state);
    const cpu = base.cpu();
    if (cpu.lock_count < lk.LOCKS_HELD_MAX) {
        cpu.locks_held[cpu.lock_count] = lock;
        cpu.lock_count += 1;
    }
    lock.owner = if (cpu.int_depth == 0) cpu.this_task else null;
}

/// `lock` off the core's list; false when it was not on it.
pub fn noteReleased(base: *ExecBase, lock: *Lock) bool {
    const hardware = _interrupt.interrupt_hardware;
    const state = hardware.disable();
    defer hardware.restore(state);
    const cpu = base.cpu();
    var at: usize = 0;
    while (at < cpu.lock_count) : (at += 1) {
        if (cpu.locks_held[at] == lock) break;
    } else return false;
    while (at + 1 < cpu.lock_count) : (at += 1) cpu.locks_held[at] = cpu.locks_held[at + 1];
    cpu.lock_count -= 1;
    cpu.locks_held[cpu.lock_count] = null;
    lock.owner = null;
    return true;
}

/// Wait called from an interrupt, which is fatal, or with a lock held: the
/// holder would go to sleep with the lock, and anyone after it spin for
/// good. The core's state is read with its interrupts masked: a task that
/// holds no lock may be moved to the other core between two reads.
pub fn checkWait(base: *ExecBase, where: usize) void {
    const hardware = _interrupt.interrupt_hardware;
    const state = hardware.disable();
    const cpu = base.cpu();
    const in_interrupt = cpu.int_depth != 0;
    const held = if (cpu.lock_count == 0) null else cpu.locks_held[cpu.lock_count - 1];
    hardware.restore(state);
    if (in_interrupt) @panic("Wait called from an interrupt");
    const lock = held orelse return;
    // A dead end: the core's count of locks held is the core's, not the
    // task's, so a task that waited holding one would leave the next task
    // on its core unable to be switched - and everyone after the lock
    // spinning for good.
    var text: [120]u8 = undefined;
    format(base, &text, "Wait called while %.40s is held", .{nameOf(lock)});
    base.iface().AlertAt(sdk.exec.AT_DeadEnd | sdk.exec.AN_LockRule, where, @ptrCast(&text));
}

/// A lock given back that the core does not hold.
pub fn notHeld(base: *ExecBase, lock: *const Lock, where: usize) void {
    ruleBroken(base, "%.40s released, which the core does not hold", .{nameOf(lock)}, where);
}

/// `lock` taken again on the core that holds it: by the code an interrupt
/// interrupted, or by a task that waited holding it. Nothing on the core
/// can let it go, so taking it would never end: a dead end.
pub fn deadlock(base: *ExecBase, lock: *const Lock, where: usize) void {
    var text: [120]u8 = undefined;
    const owner: [*:0]const u8 = if (lock.owner) |task| task.node.name orelse "?" else "an interrupt";
    format(base, &text, "%.40s taken on the core that holds it (%.40s)", .{ nameOf(lock), owner });
    base.iface().AlertAt(sdk.exec.AN_LockDeadlock, where, @ptrCast(&text));
}

fn ruleBroken(base: *ExecBase, comptime format_string: [:0]const u8, args: anytype, where: usize) void {
    var text: [160]u8 = undefined;
    format(base, &text, format_string, args);
    base.iface().AlertAt(sdk.exec.AN_LockRule, where, @ptrCast(&text));
}

/// A RawDoFmt format with its values into `into`.
fn format(base: *ExecBase, into: []u8, comptime format_string: [:0]const u8, args: anytype) void {
    comptime sdk.exec.checkFormat(format_string, @TypeOf(args));
    const stream = sdk.exec.fmtStream(args);
    _ = base.iface().RawDoFmt(format_string, &stream, null, into.ptr);
}

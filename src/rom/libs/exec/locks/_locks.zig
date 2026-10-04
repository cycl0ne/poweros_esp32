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
//! All of it runs with the caller holding exec's semaphore lock
//! (`lock_semaphores`), which is what keeps a semaphore's counts and
//! queue consistent between tasks; a caller that has to sleep gives the
//! lock back first.
//!
//! **Spinlocks** (InitLock, AcquireLock, AttemptLock, ReleaseLock) share
//! the second half: the word taken atomically - S32C1I in internal memory,
//! under the base's guard word in PSRAM - task switching (or with
//! LOCKF_INTERRUPT the core's interrupts) stopped while one is held, and
//! the rules of sdk/libs/exec/locks.zig checked against the locks the
//! core holds.

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
    var request: SemaphoreRequest = .{ .waiter = sys.FindTask(null).?, .shared = shared };
    sys.AcquireLock(&base.lock_semaphores);
    const granted = enter(base, sem, &request);
    sys.ReleaseLock(&base.lock_semaphores);
    // Asleep without the lock: a grant made in between is in the request
    // and in the signal, so nothing is missed.
    if (!granted) waitGranted(base, &request);
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
/// and queues the request if it cannot. The caller holds the semaphore
/// lock.
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
/// caller holds the semaphore lock.
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
/// loop would otherwise make the compiler read it again. The caller holds
/// no lock; a `Wait` under the caller's own Forbid breaks it while it
/// sleeps, which is how a semaphore can be obtained under Forbid at all.
///
/// INPUTS:
/// - `base` - exec: the jump table `Wait` goes through.
/// - `request` - the request to watch.
pub fn waitGranted(base: *ExecBase, request: *SemaphoreRequest) void {
    const granted: *volatile bool = &request.granted;
    while (!granted.*) _ = base.iface().Wait(sdk.exec.tasks.SIGF_SINGLE);
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
    if (builtin.is_test or inInternalMemory(@intFromPtr(word))) {
        return @cmpxchgStrong(u32, word, expected, new, .acquire, .monotonic) == null;
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
    if (base.cpu().int_depth != 0 and lock.flags & lk.LOCKF_INTERRUPT == 0) {
        ruleBroken(base, "%.40s taken in an interrupt, without LOCKF_INTERRUPT", .{nameOf(lock)}, where);
    }
    if (base.cpu().lock_count == lk.LOCKS_HELD_MAX) {
        ruleBroken(base, "%.40s taken while the core holds %u locks already", .{ nameOf(lock), @as(u32, lk.LOCKS_HELD_MAX) }, where);
        return;
    }
    if (!ordered) return;
    for (base.cpu().locks_held[0..base.cpu().lock_count]) |entry| {
        const held = entry orelse continue;
        if (held.order < lock.order) continue;
        ruleBroken(base, "%.40s (order %u) taken while %.40s (order %u) is held", .{
            nameOf(lock),
            @as(u32, lock.order),
            nameOf(held),
            @as(u32, held.order),
        }, where);
        return;
    }
}

/// `lock` taken: on the core's list, and its holder noted.
pub fn noteTaken(base: *ExecBase, lock: *Lock) void {
    if (base.cpu().lock_count < lk.LOCKS_HELD_MAX) {
        base.cpu().locks_held[base.cpu().lock_count] = lock;
        base.cpu().lock_count += 1;
    }
    lock.owner = if (base.cpu().int_depth == 0) base.cpu().this_task else null;
}

/// `lock` off the core's list; false when it was not on it.
pub fn noteReleased(base: *ExecBase, lock: *Lock) bool {
    var at: usize = 0;
    while (at < base.cpu().lock_count) : (at += 1) {
        if (base.cpu().locks_held[at] == lock) break;
    } else return false;
    while (at + 1 < base.cpu().lock_count) : (at += 1) base.cpu().locks_held[at] = base.cpu().locks_held[at + 1];
    base.cpu().lock_count -= 1;
    base.cpu().locks_held[base.cpu().lock_count] = null;
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
    ruleBroken(base, "Wait called while %.40s is held", .{nameOf(lock)}, where);
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

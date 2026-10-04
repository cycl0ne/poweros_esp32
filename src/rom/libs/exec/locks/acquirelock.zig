// SPDX-License-Identifier: MPL-2.0
//! AcquireLock: a spinlock taken, spinning while another core holds it.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");
const _interrupt = @import("../interrupt/_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Lock = sdk.exec.Lock;

/// Takes a spinlock, trying again for as long as another core holds it.
///
/// SYNOPSIS:
/// ```zig
/// fn AcquireLock(base: *ExecBase, lock: *Lock) void
/// ```
///
/// SINCE: 1.3. LVO -496.
///
/// INPUTS:
/// - `lock` - a lock made with `InitLock`.
///
/// RESULT:
/// Nothing: the lock is the caller's when it returns.
///
/// BEHAVIOR:
/// Task switching on this core stops first - on this core only: the other
/// core goes on - and a `LOCKF_INTERRUPT` lock is taken inside `Disable`
/// as well, which masks this core's interrupts and holds off the other
/// core's; both last until `ReleaseLock`. Then the lock is
/// taken, or tried again until it is free. A lock this very core holds
/// already - taken by the code an interrupt interrupted, or by a task
/// that waited while holding it - would never come free: that is a dead
/// end (`AN_LockDeadlock`), not a spin.
///
/// The lock rules are checked as it is taken: in an interrupt only a
/// `LOCKF_INTERRUPT` lock, and only after every lock the core holds in
/// the lock order. A broken rule is a recoverable alert naming the locks
/// (`AN_LockRule`), and the lock is taken all the same.
///
/// CONTEXT:
/// - Waits: never - it spins, and only while another core holds the lock.
/// - Interrupts: a `LOCKF_INTERRUPT` lock only.
/// - Forbid: may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The lock is the caller's until `ReleaseLock`. It is held for a few
/// hundred cycles at most, and nothing that may wait is called meanwhile:
/// no `Wait`, `DoIO`, `ObtainSemaphore`, no file - nor `AllocMem`, whose
/// low-memory handlers expunge libraries.
///
/// NOTES:
/// A plain lock free to take costs a compare-and-set and two masked
/// counts; a `LOCKF_INTERRUPT` lock a `Disable` as well.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InitLock`, `AttemptLock`, `ReleaseLock`, `Forbid`, `Disable`
///
/// EXAMPLES:
/// ```zig
/// sys.AcquireLock(&unit.lock);
/// unit.queue_head = next;
/// sys.ReleaseLock(&unit.lock);
/// ```
pub fn AcquireLock(base: *ExecBase, lock: *Lock) void {
    const where = @returnAddress();
    // Held first, so the rules are checked against this core's locks.
    _locks.holdCore(base, lock);
    _locks.checkTake(base, lock, true, where);
    const here = _locks.heldHere(base);
    while (!_locks.compareAndSet(base, &lock.state, 0, here)) {
        // Held on this very core: nothing here can let it go.
        if (@atomicLoad(u32, &lock.state, .monotonic) == here) {
            _locks.deadlock(base, lock, where);
            // Reached only where a dead end comes back: the host tests.
            _locks.releaseCore(base, lock);
            return;
        }
        // Spinning with the interrupts perhaps masked: a core that holds
        // this one still is answered from here.
        _interrupt.interrupt_hardware.park_if_asked();
    }
    _locks.noteTaken(base, lock);
}

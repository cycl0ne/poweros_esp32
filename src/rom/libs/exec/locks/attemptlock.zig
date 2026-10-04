// SPDX-License-Identifier: MPL-2.0
//! AttemptLock: a spinlock taken if it is free, without trying again.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Lock = sdk.exec.Lock;

/// Takes a spinlock if it is free, and answers at once if it is not.
///
/// SYNOPSIS:
/// ```zig
/// fn AttemptLock(base: *ExecBase, lock: *Lock) bool
/// ```
///
/// SINCE: 1.3. LVO -500.
///
/// INPUTS:
/// - `lock` - a lock made with `InitLock`.
///
/// RESULT:
/// True when the lock is now the caller's, to be given back with
/// `ReleaseLock`; false when it is held - by another core, or by this one.
///
/// BEHAVIOR:
/// As `AcquireLock` without the waiting: task switching (and with
/// `LOCKF_INTERRUPT` the core's interrupts) stops only while the lock is
/// held, and is back as it was when the answer is false. Nothing is
/// waited for, so the lock order is not checked: a lock tried out of
/// order cannot leave two cores waiting for each other.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: a `LOCKF_INTERRUPT` lock only.
/// - Locks: takes `lock` if it is free; the lock order is not checked, since a
///   try never waits.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// On true, the lock is the caller's until `ReleaseLock`, on the same
/// terms as `AcquireLock`'s.
///
/// NOTES:
/// What a caller that already holds a later lock uses to take an earlier
/// one: it backs off on false rather than break the order.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AcquireLock`, `ReleaseLock`, `InitLock`
///
/// EXAMPLES:
/// ```zig
/// if (sys.AttemptLock(&unit.lock)) {
///     defer sys.ReleaseLock(&unit.lock);
///     unit.counter += 1;
/// }
/// ```
pub fn AttemptLock(base: *ExecBase, lock: *Lock) bool {
    _locks.holdCore(base, lock);
    _locks.checkTake(base, lock, false, @returnAddress());
    if (!_locks.compareAndSet(base, &lock.state, 0, _locks.heldHere(base))) {
        _locks.releaseCore(base, lock);
        return false;
    }
    _locks.noteTaken(base, lock);
    return true;
}

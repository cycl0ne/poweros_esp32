// SPDX-License-Identifier: MPL-2.0
//! ReleaseLock: a spinlock given back.

const sdk = @import("sdk");
const _locks = @import("_locks.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Lock = sdk.exec.Lock;

/// Gives a spinlock back.
///
/// SYNOPSIS:
/// ```zig
/// fn ReleaseLock(base: *ExecBase, lock: *Lock) void
/// ```
///
/// SINCE: 1.3. LVO -504.
///
/// INPUTS:
/// - `lock` - a lock the caller took with `AcquireLock` or `AttemptLock`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Everything written while the lock was held is visible before the lock
/// is free. Then task switching on this core goes again once it holds no
/// lock - and with `LOCKF_INTERRUPT` the `Enable` matching the taking's
/// `Disable` is made: a Disable around it stays. Locks may be given back
/// in any order.
///
/// A lock this core does not hold is left as it is: a recoverable alert
/// (`AN_LockRule`).
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: a `LOCKF_INTERRUPT` lock only.
/// - Locks: gives `lock` back.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The lock is free again, for any core.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AcquireLock`, `AttemptLock`, `InitLock`
///
/// EXAMPLES:
/// ```zig
/// sys.AcquireLock(&unit.lock);
/// defer sys.ReleaseLock(&unit.lock);
/// ```
pub fn ReleaseLock(base: *ExecBase, lock: *Lock) void {
    if (@atomicLoad(u32, &lock.state, .monotonic) != _locks.heldHere(base) or !_locks.noteReleased(base, lock)) {
        _locks.notHeld(base, lock, @returnAddress());
        return;
    }
    @atomicStore(u32, &lock.state, 0, .release);
    _locks.releaseCore(base, lock);
}

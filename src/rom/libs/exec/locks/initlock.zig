// SPDX-License-Identifier: MPL-2.0
//! InitLock: a spinlock made ready.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Lock = sdk.exec.Lock;

/// Makes a spinlock ready: free, named, with its place in the lock order.
///
/// SYNOPSIS:
/// ```zig
/// fn InitLock(base: *ExecBase, lock: *Lock, name: ?[*:0]const u8, order: u32, flags: u32) void
/// ```
///
/// SINCE: 1.3. LVO -492.
///
/// INPUTS:
/// - `lock` - the lock, anywhere in memory.
/// - `name` - what it guards, for the alerts that name it; null for none.
///   Kept, not copied.
/// - `order` - its place in the lock order: from `LOCKORDER_DRIVER` for a
///   program's or a driver's own lock, below `LOCKORDER_SYSTEM`, which is
///   exec's. It is taken only while every lock the core holds is earlier.
/// - `flags` - `LOCKF_INTERRUPT` when an interrupt takes it too.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Whatever the lock held before is forgotten: a lock is made ready once,
/// before anyone takes it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The lock and its name stay the caller's. A lock is on no list and
/// needs no taking apart: it may be freed whenever nobody holds it.
///
/// NOTES:
/// The rules a lock is taken by are in sdk/libs/exec/locks.zig: held for a
/// few hundred cycles, nothing that may wait called while it is held,
/// taken in the lock order.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AcquireLock`, `AttemptLock`, `ReleaseLock`, `InitSemaphore`
///
/// EXAMPLES:
/// ```zig
/// sys.InitLock(&unit.lock, "mydev unit", sdk.exec.LOCKORDER_DRIVER, sdk.exec.LOCKF_INTERRUPT);
/// ```
pub fn InitLock(_: *ExecBase, lock: *Lock, name: ?[*:0]const u8, order: u32, flags: u32) void {
    lock.* = .{
        .node = .{ .type = .lock, .name = name },
        .order = @truncate(order),
        .flags = @truncate(flags),
    };
}

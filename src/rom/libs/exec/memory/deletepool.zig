// SPDX-License-Identifier: MPL-2.0
//! DeletePool: gives a pool's every puddle back to the system, and the
//! pool with them. Whatever was still allocated from it goes too, which
//! is the point: a pool's contents die together, in one call.

const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Pool = _memory.Pool;
const Puddle = _memory.Puddle;

/// Frees everything a pool holds, and the pool with it.
///
/// SYNOPSIS:
/// ```zig
/// fn DeletePool(base: *ExecBase, pool_handle: ?*anyopaque) void
/// ```
///
/// SINCE: 1.0. LVO -452.
///
/// INPUTS:
/// - `pool_handle` - what CreatePool answered, or null, which does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Every puddle goes back to the system. Nothing needs to have been freed
/// first, and no block in the pool may be touched afterwards.
///
/// CONTEXT:
/// - Waits: for the pool's lock while another task is in the pool.
/// - Interrupts: no; it frees memory.
/// - Locks: takes the pool's own lock; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Every puddle goes back to the system, and nothing the pool handed out
/// may be touched again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreatePool`, `FreePooled`
pub fn DeletePool(base: *ExecBase, pool_handle: ?*anyopaque) void {
    const pool: *Pool = @ptrCast(@alignCast(pool_handle orelse return));
    const sys = base.iface();
    // Whoever is in the pool finishes first; nobody may come in after, as
    // the pool is the caller's to delete.
    sys.ObtainSemaphore(&pool.lock);

    var it = pool.puddles.iterator();
    while (it.next()) |node| {
        const puddle: *Puddle = @fieldParentPtr("node", node);
        // Freeing the node just handed back is allowed: the iterator has
        // already taken the successor out of it.
        sys.FreeMem(puddle, puddle.bytes);
    }
    sys.FreeMem(pool, @sizeOf(Pool));
}

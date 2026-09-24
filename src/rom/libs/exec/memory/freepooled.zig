// SPDX-License-Identifier: MPL-2.0
//! FreePooled: gives a block back to its pool. The puddle is found by the
//! block's address; a puddle made for that one block goes straight back to
//! the system with it.

const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Pool = _memory.Pool;
const Puddle = _memory.Puddle;

/// Gives a block from `AllocPooled` back to its pool.
///
/// SYNOPSIS:
/// ```zig
/// fn FreePooled(base: *ExecBase, pool_handle: ?*anyopaque,
///     memory_block: ?*anyopaque, byte_size: usize) void
/// ```
///
/// SINCE: 1.0. LVO -460.
///
/// INPUTS:
/// - `pool` - the pool it came from, or null, which does nothing.
/// - `memory_block` - the block, or null, which does nothing.
/// - `byte_size` - **what was asked for**. A pooled block carries no
///   header saying how big it is, which is the point of a pool, so this
///   number is how the pool knows.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The space goes back to its puddle and is merged with what is free
/// either side of it, so the next request can have it. An ordinary puddle
/// stays with the pool even when nothing is left in it; `DeletePool` is
/// how memory goes back to the system.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no. - Forbid: taken here. - Process: a Task
///   will do.
///
/// OWNERSHIP:
/// The space is the pool's again and must not be touched.
///
/// NOTES:
/// A block in none of the pool's puddles stops the machine: it is a caller
/// freeing into the wrong pool, and by the time it is noticed the heap is
/// already wrong - the same answer `FreeMem` gives to a block freed twice.
///
/// The size is the caller's word and nothing checks it: a pooled block
/// keeps no record of its size, which is what makes a pool cost nothing
/// per block. A size that runs into free space stops the machine as a
/// double free does; one that is too small leaves the rest of the block
/// taken until `DeletePool`, and one that is too big frees whatever lies
/// after the block.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocPooled`, `DeletePool`
pub fn FreePooled(base: *ExecBase, pool_handle: ?*anyopaque, memory_block: ?*anyopaque, byte_size: usize) void {
    const pool: *Pool = @ptrCast(@alignCast(pool_handle orelse return));
    const block = memory_block orelse return;
    if (byte_size == 0) return;
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();

    const address = @intFromPtr(block);
    var it = pool.puddles.iterator();
    while (it.next()) |node| {
        const puddle: *Puddle = @fieldParentPtr("node", node);
        const mh = puddle.header;
        if (address < @intFromPtr(mh.lower) or address >= @intFromPtr(mh.upper)) continue;

        sys.Deallocate(mh, block, byte_size);
        // A puddle made for one block has nothing else in it now.
        if (puddle.alone) {
            sys.Remove(&puddle.node);
            sys.FreeMem(puddle, puddle.bytes);
        }
        return;
    }
    @panic("FreePooled: block is not in this pool");
}

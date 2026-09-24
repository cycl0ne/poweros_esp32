// SPDX-License-Identifier: MPL-2.0
//! CreatePool: a pool with no puddles yet. The pool itself is one small
//! block from `AllocMem`; its puddles are taken the first time something
//! is allocated from it.

const sdk = @import("sdk");
const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Pool = _memory.Pool;
const MEMF_CLEAR = sdk.exec.MEMF_CLEAR;

/// Makes a pool to take many small blocks from.
///
/// SYNOPSIS:
/// ```zig
/// fn CreatePool(base: *ExecBase, requirements: u32, puddle_size: usize,
///     thresh_size: usize) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -448.
///
/// INPUTS:
/// - `requirements` - MEMF_* as AllocMem takes them, for every puddle the
///   pool goes on to take. MEMF_CLEAR here means every block handed out is
///   cleared, not only the first.
/// - `puddle_size` - what the pool asks the system for at a time. A
///   puddle's own header comes out of this, so it must be bigger than one.
/// - `thresh_size` - a request this big or bigger gets memory of its own
///   rather than a share of a puddle. Larger than a puddle can hold is
///   taken as the largest it can hold, and 0 means no threshold at all -
///   only a request too big for a puddle gets its own.
///
/// RESULT:
/// The pool, or null: there was no memory, or `puddle_size` was too small
/// to hold a puddle's header.
///
/// BEHAVIOR:
/// Nothing is taken from the system yet. The first `AllocPooled` takes the
/// first puddle.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no; it allocates. - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `DeletePool`, which frees the pool and everything
/// still in it.
///
/// NOTES:
/// A pool is worth having where the blocks are small and die together. A
/// pooled block carries no header, so a 24-byte node costs 24 bytes rather
/// than a whole block more for a size word in front of it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeletePool`, `AllocPooled`, `FreePooled`
///
/// EXAMPLES:
/// ```zig
/// const pool = sys.CreatePool(exec.MEMF_ANY, 4096, 1024) orelse return;
/// defer sys.DeletePool(pool);
/// ```
pub fn CreatePool(base: *ExecBase, requirements: u32, puddle_size: usize, thresh_size: usize) ?*anyopaque {
    // A puddle that cannot hold its own header holds nothing.
    if (puddle_size <= _memory.puddle_overhead) return null;

    const largest = puddle_size - _memory.puddle_overhead;
    const sys = base.iface();
    const block = sys.AllocMem(@sizeOf(Pool), requirements | MEMF_CLEAR) orelse return null;
    const pool: *Pool = @ptrCast(@alignCast(block));
    pool.* = .{
        .requirements = requirements & ~@as(u32, MEMF_CLEAR),
        .clear = requirements & MEMF_CLEAR != 0,
        .puddle_size = puddle_size,
        // A threshold above what a puddle can hold could never be met by
        // one, so it is that at most; and 0 means no threshold at all
        // rather than "every block is too big", which is what taking it
        // literally would mean.
        .thresh_size = if (thresh_size == 0) largest else @min(thresh_size, largest),
    };
    sys.NewList(&pool.puddles);
    return block;
}

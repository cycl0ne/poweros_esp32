// SPDX-License-Identifier: MPL-2.0
//! AllocVec: `AllocMem` that remembers the size - which every block does
//! now, in its MemBlock, so it is AllocMem itself, and `FreeVec` reads the
//! size from there.

const ExecBase = @import("../exec.zig").ExecBase;

/// Allocates memory that remembers how big it is.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocVec(base: *ExecBase, byte_size: usize,
///     requirements: u32) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -292.
///
/// INPUTS:
/// - `byte_size` - bytes wanted.
/// - `requirements` - exactly as `AllocMem` takes them.
///
/// RESULT:
/// The block, or null: 0 bytes, or there was no memory.
///
/// BEHAVIOR:
/// It is `AllocMem`: the block's MemBlock holds its size, rounded up to
/// `MEM_BLOCKSIZE`, in the word right below the address answered, and its
/// owner, as every block's does.
///
/// CONTEXT:
/// - Waits: only when memory runs short, as `AllocMem` does.
/// - Interrupts: no. `AllocMem` takes exec's memory lock.
/// - Locks: none taken but `AllocMem`'s; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `FreeVec` - or `FreeMem` with the size asked for,
/// which is the same thing.
///
/// NOTES:
/// It costs `MEM_BLOCKSIZE` more than the bytes asked for, as `AllocMem`
/// does, which is why the alternative for many small blocks that die
/// together is a pool, whose blocks carry no MemBlock of their own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeVec`, `AllocMem`, `AllocPooled`
///
/// EXAMPLES:
/// ```zig
/// const buf = sys.AllocVec(1024, exec.MEMF_ANY | exec.MEMF_CLEAR)
///     orelse return;
/// defer sys.FreeVec(buf);
/// ```
pub fn AllocVec(base: *ExecBase, byte_size: usize, requirements: u32) ?*anyopaque {
    return base.iface().AllocMem(byte_size, requirements);
}

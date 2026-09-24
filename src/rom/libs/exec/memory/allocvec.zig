// SPDX-License-Identifier: MPL-2.0
//! AllocVec: `AllocMem` that remembers the size. The block carries a
//! `vec_header` in front, whose last word holds the whole size, so
//! `FreeVec` needs only the address.

const _memory = @import("_memory.zig");

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
/// - `requirements` - exactly as `AllocMem` takes them. `MEMF_CLEAR` clears
///   what the caller gets, not the header.
///
/// RESULT:
/// The block, or null: 0 bytes, the size plus the header overflows, or
/// there was no memory.
///
/// BEHAVIOR:
/// It allocates the header and the block as one and answers the address
/// past the header, with the whole size in the word immediately below it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. `AllocMem` takes Forbid.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `FreeVec`. It must not be freed with `FreeMem`: the
/// address is past the header, so the region would be handed the wrong
/// block.
///
/// NOTES:
/// It costs `MEM_BLOCKSIZE` more than `AllocMem`, which is why the
/// alternative for many small blocks that die together is a pool, whose
/// blocks carry no header at all.
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
    if (byte_size == 0) return null;
    const sum = @addWithOverflow(byte_size, _memory.vec_header);
    if (sum[1] != 0) return null;
    const total = sum[0];
    const size_word = _memory.fitsWord(total) orelse return null;
    const sys = base.iface();
    const block = sys.AllocMem(total, requirements) orelse return null;
    const bytes: [*]u8 = @as([*]u8, @ptrCast(block)) + _memory.vec_header;
    @as(*u32, @ptrCast(@alignCast(bytes - 4))).* = size_word;
    return bytes;
}

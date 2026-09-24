// SPDX-License-Identifier: MPL-2.0
//! FreeVec: gives back a block from `AllocVec`, reading its size from the
//! word in front of it.

const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Gives back memory from `AllocVec`.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeVec(base: *ExecBase, memory_block: ?*anyopaque) void
/// ```
///
/// SINCE: 1.0. LVO -296.
///
/// INPUTS:
/// - `memory_block` - what `AllocVec` answered, or null, which does
///   nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The size is read from the word below the block and the whole thing,
/// header included, goes back.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. `FreeMem` takes Forbid.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The memory is the system's again.
///
/// NOTES:
/// Only on a block from `AllocVec`. On anything else it reads whatever is
/// in front of the address as a size and frees that much.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocVec`, `FreeMem`
///
/// EXAMPLES:
/// ```zig
/// defer sys.FreeVec(buf);
/// ```
pub fn FreeVec(base: *ExecBase, memory_block: ?*anyopaque) void {
    const bytes: [*]u8 = @ptrCast(memory_block orelse return);
    const size = @as(*const u32, @ptrCast(@alignCast(bytes - 4))).*;
    const sys = base.iface();
    sys.FreeMem(bytes - _memory.vec_header, size);
}

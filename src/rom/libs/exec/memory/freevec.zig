// SPDX-License-Identifier: MPL-2.0
//! FreeVec: gives back a block from `AllocVec` - or AllocMem - reading its
//! size from the block's MemBlock.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;

/// Gives back memory from `AllocVec` or `AllocMem`, whose size it knows.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeVec(base: *ExecBase, memory_block: ?*anyopaque) void
/// ```
///
/// SINCE: 1.0. LVO -296.
///
/// INPUTS:
/// - `memory_block` - what `AllocVec` or `AllocMem` answered, or null,
///   which does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The size is read from the block's MemBlock and `FreeMem` is called with
/// it, which gives the block back, MemBlock included - or refuses a block
/// that is not in use, as it refuses any.
///
/// CONTEXT:
/// - Waits: no, unless `FreeMem` refuses the block and alerts.
/// - Interrupts: no. `FreeMem` takes exec's memory lock.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The memory is the system's again.
///
/// NOTES:
/// Only on a block from `AllocVec` or `AllocMem`: anything else has no
/// MemBlock in front, and `FreeMem` refuses it unless what is there
/// happens to look like one.
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
    const block = memory_block orelse return;
    // A block freed already says 0 bytes, which FreeMem would take for
    // nothing to do: it is asked all the same, and refuses it.
    const size = sdk.exec.MemBlock.of(block).bytes();
    base.iface().FreeMem(block, @max(size, 1));
}

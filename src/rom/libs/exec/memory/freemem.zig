// SPDX-License-Identifier: MPL-2.0
//! FreeMem: gives a block back to the system's memory. The region it came
//! from is found by its address, so the caller names only the block and
//! its size.

const sdk = @import("sdk");
const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const MemHeader = sdk.exec.MemHeader;

/// Gives memory back to the system.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeMem(base: *ExecBase, memory_block: ?*anyopaque,
///     byte_size: usize) void
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `memory_block` - what `AllocMem` answered, or null, which does
///   nothing so that a cleanup path need not test it.
/// - `byte_size` - **the size that was allocated**, not the size that was
///   used. 0 does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The region holding that address is found on the memory list and the
/// block goes back to it. A block in no region at all is fatal: it is
/// either an address that was never allocated or one already freed and
/// handed to someone else, and both are worth stopping for.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the search and the free.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The memory is the system's again and must not be touched.
///
/// NOTES:
/// The size has to be right. Too small leaves the difference unreachable;
/// too large frees memory that was never the caller's, which `Deallocate`
/// catches as a double free only if it happens to overlap something free.
///
/// A block in no region stops the machine: it is a caller freeing memory
/// the system never gave out.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocMem`, `FreeVec`, `Deallocate`
///
/// EXAMPLES:
/// ```zig
/// defer sys.FreeMem(buf, 1024);
/// ```
pub fn FreeMem(base: *ExecBase, memory_block: ?*anyopaque, byte_size: usize) void {
    const block = memory_block orelse return;
    if (byte_size == 0) return;
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();

    if (_memory.trace.on) _memory.traceEvent('F', byte_size, block, @returnAddress());
    const addr = @intFromPtr(block);
    var it = base.mem_list.iterator();
    while (it.next()) |node| {
        const mh: *MemHeader = @fieldParentPtr("node", node);
        if (addr >= @intFromPtr(mh.lower) and addr < @intFromPtr(mh.upper)) {
            return sys.Deallocate(mh, block, byte_size);
        }
    }
    @panic("FreeMem: block is not in any memory region");
}

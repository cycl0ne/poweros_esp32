// SPDX-License-Identifier: MPL-2.0
//! AvailMem: how much memory of a kind there is - free, the largest free
//! block, or the total - summed over the regions with the attributes asked
//! for.

const sdk = @import("sdk");
const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const MemHeader = sdk.exec.MemHeader;
const MEM_BLOCKSIZE = sdk.exec.MEM_BLOCKSIZE;

/// How much memory of a kind there is.
///
/// SYNOPSIS:
/// ```zig
/// fn AvailMem(base: *ExecBase, requirements: u32) usize
/// ```
///
/// SINCE: 1.0. LVO -116.
///
/// INPUTS:
/// - `requirements` - which regions to count, by the same attribute bits
///   `AllocMem` takes, and which question to ask:
///   - nothing further - the free bytes.
///   - `MEMF_LARGEST` - the biggest allocation that could succeed: the
///     largest single free chunk, less the MemBlock a block carries - and
///     its wall while memory debugging is on.
///   - `MEMF_TOTAL` - the regions' whole size, free or not. It wins over
///     `MEMF_LARGEST`.
///
/// RESULT:
/// The number of bytes. 0 if no region has the attributes asked for.
///
/// BEHAVIOR:
/// Free and largest differ by fragmentation, and the gap between them is
/// the only measure of it the system offers. The free bytes are the
/// regions' own count, MemBlocks of blocks to come included, so a block of
/// N bytes takes N rounded up and `MEM_BLOCKSIZE` from it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes exec's memory lock, around the walk.
/// - Locks: takes exec's memory lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// The answer is out of date as soon as it is given, on a machine where
/// another task - on either core - may allocate the moment it is. It is worth
/// having as a measurement and not as a decision: allocate and test the
/// result instead.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocMem`, `AddMemList`
///
/// EXAMPLES:
/// ```zig
/// const free = sys.AvailMem(exec.MEMF_INTERNAL);
/// const biggest = sys.AvailMem(exec.MEMF_INTERNAL | exec.MEMF_LARGEST);
/// ```
pub fn AvailMem(base: *ExecBase, requirements: u32) usize {
    const wanted = requirements & _memory.attribute_mask;
    const sys = base.iface();
    sys.AcquireLock(&base.lock_memory);
    defer sys.ReleaseLock(&base.lock_memory);

    var result: usize = 0;
    var it = base.mem_list.iterator();
    while (it.next()) |node| {
        const mh: *MemHeader = @fieldParentPtr("node", node);
        if (@as(u32, mh.attributes) & wanted != wanted) continue;
        if (requirements & sdk.exec.MEMF_TOTAL != 0) {
            result += @intFromPtr(mh.upper) - @intFromPtr(mh.lower);
        } else if (requirements & sdk.exec.MEMF_LARGEST != 0) {
            var chunk = mh.first;
            // A block carries its MemBlock, and while memory debugging is on
            // its wall as well.
            const extra: usize = MEM_BLOCKSIZE + if (base.mem_debug.on) @as(usize, sdk.exec.MEM_WALLSIZE) else 0;
            while (chunk) |free_chunk| : (chunk = free_chunk.next) {
                if (free_chunk.bytes > extra) result = @max(result, free_chunk.bytes - extra);
            }
        } else {
            result += mh.free;
        }
    }
    return result;
}

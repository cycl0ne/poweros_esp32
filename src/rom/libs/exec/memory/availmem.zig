// SPDX-License-Identifier: MPL-2.0
//! AvailMem: how much memory of a kind there is - free, the largest free
//! block, or the total - summed over the regions with the attributes asked
//! for.

const sdk = @import("sdk");
const _memory = @import("_memory.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const MemHeader = sdk.exec.MemHeader;

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
///   - `MEMF_LARGEST` - the largest single free chunk, which is the biggest
///     allocation that could succeed.
///   - `MEMF_TOTAL` - the regions' whole size, free or not. It wins over
///     `MEMF_LARGEST`.
///
/// RESULT:
/// The number of bytes. 0 if no region has the attributes asked for.
///
/// BEHAVIOR:
/// Free and largest differ by fragmentation, and the gap between them is
/// the only measure of it the system offers.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the walk.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// The answer is out of date as soon as it is given, on a machine where
/// another task may allocate the moment Forbid is let go. It is worth
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
    sys.Forbid();
    defer sys.Permit();

    var result: usize = 0;
    var it = base.mem_list.iterator();
    while (it.next()) |node| {
        const mh: *MemHeader = @fieldParentPtr("node", node);
        if (@as(u32, mh.attributes) & wanted != wanted) continue;
        if (requirements & sdk.exec.MEMF_TOTAL != 0) {
            result += @intFromPtr(mh.upper) - @intFromPtr(mh.lower);
        } else if (requirements & sdk.exec.MEMF_LARGEST != 0) {
            var chunk = mh.first;
            while (chunk) |free_chunk| : (chunk = free_chunk.next) result = @max(result, free_chunk.bytes);
        } else {
            result += mh.free;
        }
    }
    return result;
}

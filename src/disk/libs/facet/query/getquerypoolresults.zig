// SPDX-License-Identifier: MIT
//! GetQueryPoolResults: what the queries counted, read into memory.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _queue = @import("../queue/_queue.zig");
const _query = @import("_query.zig");
const Pool = _query.Pool;

/// What `count` queries from `first` counted, written into `data`.
///
/// SYNOPSIS:
/// ```zig
/// fn GetQueryPoolResults(base: *FacetBase, device: *facet.Device, pool: *facet.QueryPool, first: u32, count: u32, size: usize, data: *anyopaque, stride: u64, flags: u32) facet.Result
/// ```
///
/// SINCE: 1.29. LVO -464.
///
/// INPUTS:
/// - `device` - the device the pool was made on.
/// - `pool` - the pool.
/// - `first`, `count` - the queries read; those past the pool's last are
///   left out.
/// - `size`, `data` - the bytes written into, and how many there are.
/// - `stride` - the bytes from one query's values to the next.
/// - `flags` - `QUERY_RESULT_64` for values of 8 bytes rather than 4,
///   `QUERY_RESULT_WAIT` to wait for the work rather than answer
///   `not_ready`, `QUERY_RESULT_WITH_AVAILABILITY` for a value after each
///   query's saying whether it is available, `QUERY_RESULT_PARTIAL` to
///   write what a query not available has counted so far.
///
/// RESULT:
/// `success` where every query read was available; `not_ready` where one
/// was not, the others written all the same; `error_device_lost`;
/// `error_out_of_host_memory` where `size` is too small for what was asked
/// for, nothing written past what fitted.
///
/// BEHAVIOR:
/// A statistics query writes one value for each statistic it counts, in the
/// order of their bits; the other kinds write one. Without
/// `QUERY_RESULT_64` a value is 4 bytes and one that will not fit is held
/// at 0xFFFFFFFF, where Vulkan leaves it undefined.
///
/// `QUERY_RESULT_WAIT` waits for the device's queue to go idle, which is
/// when everything recorded before has been played and every value is
/// written. Without it the answer is what is there: a query is available
/// once the command that ended it was played, and the pixels a pass shaded
/// are counted as its tiles are drawn, at the end of the pass - so a
/// program that reads values without waiting for the fence of the
/// submission that counted them may read a sum still being added to.
///
/// CONTEXT:
/// - Waits: with `QUERY_RESULT_WAIT`, for the queue.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `data` is the caller's.
///
/// NOTES:
/// `CmdCopyQueryPoolResults` writes the same values into a buffer as part
/// of a command buffer, which wants no wait at all.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateQueryPool`, `CmdEndQuery`, `CmdCopyQueryPoolResults`
///
/// EXAMPLES:
/// ```zig
/// var samples: u64 = 0;
/// _ = fb.GetQueryPoolResults(device, counted, 0, 1, @sizeOf(u64), &samples, @sizeOf(u64), facet.QUERY_RESULT_64 | facet.QUERY_RESULT_WAIT);
/// ```
pub fn GetQueryPoolResults(base: *FacetBase, device: *facet.Device, pool: *facet.QueryPool, first: u32, count: u32, size: usize, data: *anyopaque, stride: u64, flags: u32) facet.Result {
    const owner = _objects.of(Device, device);
    const made = _objects.of(Pool, pool);
    if (flags & facet.QUERY_RESULT_WAIT != 0 and owner.has_queue) {
        _queue.waitIdle(&owner.queue, base.sys_base);
    }
    if (owner.isLost()) return .error_device_lost;
    const bytes: [*]u8 = @ptrCast(data);
    return _query.write(made, first, count, bytes[0..size], stride, flags);
}

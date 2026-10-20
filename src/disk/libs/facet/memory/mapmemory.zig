// SPDX-License-Identifier: MIT
//! MapMemory: where a block of device memory is, for the program.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const DeviceMemory = @import("_memory.zig").DeviceMemory;

/// The address of a block's memory, from an offset on.
///
/// SYNOPSIS:
/// ```zig
/// fn MapMemory(base: *FacetBase, device: *facet.Device, memory: *facet.DeviceMemory, offset: u64, size: u64, flags: u32, data: *?*anyopaque) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `device` - the device it was allocated from.
/// - `memory` - the block.
/// - `offset` - where in it the mapping starts.
/// - `size` - how many bytes, or WHOLE_SIZE for all of it from `offset`.
/// - `flags` - 0.
/// - `data` - where the address of the byte at `offset` is written;
///   null when it fails.
///
/// RESULT:
/// `success`; `error_memory_map_failed` for lazily allocated memory, for
/// a block mapped already, and for a range past its end.
///
/// BEHAVIOR:
/// Mapping is handing out the address: the memory is the machine's RAM,
/// and what the program writes there the queue sees, and the other way
/// round, with nothing flushed (MEMORY_PROPERTY_HOST_COHERENT). The
/// address is aligned as the block is, to a cache line, plus `offset`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The address is good until UnmapMemory or FreeMemory.
///
/// NOTES:
/// What the queue is reading or writing still has to be waited for, with
/// a fence: the mapping is coherent, not synchronized.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnmapMemory`, `AllocateMemory`
///
/// EXAMPLES:
/// ```zig
/// var data: ?*anyopaque = null;
/// if (fb.MapMemory(device, memory, 0, facet.WHOLE_SIZE, 0, &data) != .success) return error.NoMap;
/// const vertices: [*]Vertex = @ptrCast(@alignCast(data.?));
/// ```
pub fn MapMemory(base: *FacetBase, device: *facet.Device, memory: *facet.DeviceMemory, offset: u64, size: u64, flags: u32, data: *?*anyopaque) facet.Result {
    _ = base;
    _ = device;
    _ = flags;
    data.* = null;
    const made = _objects.of(DeviceMemory, memory);
    const start = made.data orelse return .error_memory_map_failed;
    if (made.mapped or offset >= made.size) return .error_memory_map_failed;
    if (size != facet.WHOLE_SIZE and (size == 0 or size > made.size - offset)) return .error_memory_map_failed;
    made.mapped = true;
    data.* = start + @as(usize, @intCast(offset));
    return .success;
}

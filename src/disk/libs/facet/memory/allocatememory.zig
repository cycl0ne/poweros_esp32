// SPDX-License-Identifier: MIT
//! AllocateMemory: a block of the device's memory.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _memory = @import("_memory.zig");
const DeviceMemory = _memory.DeviceMemory;

/// A block of the device's memory, of one of its memory types.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocateMemory(base: *FacetBase, device: *facet.Device, info: *const facet.MemoryAllocateInfo, memory: *?*facet.DeviceMemory) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - how many bytes, and of which memory type.
/// - `memory` - where the block is written; null when it fails.
///
/// RESULT:
/// `success`; `error_out_of_device_memory` when no region with the
/// type's attributes has room, for no bytes, and for a type the device
/// has not got; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The memory is exec's (AllocMem, with the attributes of the type's
/// heap), aligned to a cache line and not cleared. Memory of the lazily
/// allocated type takes nothing: it is for an attachment whose pixels
/// stay in the tiles, and cannot be mapped.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: exec's memory list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The block is the caller's, until FreeMemory. It is the calling task's
/// memory as exec's tools show it, and not private: the queue's task
/// reads and writes it.
///
/// NOTES:
/// A few large blocks with many buffers and images bound into each cost
/// less than a block for each.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeMemory`, `MapMemory`, `GetPhysicalDeviceMemoryProperties`
///
/// EXAMPLES:
/// ```zig
/// var memory: ?*facet.DeviceMemory = null;
/// const info = facet.MemoryAllocateInfo{ .allocation_size = 1 << 20, .memory_type_index = 0 };
/// if (fb.AllocateMemory(device, &info, &memory) != .success) return error.NoMemory;
/// defer fb.FreeMemory(device, memory);
/// ```
pub fn AllocateMemory(base: *FacetBase, device: *facet.Device, info: *const facet.MemoryAllocateInfo, memory: *?*facet.DeviceMemory) facet.Result {
    memory.* = null;
    const owner = _objects.of(Device, device);
    const properties = &owner.physical.memory;
    const index = info.memory_type_index;
    if (index >= properties.memory_type_count or info.allocation_size == 0) return .error_out_of_device_memory;
    const sys = base.sys_base;
    const made = _objects.create(sys, DeviceMemory) orelse return .error_out_of_host_memory;
    made.* = .{ .device = owner, .size = info.allocation_size, .type_index = index };
    if (!_memory.isLazy(properties, index)) {
        const result = owner.physical.ops.allocate_memory(owner, made);
        if (result != .success) {
            _objects.destroy(sys, made);
            return result;
        }
    }
    owner.allocations += 1;
    memory.* = _objects.handle(facet.DeviceMemory, made);
    return .success;
}

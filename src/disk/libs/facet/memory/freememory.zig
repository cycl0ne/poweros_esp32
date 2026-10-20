// SPDX-License-Identifier: MIT
//! FreeMemory: a block of device memory given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const DeviceMemory = @import("_memory.zig").DeviceMemory;

/// The block given back.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeMemory(base: *FacetBase, device: *facet.Device, memory: ?*facet.DeviceMemory) void
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `device` - the device it was allocated from.
/// - `memory` - the block, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A mapping of it ends with it. Nothing bound into it may be in use by
/// work the queue has not finished: wait for its fence first.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: exec's memory list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The block is gone. The buffers and images bound into it stay, and may
/// only be destroyed.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocateMemory`
///
/// EXAMPLES:
/// ```zig
/// fb.FreeMemory(device, memory);
/// ```
pub fn FreeMemory(base: *FacetBase, device: *facet.Device, memory: ?*facet.DeviceMemory) void {
    const made = _objects.of(DeviceMemory, memory orelse return);
    const sys = base.sys_base;
    if (made.block) |block| sys.FreeMem(block, made.block_bytes);
    _objects.of(Device, device).allocations -= 1;
    _objects.destroy(sys, made);
}

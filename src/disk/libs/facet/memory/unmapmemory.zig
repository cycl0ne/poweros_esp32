// SPDX-License-Identifier: MIT
//! UnmapMemory: a mapping ended.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const DeviceMemory = @import("_memory.zig").DeviceMemory;

/// The block's mapping ended.
///
/// SYNOPSIS:
/// ```zig
/// fn UnmapMemory(base: *FacetBase, device: *facet.Device, memory: *facet.DeviceMemory) void
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `device` - the device it was allocated from.
/// - `memory` - a block MapMemory mapped.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The address MapMemory gave is no longer the program's to use; the
/// block may be mapped again. Nothing is flushed: nothing needs to be.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The block stays the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MapMemory`
///
/// EXAMPLES:
/// ```zig
/// fb.UnmapMemory(device, memory);
/// ```
pub fn UnmapMemory(base: *FacetBase, device: *facet.Device, memory: *facet.DeviceMemory) void {
    _ = base;
    _ = device;
    _objects.of(DeviceMemory, memory).mapped = false;
}

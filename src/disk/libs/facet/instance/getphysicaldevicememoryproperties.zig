// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceMemoryProperties: the kinds of memory a device has.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const PhysicalDevice = @import("_instance.zig").PhysicalDevice;

/// The physical device's memory types and heaps.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPhysicalDeviceMemoryProperties(base: *FacetBase, physical: *facet.PhysicalDevice, properties: *facet.PhysicalDeviceMemoryProperties) void
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `physical` - a physical device EnumeratePhysicalDevices listed.
/// - `properties` - where they are written.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The heaps are made from exec's memory regions as the instance was
/// made, in the order exec prefers them: each set of MEMF_INTERNAL,
/// MEMF_EXTERNAL and MEMF_DMA that a region has is a heap, as large as
/// its regions together, its attributes in `MemoryHeap.attributes`, with
/// a memory type of its own in the same place. Every one of those types
/// is DEVICE_LOCAL, HOST_VISIBLE and HOST_COHERENT - the device is the
/// processor - and HOST_CACHED where its regions are behind the data
/// cache (MEMF_EXTERNAL), MEMORY_PROPERTY_DMA where a DMA engine reaches
/// them (MEMF_DMA). The last type is DEVICE_LOCAL and LAZILY_ALLOCATED:
/// memory with nothing behind it, for an attachment that lives only in
/// the tiles, such as a depth a render pass clears and does not store.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `properties` is the caller's.
///
/// NOTES:
/// On a RISC-V 64 machine the RAM below 4 GiB is MEMF_DMA and the RAM
/// above it not, so RAM past 4 GiB is a heap of its own. An ESP32's
/// internal SRAM and its PSRAM are two heaps.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocateMemory`, `GetPhysicalDeviceProperties`
///
/// EXAMPLES:
/// ```zig
/// fn typeFor(memory: *const facet.PhysicalDeviceMemoryProperties, bits: u32, wanted: u32) ?u32 {
///     for (memory.memory_types[0..memory.memory_type_count], 0..) |kind, index| {
///         if (bits >> @intCast(index) & 1 != 0 and kind.property_flags & wanted == wanted) return @intCast(index);
///     }
///     return null;
/// }
/// ```
pub fn GetPhysicalDeviceMemoryProperties(base: *FacetBase, physical: *facet.PhysicalDevice, properties: *facet.PhysicalDeviceMemoryProperties) void {
    _ = base;
    properties.* = _objects.of(PhysicalDevice, physical).memory;
}

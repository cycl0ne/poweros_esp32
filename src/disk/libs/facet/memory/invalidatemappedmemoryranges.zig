// SPDX-License-Identifier: MIT
//! InvalidateMappedMemoryRanges: what the device wrote made the host's to
//! read through a mapping.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;

/// What the device wrote, in `ranges`, made the host's to read through its
/// mapping: nothing to do, every memory type being coherent.
///
/// SYNOPSIS:
/// ```zig
/// fn InvalidateMappedMemoryRanges(base: *FacetBase, device: *facet.Device, range_count: u32, ranges: [*]const facet.MappedMemoryRange) facet.Result
/// ```
///
/// SINCE: 1.123. LVO -532.
///
/// INPUTS:
/// - `device` - the device the blocks were allocated from.
/// - `range_count`, `ranges` - the ranges, each of a block mapped now:
///   `size` bytes from `offset`, which counts from the block's start, or
///   to the end of the mapping for `WHOLE_SIZE`.
///
/// RESULT:
/// `success`.
///
/// BEHAVIOR:
/// Every memory type that can be mapped is `MEMORY_PROPERTY_HOST_COHERENT`
/// on either device, so what the device wrote is the host's to read
/// through a mapping once the submission that wrote it is done - its fence
/// signalled, or `QueueWaitIdle` back - with nothing in between. Vulkan has
/// the call all the same, for a type that is not coherent, and a program
/// written for one calls it; it is lavapipe's and v3dv's, which answer
/// `success` and look at nothing (`lvp_InvalidateMappedMemoryRanges`,
/// lvp_device.c:2398-2404; `v3dv_InvalidateMappedMemoryRanges`,
/// v3dv_device.c:2732-2738). A range outside its block's mapping, or not
/// rounded to `PhysicalDeviceLimits.non_coherent_atom_size`, is the
/// program's mistake (VUID-VkMappedMemoryRange-size-00685,
/// VUID-VkMappedMemoryRange-offset-00687) and is not looked for either.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The ranges stay the caller's, and are not read.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FlushMappedMemoryRanges`, `MapMemory`
///
/// EXAMPLES:
/// ```zig
/// const range = facet.MappedMemoryRange{ .memory = memory };
/// _ = fb.InvalidateMappedMemoryRanges(device, 1, @ptrCast(&range));
/// ```
pub fn InvalidateMappedMemoryRanges(base: *FacetBase, device: *facet.Device, range_count: u32, ranges: [*]const facet.MappedMemoryRange) facet.Result {
    _ = base;
    _ = device;
    _ = range_count;
    _ = ranges;
    return .success;
}

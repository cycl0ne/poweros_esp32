// SPDX-License-Identifier: MIT
//! GetDeviceMemoryCommitment: the bytes of a block that are really there.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const DeviceMemory = @import("_memory.zig").DeviceMemory;

/// How many bytes of a block the device has really put behind it.
///
/// SYNOPSIS:
/// ```zig
/// fn GetDeviceMemoryCommitment(base: *FacetBase, device: *facet.Device, memory: *facet.DeviceMemory, bytes: *u64) void
/// ```
///
/// SINCE: 1.36. LVO -512.
///
/// INPUTS:
/// - `device` - the device the block was allocated on.
/// - `memory` - a block AllocateMemory gave.
/// - `bytes` - where the answer is written.
///
/// BEHAVIOR:
/// A block of the lazily allocated type has nothing behind it at all, so
/// 0 is its answer however much was asked for: the transient attachments
/// bound into it live in the device's tiles and never in memory. Every
/// other block is whole from the moment it is allocated, so its answer is
/// its `allocation_size`, as AllocateMemory was given it.
///
/// RESULT:
/// None.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `bytes` is the caller's.
///
/// NOTES:
/// Vulkan asks this of lazily allocated memory alone, and leaves the rest
/// undefined; here every block answers.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocateMemory`, `GetPhysicalDeviceMemoryProperties`, `CreateImage`
///
/// EXAMPLES:
/// ```zig
/// var bytes: u64 = 0;
/// fb.GetDeviceMemoryCommitment(device, block.?, &bytes);
/// // 0 for the lazily allocated type: nothing is behind it.
/// ```
pub fn GetDeviceMemoryCommitment(base: *FacetBase, device: *facet.Device, memory: *facet.DeviceMemory, bytes: *u64) void {
    _ = base;
    _ = device;
    const block = _objects.of(DeviceMemory, memory);
    bytes.* = if (block.block == null) 0 else block.size;
}

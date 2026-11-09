// SPDX-License-Identifier: MIT
//! BindBufferMemory: a buffer given its memory.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _buffer = @import("_buffer.zig");
const _memory = @import("../memory/_memory.zig");

/// The buffer bound into a block of memory, at an offset.
///
/// SYNOPSIS:
/// ```zig
/// fn BindBufferMemory(base: *FacetBase, device: *facet.Device, buffer: *facet.Buffer, memory: *facet.DeviceMemory, offset: u64) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -88.
///
/// INPUTS:
/// - `device` - the device both are of.
/// - `buffer` - a buffer not yet bound.
/// - `memory` - the block.
/// - `offset` - where in it the buffer starts.
///
/// RESULT:
/// `success`; `error_validation_failed` when the buffer does not fit
/// there - past the block's end, the offset not aligned as
/// GetBufferMemoryRequirements says, or a type the buffer may not be in -
/// or it is bound already (VUID-vkBindBufferMemory-memoryOffset-01031,
/// -None-10741, -None-10739, -memory-01035, -buffer-07459;
/// `error_out_of_device_memory` until 1.134).
///
/// BEHAVIOR:
/// The buffer's bytes are the block's from `offset` on, for as long as
/// both last; what the program writes there through MapMemory is what the
/// queue reads.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The block stays the caller's to free, after the buffer is no longer in
/// use.
///
/// NOTES:
/// Several buffers may be bound into one block side by side.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBufferMemoryRequirements`, `AllocateMemory`
///
/// EXAMPLES:
/// ```zig
/// if (fb.BindBufferMemory(device, vertices, memory, 0) != .success) return error.NoBind;
/// ```
pub fn BindBufferMemory(base: *FacetBase, device: *facet.Device, buffer: *facet.Buffer, memory: *facet.DeviceMemory, offset: u64) facet.Result {
    _ = base;
    _ = device;
    const made = _objects.of(_buffer.Buffer, buffer);
    const block = _objects.of(_memory.DeviceMemory, memory);
    // Each of these breaks one of Vulkan's rules: no memory has run out
    // (VUID-vkBindBufferMemory-buffer-07459, -memoryOffset-01031,
    // -memory-01035, -None-10739, -None-10741; since 1.134).
    if (made.memory != null or !_memory.suits(block, offset, _buffer.requirements(made))) return .error_validation_failed;
    made.memory = block;
    made.offset = offset;
    made.data = _memory.at(block, offset);
    return .success;
}

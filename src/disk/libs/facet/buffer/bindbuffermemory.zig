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
/// `success`; `error_out_of_device_memory` when the buffer does not fit
/// there - past the block's end, the offset not aligned as
/// GetBufferMemoryRequirements says, or a type the buffer may not be in -
/// or it is bound already.
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
    if (made.memory != null or !_memory.suits(block, offset, _buffer.requirements(made))) return .error_out_of_device_memory;
    made.memory = block;
    made.offset = offset;
    made.data = _memory.at(block, offset);
    return .success;
}

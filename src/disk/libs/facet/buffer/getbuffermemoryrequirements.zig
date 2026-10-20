// SPDX-License-Identifier: MIT
//! GetBufferMemoryRequirements: what a buffer needs of its memory.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _buffer = @import("_buffer.zig");

/// What the buffer needs of the memory it is bound into.
///
/// SYNOPSIS:
/// ```zig
/// fn GetBufferMemoryRequirements(base: *FacetBase, device: *facet.Device, buffer: *facet.Buffer, requirements: *facet.MemoryRequirements) void
/// ```
///
/// SINCE: 1.0. LVO -84.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `buffer` - the buffer.
/// - `requirements` - where they are written.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Its size rounded up to 16 bytes, an offset aligned to 16, and any
/// memory type with memory behind it: not the lazily allocated one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `requirements` is the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BindBufferMemory`, `AllocateMemory`
///
/// EXAMPLES:
/// ```zig
/// var needs: facet.MemoryRequirements = undefined;
/// fb.GetBufferMemoryRequirements(device, vertices, &needs);
/// ```
pub fn GetBufferMemoryRequirements(base: *FacetBase, device: *facet.Device, buffer: *facet.Buffer, requirements: *facet.MemoryRequirements) void {
    _ = base;
    _ = device;
    requirements.* = _buffer.requirements(_objects.of(_buffer.Buffer, buffer));
}

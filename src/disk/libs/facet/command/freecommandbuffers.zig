// SPDX-License-Identifier: MIT
//! FreeCommandBuffers: command buffers given back to their pool.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");

/// Command buffers given back to the pool they came from.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeCommandBuffers(base: *FacetBase, device: *facet.Device, pool: *facet.CommandPool, count: u32, buffers: [*]const ?*facet.CommandBuffer) void
/// ```
///
/// SINCE: 1.0. LVO -136.
///
/// INPUTS:
/// - `device` - the device.
/// - `pool` - the pool they were allocated from.
/// - `count` - how many.
/// - `buffers` - the buffers; a null among them is passed over.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// None of them may be pending. What they recorded goes with them.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffers are gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocateCommandBuffers`, `DestroyCommandPool`
///
/// EXAMPLES:
/// ```zig
/// fb.FreeCommandBuffers(device, pool.?, 1, &commands);
/// ```
pub fn FreeCommandBuffers(base: *FacetBase, device: *facet.Device, pool: *facet.CommandPool, count: u32, buffers: [*]const ?*facet.CommandBuffer) void {
    _ = device;
    const owner = _objects.of(_command.CommandPool, pool);
    const sys = base.sys_base;
    for (buffers[0..count]) |buffer| {
        const made = _objects.of(_command.CommandBuffer, buffer orelse continue);
        _command.unlink(owner, made);
        made.stream.free(sys);
        _objects.destroy(sys, made);
    }
}

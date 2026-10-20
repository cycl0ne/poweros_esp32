// SPDX-License-Identifier: MIT
//! DestroyCommandPool: a pool given back, with its command buffers.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");

/// The pool given back, and every command buffer allocated from it.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyCommandPool(base: *FacetBase, device: *facet.Device, pool: ?*facet.CommandPool) void
/// ```
///
/// SINCE: 1.0. LVO -124.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `pool` - the pool, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No buffer of it may be pending: wait for the fences of the work it was
/// submitted with first.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pool and its command buffers are gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateCommandPool`, `FreeCommandBuffers`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyCommandPool(device, pool);
/// ```
pub fn DestroyCommandPool(base: *FacetBase, device: *facet.Device, pool: ?*facet.CommandPool) void {
    _ = device;
    const made = _objects.of(_command.CommandPool, pool orelse return);
    const sys = base.sys_base;
    var buffer = made.first;
    while (buffer) |each| {
        buffer = each.next;
        each.stream.free(sys);
        _objects.destroy(sys, each);
    }
    _objects.destroy(sys, made);
}

// SPDX-License-Identifier: MIT
//! ResetCommandPool: every command buffer of a pool reset.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");

/// Every command buffer of the pool back to where it started.
///
/// SYNOPSIS:
/// ```zig
/// fn ResetCommandPool(base: *FacetBase, device: *facet.Device, pool: *facet.CommandPool, flags: u32) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -128.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `pool` - the pool.
/// - `flags` - COMMAND_BUFFER_RESET_RELEASE_RESOURCES to give back the
///   memory the recordings took, or 0 to keep it for the next.
///
/// RESULT:
/// `success`.
///
/// BEHAVIOR:
/// Each buffer is as it was allocated, nothing recorded in it. None may
/// be pending.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffers stay the pool's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ResetCommandBuffer`, `CreateCommandPool`
///
/// EXAMPLES:
/// ```zig
/// _ = fb.ResetCommandPool(device, pool, 0);
/// ```
pub fn ResetCommandPool(base: *FacetBase, device: *facet.Device, pool: *facet.CommandPool, flags: u32) facet.Result {
    _ = base;
    _ = device;
    const release = flags & facet.COMMAND_BUFFER_RESET_RELEASE_RESOURCES != 0;
    var buffer = _objects.of(_command.CommandPool, pool).first;
    while (buffer) |each| : (buffer = each.next) _command.clear(each, release);
    return .success;
}

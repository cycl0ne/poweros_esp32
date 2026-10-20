// SPDX-License-Identifier: MIT
//! ResetCommandBuffer: a command buffer reset.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");

/// The command buffer back to where it started.
///
/// SYNOPSIS:
/// ```zig
/// fn ResetCommandBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, flags: u32) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -148.
///
/// INPUTS:
/// - `buffer` - a command buffer that is not pending.
/// - `flags` - COMMAND_BUFFER_RESET_RELEASE_RESOURCES to give back the
///   memory its recording took, or 0 to keep it for the next.
///
/// RESULT:
/// `success`.
///
/// BEHAVIOR:
/// Nothing is recorded in it, as when it was allocated.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer stays its pool's.
///
/// NOTES:
/// BeginCommandBuffer resets a buffer itself.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BeginCommandBuffer`, `ResetCommandPool`
///
/// EXAMPLES:
/// ```zig
/// _ = fb.ResetCommandBuffer(commands, 0);
/// ```
pub fn ResetCommandBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, flags: u32) facet.Result {
    _ = base;
    _command.clear(_objects.of(_command.CommandBuffer, buffer), flags & facet.COMMAND_BUFFER_RESET_RELEASE_RESOURCES != 0);
    return .success;
}

// SPDX-License-Identifier: MIT
//! BeginCommandBuffer: a recording begun.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");

/// The command buffer's recording begun.
///
/// SYNOPSIS:
/// ```zig
/// fn BeginCommandBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, info: *const facet.CommandBufferBeginInfo) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -140.
///
/// INPUTS:
/// - `buffer` - a command buffer that is not pending.
/// - `info` - how it is used: COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT for a
///   buffer submitted once.
///
/// RESULT:
/// `success`.
///
/// BEHAVIOR:
/// What it recorded before is gone, its memory kept for this recording.
/// The Cmd calls that follow record into it until EndCommandBuffer.
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
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EndCommandBuffer`, `ResetCommandBuffer`
///
/// EXAMPLES:
/// ```zig
/// _ = fb.BeginCommandBuffer(commands, &.{ .flags = facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT });
/// ```
pub fn BeginCommandBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, info: *const facet.CommandBufferBeginInfo) facet.Result {
    _ = base;
    const made = _objects.of(_command.CommandBuffer, buffer);
    _command.clear(made, false);
    made.state = .recording;
    made.one_time = info.flags & facet.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT != 0;
    return .success;
}

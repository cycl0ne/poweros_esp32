// SPDX-License-Identifier: MIT
//! EndCommandBuffer: a recording ended.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");

/// The command buffer's recording ended: it can be submitted.
///
/// SYNOPSIS:
/// ```zig
/// fn EndCommandBuffer(base: *FacetBase, buffer: *facet.CommandBuffer) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -144.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
///
/// RESULT:
/// `success`; `error_out_of_host_memory` when memory ran out for a command
/// while it recorded: it cannot be submitted, and is recorded again after
/// a reset; `error_initialization_failed` for a buffer not recording.
///
/// BEHAVIOR:
/// The buffer is executable: QueueSubmit plays it, as often as it is submitted.
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
/// `BeginCommandBuffer`, `QueueSubmit`
///
/// EXAMPLES:
/// ```zig
/// if (fb.EndCommandBuffer(commands) != .success) return error.NoRecording;
/// ```
pub fn EndCommandBuffer(base: *FacetBase, buffer: *facet.CommandBuffer) facet.Result {
    _ = base;
    const made = _objects.of(_command.CommandBuffer, buffer);
    if (made.state != .recording) return .error_initialization_failed;
    if (made.stream.failed) {
        made.state = .spent;
        return .error_out_of_host_memory;
    }
    made.state = .executable;
    return .success;
}

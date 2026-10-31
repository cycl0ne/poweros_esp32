// SPDX-License-Identifier: MIT
//! CmdExecuteCommands: secondary command buffers played.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const CommandBuffer = _command.CommandBuffer;

/// Recorded: secondary command buffers played, in the order given.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdExecuteCommands(base: *FacetBase, buffer: *facet.CommandBuffer, count: u32, secondaries: [*]const *facet.CommandBuffer) void
/// ```
///
/// SINCE: 1.17. LVO -412.
///
/// INPUTS:
/// - `buffer` - a primary command buffer recording.
/// - `count`, `secondaries` - command buffers allocated with
///   `CommandBufferLevel.secondary`, recorded and ended.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Their commands are played where this command stands, inside or outside
/// a render pass, into the pass that is begun there. In a secondary command
/// buffer it does nothing, nor does a buffer given that is primary or not
/// ended count: it is left out.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The secondaries have to last, and stay as they are, until the work recorded is done.
///
/// NOTES:
/// Vulkan leaves what a secondary finds bound undefined, and what the primary finds after it: here each goes on from what the last left. A program written for Vulkan binds what it uses, and that works.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocateCommandBuffers`, `BeginCommandBuffer`, `QueueSubmit`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdExecuteCommands(primary, 1, @ptrCast(&secondary));
/// ```
pub fn CmdExecuteCommands(base: *FacetBase, buffer: *facet.CommandBuffer, count: u32, secondaries: [*]const *facet.CommandBuffer) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    if (made.secondary) return;
    var kept: [32]*CommandBuffer = undefined;
    var at: u32 = 0;
    for (secondaries[0..count]) |given| {
        const secondary = _objects.of(CommandBuffer, given);
        if (!secondary.secondary or secondary.state != .executable) continue;
        kept[at] = secondary;
        at += 1;
        if (at == kept.len) {
            _command.record(made, _command.ExecuteCommands{ .count = at }, *CommandBuffer, kept[0..at]);
            at = 0;
        }
    }
    if (at != 0) _command.record(made, _command.ExecuteCommands{ .count = at }, *CommandBuffer, kept[0..at]);
}

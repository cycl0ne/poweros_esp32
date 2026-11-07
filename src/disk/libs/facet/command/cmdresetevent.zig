// SPDX-License-Identifier: MIT
//! CmdResetEvent: an event reset by a queue, the work before done.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Event = @import("../sync/_sync.zig").Event;

/// Recorded: the event reset once the work before it is done.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdResetEvent(base: *FacetBase, buffer: *facet.CommandBuffer, event: *facet.Event, stage_mask: u32) void
/// ```
///
/// SINCE: 1.129. LVO -572.
///
/// INPUTS:
/// - `buffer` - a command buffer recording, outside a render pass.
/// - `event` - the event.
/// - `stage_mask` - the stages whose work before it is done first
///   (PIPELINE_STAGE_*), PIPELINE_STAGE_HOST not among them.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Played, it resets the event, as lavapipe's queue does
/// (`handle_event_reset2`, lvp_execute.c:3414-3422), the queue having
/// done every command before it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The event is the caller's, and has to last until the work is done.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdSetEvent`, `ResetEvent`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdResetEvent(commands, uploaded.?, facet.PIPELINE_STAGE_TRANSFER);
/// ```
pub fn CmdResetEvent(base: *FacetBase, buffer: *facet.CommandBuffer, event: *facet.Event, stage_mask: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.ResetEvent{ .stage_mask = stage_mask, .event = _objects.of(Event, event) }, u8, &.{});
}

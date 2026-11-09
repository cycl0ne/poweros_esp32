// SPDX-License-Identifier: MIT
//! CmdSetEvent: an event set by a queue, the work before done.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Event = @import("../sync/_sync.zig").Event;

/// Recorded: the event set once the work before it is done.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdSetEvent(base: *FacetBase, buffer: *facet.CommandBuffer, event: *facet.Event, stage_mask: u32) void
/// ```
///
/// SINCE: 1.129. LVO -568.
///
/// INPUTS:
/// - `buffer` - a command buffer recording, outside a render pass.
/// - `event` - the event.
/// - `stage_mask` - the stages whose work before it is done first
///   (PIPELINE_STAGE_*).
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Played, it sets the event, as lavapipe's queue does
/// (`handle_event_set2`, lvp_execute.c:3401-3412): the queue has done
/// every command before it, in whatever stage, when it gets there. A
/// CmdWaitEvents after it in the queue's order finds the event set, and
/// GetEventStatus says so from then on.
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
/// `CmdResetEvent`, `CmdWaitEvents`, `GetEventStatus`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdCopyBuffer(commands, staging, vertices, 1, @ptrCast(&region));
/// fb.CmdSetEvent(commands, uploaded.?, facet.PIPELINE_STAGE_TRANSFER);
/// ```
pub fn CmdSetEvent(base: *FacetBase, buffer: *facet.CommandBuffer, event: *facet.Event, stage_mask: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.SetEvent{ .stage_mask = stage_mask, .event = _objects.of(Event, event) }, u8, &.{});
}

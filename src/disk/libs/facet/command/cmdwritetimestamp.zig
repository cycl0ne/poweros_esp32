// SPDX-License-Identifier: MIT
//! CmdWriteTimestamp: the clock as the command is played.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Pool = @import("../query/_query.zig").Pool;

/// Recorded: the clock written into query `query` of `pool` when the
/// command is played.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdWriteTimestamp(base: *FacetBase, buffer: *facet.CommandBuffer, stage: u32, pool: *facet.QueryPool, query: u32) void
/// ```
///
/// SINCE: 1.29. LVO -480.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `stage` - the `PIPELINE_STAGE_` the time is asked for at; every stage
///   is the same moment here, see below.
/// - `pool` - a timestamp pool; one of another kind is left out of the
///   frame and said to be in the log.
/// - `query` - which query of it.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The value is the E-clock in microseconds, which is what
/// `PhysicalDeviceLimits.timestamp_period_ns` of 1000 says; the query is
/// available from then on.
///
/// The commands of a buffer are played one after another, each finished
/// before the next starts - on the cores by the queue's task itself, on the
/// V3D by waiting for the frame's interrupts - so a timestamp is the moment
/// everything recorded before it was done, whatever `stage` asks for. Two
/// of them round a render pass measure that pass.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pool has to last until the work is done.
///
/// NOTES:
/// Without timer.device there is no clock to read:
/// `Capabilities.timestamp_queries` is false then and
/// CreateQueryPool refuses the kind, so this cannot be reached.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateQueryPool`, `GetQueryPoolResults`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdWriteTimestamp(commands, facet.PIPELINE_STAGE_TOP_OF_PIPE, times, 0);
/// fb.CmdBeginRenderPass(commands, &begin, .@"inline");
/// // ... the frame ...
/// fb.CmdEndRenderPass(commands);
/// fb.CmdWriteTimestamp(commands, facet.PIPELINE_STAGE_BOTTOM_OF_PIPE, times, 1);
/// ```
pub fn CmdWriteTimestamp(base: *FacetBase, buffer: *facet.CommandBuffer, stage: u32, pool: *facet.QueryPool, query: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.WriteTimestamp{
        .pool = _objects.of(Pool, pool),
        .query = query,
        .stage = stage,
    }, u8, &.{});
}

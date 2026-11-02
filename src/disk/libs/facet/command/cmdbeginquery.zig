// SPDX-License-Identifier: MIT
//! CmdBeginQuery: the query the work that follows is counted into.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Pool = @import("../query/_query.zig").Pool;

/// Recorded: query `query` of `pool` begun - what the draws and the
/// dispatches until `CmdEndQuery` come to is counted into it.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdBeginQuery(base: *FacetBase, buffer: *facet.CommandBuffer, pool: *facet.QueryPool, query: u32, flags: u32) void
/// ```
///
/// SINCE: 1.29. LVO -468.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `pool` - an occlusion or a statistics pool; a timestamp pool has
///   nothing to begin and the command is left out of the frame, said in
///   the log.
/// - `query` - which query of it; one past its last is left out the same
///   way.
/// - `flags` - `QUERY_CONTROL_PRECISE`, which changes nothing: every
///   sample is counted either way.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// An occlusion query counts the samples that passed the depth and the
/// stencil test and were not dropped by the fragment function; a statistics
/// query counts what each stage was given and handed on, one value for each
/// statistic the pool was made with.
///
/// What is counted is added to what the query holds, so a query begun and
/// ended twice over without a reset in between holds the sum. One begun
/// while another of the same pool is being counted into takes its place:
/// commands are played one after another, and the library counts into one
/// query at a time.
///
/// The pixels of a render pass are shaded when its tiles are drawn, at the
/// end of the pass: a query begun and ended inside a pass counts the draws
/// between them, and the count lands when the pass does.
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
/// Vulkan's rule that a query is reset before it is used holds here too:
/// a pool is made counting nothing, and `CmdResetQueryPool` puts it back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdEndQuery`, `CmdResetQueryPool`, `CreateQueryPool`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdBeginQuery(commands, counted, 0, 0);
/// fb.CmdDrawIndexed(commands, indices.len, 1, 0, 0, 0);
/// fb.CmdEndQuery(commands, counted, 0);
/// ```
pub fn CmdBeginQuery(base: *FacetBase, buffer: *facet.CommandBuffer, pool: *facet.QueryPool, query: u32, flags: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.BeginQuery{
        .pool = _objects.of(Pool, pool),
        .query = query,
        .flags = flags,
    }, u8, &.{});
}

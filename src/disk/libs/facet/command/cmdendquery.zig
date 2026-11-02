// SPDX-License-Identifier: MIT
//! CmdEndQuery: the query ended, and what it counted made available.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Pool = @import("../query/_query.zig").Pool;

/// Recorded: the query ended - nothing after it is counted into it - and
/// what it counted made available.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdEndQuery(base: *FacetBase, buffer: *facet.CommandBuffer, pool: *facet.QueryPool, query: u32) void
/// ```
///
/// SINCE: 1.29. LVO -472.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `pool`, `query` - the query `CmdBeginQuery` begun.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The query is available from then on, which is what
/// `GetQueryPoolResults` answers `success` for. Its value is whole once the
/// submission is done: the pixels a pass shaded are counted while its tiles
/// are drawn, which is after the command that ended the query if the query
/// was ended inside the pass.
///
/// An end without a begin, or of another query than the one being counted
/// into, makes the query available with what it holds.
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
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdBeginQuery`, `GetQueryPoolResults`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdEndQuery(commands, counted, 0);
/// ```
pub fn CmdEndQuery(base: *FacetBase, buffer: *facet.CommandBuffer, pool: *facet.QueryPool, query: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.EndQuery{ .pool = _objects.of(Pool, pool), .query = query }, u8, &.{});
}

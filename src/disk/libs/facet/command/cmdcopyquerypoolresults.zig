// SPDX-License-Identifier: MIT
//! CmdCopyQueryPoolResults: the queries' values written into a buffer.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Buffer = @import("../buffer/_buffer.zig").Buffer;
const Pool = @import("../query/_query.zig").Pool;

/// Recorded: what `count` queries from `first` counted, written into a
/// buffer as `GetQueryPoolResults` writes it into memory.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdCopyQueryPoolResults(base: *FacetBase, buffer: *facet.CommandBuffer, pool: *facet.QueryPool, first: u32, count: u32, destination: *facet.Buffer, offset: u64, stride: u64, flags: u32) void
/// ```
///
/// SINCE: 1.29. LVO -484.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `pool`, `first`, `count` - the queries read.
/// - `destination`, `offset` - the buffer written and where in it.
/// - `stride` - the bytes from one query's values to the next.
/// - `flags` - as `GetQueryPoolResults` takes them, `QUERY_RESULT_WAIT`
///   apart: the commands are played in order, so a query ended before this
///   one is already written.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Played, a copy whose values would lie past the end of the buffer is left
/// out and said to be in the log, as every command that will not fit is.
/// A query that is not available writes nothing unless `QUERY_RESULT_PARTIAL`
/// says to write what it has counted so far, and
/// `QUERY_RESULT_WITH_AVAILABILITY` puts a value after each query's saying
/// which it was.
///
/// `QUERY_RESULT_WAIT` is passed over: a value this command reads was
/// written by a command before it, which is finished by the time this one
/// is played.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pool and the buffer have to last until the work is done.
///
/// NOTES:
/// This is how a program keeps what a frame counted without waiting for it:
/// the values go into a buffer it reads when it pleases.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetQueryPoolResults`, `CmdEndQuery`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdCopyQueryPoolResults(commands, counted, 0, 1, readings, 0, 8, facet.QUERY_RESULT_64);
/// ```
pub fn CmdCopyQueryPoolResults(base: *FacetBase, buffer: *facet.CommandBuffer, pool: *facet.QueryPool, first: u32, count: u32, destination: *facet.Buffer, offset: u64, stride: u64, flags: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.CopyQueryResults{
        .pool = _objects.of(Pool, pool),
        .destination = _objects.of(Buffer, destination),
        .offset = offset,
        .stride = stride,
        .first = first,
        .count = count,
        .flags = flags,
    }, u8, &.{});
}

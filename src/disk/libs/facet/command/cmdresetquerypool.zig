// SPDX-License-Identifier: MIT
//! CmdResetQueryPool: queries set back to nothing counted.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Pool = @import("../query/_query.zig").Pool;

/// Recorded: `count` queries from `first` set back to nothing counted and
/// not available.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdResetQueryPool(base: *FacetBase, buffer: *facet.CommandBuffer, pool: *facet.QueryPool, first: u32, count: u32) void
/// ```
///
/// SINCE: 1.29. LVO -476.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `pool` - the pool.
/// - `first`, `count` - the queries reset; those past its last are left
///   alone.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Played in its turn, as every command is: a reset recorded before the
/// draws of a frame leaves the queries counting that frame alone, which is
/// how a frame loop reads one pool over and over.
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
/// A pool is made counting nothing, so the first frame needs no reset; the
/// ones after it do, and Vulkan asks for one before every use.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdBeginQuery`, `CreateQueryPool`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdResetQueryPool(commands, counted, 0, 1);
/// ```
pub fn CmdResetQueryPool(base: *FacetBase, buffer: *facet.CommandBuffer, pool: *facet.QueryPool, first: u32, count: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.ResetQueryPool{ .pool = _objects.of(Pool, pool), .first = first, .count = count }, u8, &.{});
}

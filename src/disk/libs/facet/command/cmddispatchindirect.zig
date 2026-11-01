// SPDX-License-Identifier: MIT
//! CmdDispatchIndirect: a compute function run, how often read from a buffer.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Buffer = @import("../buffer/_buffer.zig").Buffer;

/// Recorded: as CmdDispatch, its numbers in a buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdDispatchIndirect(base: *FacetBase, buffer: *facet.CommandBuffer, numbers: *facet.Buffer, offset: u64) void
/// ```
///
/// SINCE: 1.18. LVO -424.
///
/// INPUTS:
/// - `buffer` - a command buffer recording, outside a render pass.
/// - `numbers` - the buffer they are in, a `facet.DispatchIndirectCommand`.
/// - `offset` - where.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// As `CmdDispatch`, with the numbers read as the command is played. If the
/// buffer ends before them, it does nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `numbers` has to last until the work recorded is done.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdDispatch`, `CmdDrawIndirect`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdDispatchIndirect(commands, numbers, 0);
/// ```
pub fn CmdDispatchIndirect(base: *FacetBase, buffer: *facet.CommandBuffer, numbers: *facet.Buffer, offset: u64) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.DispatchIndirect{ .buffer = _objects.of(Buffer, numbers), .offset = offset }, u8, &.{});
}

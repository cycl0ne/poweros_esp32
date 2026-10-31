// SPDX-License-Identifier: MIT
//! CmdDrawIndexedIndirect: draws whose numbers are in a buffer.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Buffer = @import("../buffer/_buffer.zig").Buffer;

/// Recorded: draws whose numbers, as CmdDrawIndexed takes them, are in a buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdDrawIndexedIndirect(base: *FacetBase, buffer: *facet.CommandBuffer, numbers: *facet.Buffer, offset: u64, draw_count: u32, stride: u32) void
/// ```
///
/// SINCE: 1.17. LVO -408.
///
/// INPUTS:
/// - `buffer` - a command buffer recording, in a render pass.
/// - `numbers` - the buffer they are in.
/// - `offset` - where the first draw's are.
/// - `draw_count` - how many draws.
/// - `stride` - the bytes from one draw's to the next: `facet.DrawIndexedIndirectCommand`'s at
///   least, unless there is one draw at most.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The numbers are read as the command is played, not as it is recorded, so
/// a program may write them after recording, up to the submission, and a
/// compute function played before it may too. Each draw is as `CmdDrawIndexed` with
/// those numbers. The draws past the end of the buffer are left out, and with
/// a `stride` too small nothing is recorded.
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
/// The cores read the numbers, whichever device draws.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdDrawIndexed`, `CmdDispatchIndirect`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdDrawIndexedIndirect(commands, numbers, 0, 2, @sizeOf(facet.DrawIndexedIndirectCommand));
/// ```
pub fn CmdDrawIndexedIndirect(base: *FacetBase, buffer: *facet.CommandBuffer, numbers: *facet.Buffer, offset: u64, draw_count: u32, stride: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    if (draw_count == 0 or (draw_count > 1 and stride < @sizeOf(facet.DrawIndexedIndirectCommand))) return;
    _command.record(made, _command.DrawIndirect{ .buffer = _objects.of(Buffer, numbers), .offset = offset, .count = draw_count, .stride = stride, .indexed = true }, u8, &.{});
}

// SPDX-License-Identifier: MIT
//! CmdFillBuffer: a run of a buffer set to one value.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Buffer = @import("../buffer/_buffer.zig").Buffer;

/// Recorded: a run of a buffer set to one value, four bytes at a time.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdFillBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, destination: *facet.Buffer, offset: u64, size: u64, data: u32) void
/// ```
///
/// SINCE: 1.27. LVO -436.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `destination` - the buffer written.
/// - `offset` - where the run starts, a multiple of four.
/// - `size` - how many bytes, a multiple of four, or `facet.WHOLE_SIZE`
///   for the rest of the buffer from `offset`.
/// - `data` - the four bytes written over and over, as they lie in memory:
///   the low byte first.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Played, a run that lies past the end of the buffer is left out and said
/// to be in the log. An `offset` or a `size` that is not a multiple of four
/// is rounded down to one, as Vulkan asks of the program instead.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer has to last until the work is done.
///
/// NOTES:
/// What `CmdUpdateBuffer` is for one run of bytes, this is for one value
/// repeated: neither wants a staging buffer, a map or a submit of its own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdUpdateBuffer`, `CmdCopyBuffer`, `CmdClearColorImage`
///
/// EXAMPLES:
/// ```zig
/// // Every index zeroed before the real ones are written.
/// fb.CmdFillBuffer(commands, indices.?, 0, facet.WHOLE_SIZE, 0);
/// ```
pub fn CmdFillBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, destination: *facet.Buffer, offset: u64, size: u64, data: u32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    const command = _command.FillBuffer{
        .destination = _objects.of(Buffer, destination),
        .offset = offset & ~@as(u64, 3),
        .size = if (size == facet.WHOLE_SIZE) size else size & ~@as(u64, 3),
        .data = data,
    };
    _command.record(made, command, u8, &.{});
}

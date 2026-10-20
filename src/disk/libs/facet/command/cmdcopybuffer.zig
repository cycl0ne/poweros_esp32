// SPDX-License-Identifier: MIT
//! CmdCopyBuffer: bytes copied from one buffer to another.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Buffer = @import("../buffer/_buffer.zig").Buffer;

/// Recorded: bytes copied from one buffer to another.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdCopyBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Buffer, destination: *facet.Buffer, region_count: u32, regions: [*]const facet.BufferCopy) void
/// ```
///
/// SINCE: 1.0. LVO -160.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `source` - the buffer copied from.
/// - `destination` - the buffer copied into.
/// - `region_count`, `regions` - where in each, and how many bytes.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Played, a region that lies past the end of either buffer is left out.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The regions are copied as the command is recorded. The buffers have to
/// last until the work is done.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdCopyBufferToImage`
///
/// EXAMPLES:
/// ```zig
/// const region = facet.BufferCopy{ .size = bytes };
/// fb.CmdCopyBuffer(commands, staging.?, vertices.?, 1, @ptrCast(&region));
/// ```
pub fn CmdCopyBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Buffer, destination: *facet.Buffer, region_count: u32, regions: [*]const facet.BufferCopy) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    const command = _command.CopyBuffer{ .count = region_count, .source = _objects.of(Buffer, source), .destination = _objects.of(Buffer, destination) };
    _command.record(made, command, facet.BufferCopy, regions[0..region_count]);
}

// SPDX-License-Identifier: MIT
//! CmdCopyBufferToImage: texels copied from a buffer into an image.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Buffer = @import("../buffer/_buffer.zig").Buffer;
const Image = @import("../image/_image.zig").Image;

/// Recorded: rectangles of texels copied from a buffer into an image.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdCopyBufferToImage(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Buffer, image: *facet.Image, layout: facet.ImageLayout, region_count: u32, regions: [*]const facet.BufferImageCopy) void
/// ```
///
/// SINCE: 1.0. LVO -156.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `source` - the buffer the texels are in, in rows, in the image's
///   format.
/// - `image` - the image they go into: a texture, or rows.
/// - `layout` - the image's layout: TRANSFER_DST_OPTIMAL or GENERAL.
/// - `region_count`, `regions` - the rectangles: where each is in the
///   buffer, and which level of the image and where in it.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Played, each texel goes where the image keeps it: in a texture,
/// converted to its layout - into blocks, an 8888 texel spread, an R8G8B8A8
/// one put in the order the rasterizer keeps colours in - and in rows,
/// copied as it is. What lies outside the level, or past the end of the
/// buffer, is left out. A depth attachment takes nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The regions are copied as the command is recorded. The buffer and the
/// image have to last until the work is done.
///
/// NOTES:
/// Each level of a texture is a copy of its own: the library makes no levels.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdPipelineBarrier`, `CreateImage`
///
/// EXAMPLES:
/// ```zig
/// const region = facet.BufferImageCopy{ .image_extent = .{ .width = 256, .height = 256 } };
/// fb.CmdCopyBufferToImage(commands, staging.?, picture.?, .transfer_dst_optimal, 1, @ptrCast(&region));
/// ```
pub fn CmdCopyBufferToImage(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Buffer, image: *facet.Image, layout: facet.ImageLayout, region_count: u32, regions: [*]const facet.BufferImageCopy) void {
    _ = base;
    _ = layout;
    const made = _command.recording(buffer) orelse return;
    const command = _command.CopyBufferToImage{ .count = region_count, .source = _objects.of(Buffer, source), .image = _objects.of(Image, image) };
    _command.record(made, command, facet.BufferImageCopy, regions[0..region_count]);
}

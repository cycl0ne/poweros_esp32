// SPDX-License-Identifier: MIT
//! CmdCopyImageToBuffer: a rectangle of texels copied from an image to a buffer.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Image = @import("../image/_image.zig").Image;
const Buffer = @import("../buffer/_buffer.zig").Buffer;

/// Recorded: a rectangle of texels copied from an image to a buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdCopyImageToBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, image: *facet.Image, image_layout: facet.ImageLayout, destination: *facet.Buffer, region_count: u32, regions: [*]const facet.BufferImageCopy) void
/// ```
///
/// SINCE: 1.16. LVO -396.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `image` - an image of colour.
/// - `image_layout` - not looked at.
/// - `destination` - the buffer.
/// - `region_count`, `regions` - the rectangles.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Outside a render pass. In the buffer the texels are in rows, in the image's
/// format. The part of a rectangle outside the image, or past the buffer's
/// end, is left out.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// What is given is copied as the command is recorded; the images and buffers
/// have to last until it has been played.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdCopyBufferToImage`, `CmdCopyImage`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdCopyImageToBuffer(commands, picture.?, .general, readback.?, 1, @ptrCast(&region));
/// ```
pub fn CmdCopyImageToBuffer(base: *FacetBase, buffer: *facet.CommandBuffer, image: *facet.Image, image_layout: facet.ImageLayout, destination: *facet.Buffer, region_count: u32, regions: [*]const facet.BufferImageCopy) void {
    _ = base;
    _ = image_layout;
    const made = _command.recording(buffer) orelse return;
    const command = _command.CopyImageToBuffer{ .count = region_count, .image = _objects.of(Image, image), .destination = _objects.of(Buffer, destination) };
    _command.record(made, command, facet.BufferImageCopy, regions[0..region_count]);
}

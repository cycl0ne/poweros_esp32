// SPDX-License-Identifier: MIT
//! CmdCopyImage: a rectangle of texels copied from one image to another, as they are.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Image = @import("../image/_image.zig").Image;

/// Recorded: a rectangle of texels copied from one image to another, as they are.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdCopyImage(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Image, source_layout: facet.ImageLayout, destination: *facet.Image, destination_layout: facet.ImageLayout, region_count: u32, regions: [*]const facet.ImageCopy) void
/// ```
///
/// SINCE: 1.16. LVO -388.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `source`, `destination` - images of the same size of texel, whatever their
///   formats: the bytes go as they are.
/// - `source_layout`, `destination_layout` - not looked at.
/// - `region_count`, `regions` - the rectangles.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Outside a render pass. The part of a rectangle outside either image is
/// left out, and so are images of depth or stencil, which live in the tiles.
///
/// Two images that keep their blocks, of the one format, are copied block by
/// block (`PhysicalDeviceFeatures.kept_compressed`, since 1.44), their
/// offsets on a multiple of 4; a compressed image and an uncompressed one,
/// either way round, take nothing.
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
/// `CmdBlitImage`, `CmdCopyImageToBuffer`, `CmdCopyBufferToImage`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdCopyImage(commands, from.?, .general, to.?, .general, 1, @ptrCast(&facet.ImageCopy{ .extent = .{ .width = 64, .height = 64 } }));
/// ```
pub fn CmdCopyImage(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Image, source_layout: facet.ImageLayout, destination: *facet.Image, destination_layout: facet.ImageLayout, region_count: u32, regions: [*]const facet.ImageCopy) void {
    _ = base;
    _ = source_layout;
    _ = destination_layout;
    const made = _command.recording(buffer) orelse return;
    const command = _command.CopyImage{ .count = region_count, .source = _objects.of(Image, source), .destination = _objects.of(Image, destination) };
    _command.record(made, command, facet.ImageCopy, regions[0..region_count]);
}

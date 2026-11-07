// SPDX-License-Identifier: MIT
//! CmdResolveImage: the samples of a multisampled image averaged into an
//! image of one sample a pixel.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Image = @import("../image/_image.zig").Image;

/// Recorded: the samples of a multisampled image averaged into an image of
/// one sample, rectangle by rectangle.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdResolveImage(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Image, source_layout: facet.ImageLayout, destination: *facet.Image, destination_layout: facet.ImageLayout, region_count: u32, regions: [*]const facet.ImageResolve) void
/// ```
///
/// SINCE: 1.101. LVO -524.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `source` - an image of four samples a pixel.
/// - `destination` - an image of one sample, of the source's format.
/// - `source_layout`, `destination_layout` - not looked at.
/// - `region_count`, `regions` - the rectangles, and the layers of each.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Outside a render pass. Each pixel of a rectangle of the destination is
/// the average of the source's samples at the same place in its rectangle:
/// for each channel, the samples' sum over their count, rounded to the
/// nearest, as Mesa's resolve averages them. What falls outside either
/// image is left out. A source not of four samples, a destination of more
/// than one, or two formats, none of which Vulkan has a program give,
/// resolve nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// What is given is copied as the command is recorded; the images have to
/// last until it has been played.
///
/// NOTES:
/// Only a device that draws four samples makes an image of them
/// (`Capabilities.multisampling`): the cores since 1.112, and the V3D
/// not yet (docs/facet-vulkan10.md item 61, V5).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdCopyImage`, `CmdBlitImage`, `CreateRenderPass`
///
/// EXAMPLES:
/// ```zig
/// const region = facet.ImageResolve{ .extent = .{ .width = 800, .height = 600, .depth = 1 } };
/// fb.CmdResolveImage(commands, drawn.?, .transfer_src_optimal, shown.?, .transfer_dst_optimal, 1, @ptrCast(&region));
/// ```
pub fn CmdResolveImage(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Image, source_layout: facet.ImageLayout, destination: *facet.Image, destination_layout: facet.ImageLayout, region_count: u32, regions: [*]const facet.ImageResolve) void {
    _ = base;
    _ = source_layout;
    _ = destination_layout;
    const made = _command.recording(buffer) orelse return;
    const command = _command.ResolveImage{ .count = region_count, .source = _objects.of(Image, source), .destination = _objects.of(Image, destination) };
    _command.record(made, command, facet.ImageResolve, regions[0..region_count]);
}

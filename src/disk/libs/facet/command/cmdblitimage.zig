// SPDX-License-Identifier: MIT
//! CmdBlitImage: a rectangle of an image drawn over one of another, scaled.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const Image = @import("../image/_image.zig").Image;

/// Recorded: a rectangle of an image drawn over one of another, scaled.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdBlitImage(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Image, source_layout: facet.ImageLayout, destination: *facet.Image, destination_layout: facet.ImageLayout, region_count: u32, regions: [*]const facet.ImageBlit, filter: facet.Filter) void
/// ```
///
/// SINCE: 1.16. LVO -392.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `source`, `destination` - images of formats whose features say
///   BLIT_SRC and BLIT_DST (GetPhysicalDeviceFormatProperties, since
///   1.126): of colour, or both of D16_UNORM.
/// - `source_layout`, `destination_layout` - not looked at.
/// - `region_count`, `regions` - the rectangles: corners the other way round
///   turn it round.
/// - `filter` - NEAREST or LINEAR.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Outside a render pass. Colours go by way of 8 bits a channel, and are
/// rounded into the destination's format, not dithered. What falls outside
/// the destination is left out, and the source's edge is read beyond it.
///
/// A source kept in its blocks is read out of them, texel by texel (since
/// 1.44), and one kept as floats, or as channels of 16 bits, is read as a
/// sample reads it, each channel held to 0 to 1 and rounded to 8 bits:
/// since 1.126, where before a float one read as nothing and one of 8
/// bytes a texel as what lay past its first 4. Nothing here compresses or
/// makes floats, so a destination that keeps what it was given takes
/// nothing, as Vulkan does not allow a compressed one either.
///
/// A depth goes into an image of its own format, D16_UNORM, without a
/// filter, as Vulkan has it (VUID-vkCmdBlitImage-srcImage-00231, -00232):
/// each pixel takes the nearest one's depth as it lies (since 1.126). An
/// image with a stencil takes nothing.
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
/// `CmdCopyImage`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdBlitImage(commands, from.?, .general, to.?, .general, 1, @ptrCast(&region), .linear);
/// ```
pub fn CmdBlitImage(base: *FacetBase, buffer: *facet.CommandBuffer, source: *facet.Image, source_layout: facet.ImageLayout, destination: *facet.Image, destination_layout: facet.ImageLayout, region_count: u32, regions: [*]const facet.ImageBlit, filter: facet.Filter) void {
    _ = base;
    _ = source_layout;
    _ = destination_layout;
    const made = _command.recording(buffer) orelse return;
    const command = _command.BlitImage{ .count = region_count, .filter = filter, .source = _objects.of(Image, source), .destination = _objects.of(Image, destination) };
    _command.record(made, command, facet.ImageBlit, regions[0..region_count]);
}

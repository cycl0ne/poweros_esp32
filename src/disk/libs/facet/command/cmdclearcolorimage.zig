// SPDX-License-Identifier: MIT
//! CmdClearColorImage: an image's levels and layers set to a colour,
//! outside a render pass.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const _render = @import("../render/_render.zig");
const Image = @import("../image/_image.zig").Image;

/// Recorded: an image's levels and layers set to a colour.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdClearColorImage(base: *FacetBase, buffer: *facet.CommandBuffer, image: *facet.Image, layout: facet.ImageLayout, color: *const facet.ClearColorValue, range_count: u32, ranges: [*]const facet.ImageSubresourceRange) void
/// ```
///
/// SINCE: 1.27. LVO -444.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `image` - the image cleared, which is not an attachment of the pass
///   being recorded: this is a transfer, not a draw.
/// - `layout` - what the image is in, which this library does not act on.
/// - `color` - the colour, as `float32`: 0 to 1 a channel for a format of
///   bytes, and since 1.61 whatever it says for a float one. An image of
///   whole numbers reads `uint32` instead, or `int32` where its format is
///   signed, as Vulkan has it (since 1.70).
/// - `range_count`, `ranges` - which levels and layers, by
///   `base_mip_level`, `level_count`, `base_array_layer` and `layer_count`;
///   `facet.REMAINING`, which both counts default to, reaches to the end.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Every texel of each level and layer named is set to the colour. A level
/// or a layer the image does not have is left out. An image whose format
/// this cannot write a single texel of is left out and said to be in the
/// log: a compressed one, whose texels are written as whole blocks and
/// which nothing here compresses, and a depth one, which
/// `CmdClearDepthStencilImage` writes instead.
///
/// **A float image takes the channels as they were given** since 1.61
/// (`PhysicalDeviceFeatures.kept_floats`): the four floats are put into
/// the format's own texel the way a copy of one would be, so a channel
/// above 1 or below 0 goes in as far as the format reaches instead of
/// being rounded to a byte. Before 1.61 such an image was the one this
/// could not write and was left alone.
///
/// Whole levels are written, so the clear does not care how a level's
/// texels are laid out in memory: every one of them takes the same value.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The ranges are copied as the command is recorded. The image has to last
/// until the work is done.
///
/// NOTES:
/// This is how a texture is cleared without a render pass over it, which
/// before wanted an attachment, a framebuffer and a pass of its own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdClearAttachments` for an attachment of the pass being drawn,
/// `CmdFillBuffer`
///
/// EXAMPLES:
/// ```zig
/// const color = facet.ClearColorValue{ .float32 = .{ 0, 0, 0, 1 } };
/// const range = facet.ImageSubresourceRange{};
/// fb.CmdClearColorImage(commands, texture.?, .transfer_dst_optimal, &color, 1, @ptrCast(&range));
/// ```
pub fn CmdClearColorImage(base: *FacetBase, buffer: *facet.CommandBuffer, image: *facet.Image, layout: facet.ImageLayout, color: *const facet.ClearColorValue, range_count: u32, ranges: [*]const facet.ImageSubresourceRange) void {
    _ = base;
    _ = layout;
    const made = _command.recording(buffer) orelse return;
    const command = _command.ClearColorImage{
        .count = range_count,
        .color = _render.colorOf(color.*),
        .parts = color.float32,
        .words = color.uint32,
        .image = _objects.of(Image, image),
    };
    _command.record(made, command, facet.ImageSubresourceRange, ranges[0..range_count]);
}

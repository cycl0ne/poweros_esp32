// SPDX-License-Identifier: MIT
//! CmdClearDepthStencilImage: a depth image's pixels set to a depth,
//! outside a render pass.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const _render = @import("../render/_render.zig");
const Image = @import("../image/_image.zig").Image;

/// Recorded: a depth image's pixels set to a depth.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdClearDepthStencilImage(base: *FacetBase, buffer: *facet.CommandBuffer, image: *facet.Image, layout: u32, value: *const facet.ClearDepthStencilValue, range_count: u32, ranges: [*]const facet.ImageSubresourceRange) void
/// ```
///
/// SINCE: 1.30. LVO -488.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `image` - the image cleared, of `d16_unorm`, which is not an
///   attachment of the pass being recorded: this is a transfer, not a draw.
/// - `layout` - what the image is in, which this library does not act on.
/// - `value` - the depth, 0 to 1, as the tiles hold one: 0 nearest. Its
///   `stencil` is kept and not written, there being no stencil plane.
/// - `range_count`, `ranges` - which levels and layers, by
///   `base_mip_level`, `level_count`, `base_array_layer` and `layer_count`.
///   A depth image has one of each, so a range past them is left out.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Every pixel of the image is set to the depth. An image this cannot
/// write - one that is not a depth image, or one of `s8_uint` or
/// `d16_unorm_s8_uint`, which have no plane of their own - is left out of
/// the frame and said to be in the log.
///
/// A transient depth image is left alone: its pixels live in the tiles and
/// there is nothing in memory to clear, which the render pass does as each
/// tile starts. It is not an error.
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
/// This is for a depth image a render pass stores into
/// (`PhysicalDeviceFeatures.stored_depth`): it is how one is put back to
/// the furthest depth without a pass over it. Where the pass clears its
/// depth attachment itself there is nothing for this to do.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdClearColorImage`, `CmdClearAttachments`, `CreateRenderPass`
///
/// EXAMPLES:
/// ```zig
/// const value = facet.ClearDepthStencilValue{ .depth = 1 };
/// const range = facet.ImageSubresourceRange{ .aspect_mask = facet.IMAGE_ASPECT_DEPTH };
/// fb.CmdClearDepthStencilImage(commands, depth.?, 0, &value, 1, @ptrCast(&range));
/// ```
pub fn CmdClearDepthStencilImage(base: *FacetBase, buffer: *facet.CommandBuffer, image: *facet.Image, layout: u32, value: *const facet.ClearDepthStencilValue, range_count: u32, ranges: [*]const facet.ImageSubresourceRange) void {
    _ = base;
    _ = layout;
    const made = _command.recording(buffer) orelse return;
    const command = _command.ClearDepthStencilImage{
        .count = range_count,
        .depth = _render.depthOf(value.*),
        .stencil = @truncate(value.stencil),
        .image = _objects.of(Image, image),
    };
    _command.record(made, command, facet.ImageSubresourceRange, ranges[0..range_count]);
}

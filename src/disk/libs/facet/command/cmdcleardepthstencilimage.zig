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
/// - `image` - the image cleared, a depth attachment's of `d16_unorm`,
///   `s8_uint` or `d16_unorm_s8_uint`, which is not an attachment of the
///   pass being recorded: this is a transfer, not a draw.
/// - `layout` - what the image is in, which this library does not act on.
///   A `facet.ImageLayout`, as its five sibling commands take (since
///   1.80; a bare `u32` before, so the layout had to be spelled as a
///   number here and as a name there).
/// - `value` - the depth, 0 to 1, as the tiles hold one: 0 nearest, and
///   the stencil, a byte, for a format that holds one (since 1.38).
/// - `range_count`, `ranges` - which levels and layers, by
///   `base_mip_level`, `level_count`, `base_array_layer` and `layer_count`,
///   and which of the two the range's `aspect_mask` asks for: a format
///   that holds both has each cleared on its own. A range past the levels
///   or the layers the image has is left out; such an image has had
///   layers since 1.58 and levels since 1.63, each level's own rows
///   cleared over the level's own size.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Every pixel of the image is set to the depth, to the stencil, or to
/// both, as the range's aspects say and as the format holds. What the
/// aspects leave out is left as it is: the depth of a `d16_unorm_s8_uint`
/// image whose stencil alone was cleared still says what the pass stored.
/// An image this cannot write - one that is not a depth attachment's - is
/// left out of the frame and said to be in the log.
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
/// This is for a depth or stencil image a render pass stores into
/// (`PhysicalDeviceFeatures.stored_depth`, `stored_stencil`): it is how
/// one is put back to the furthest depth, or to a stencil of its own,
/// without a pass over it. Where the pass clears its attachment itself
/// there is nothing for this to do.
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
/// fb.CmdClearDepthStencilImage(commands, depth.?, .undefined, &value, 1, @ptrCast(&range));
/// ```
pub fn CmdClearDepthStencilImage(base: *FacetBase, buffer: *facet.CommandBuffer, image: *facet.Image, layout: facet.ImageLayout, value: *const facet.ClearDepthStencilValue, range_count: u32, ranges: [*]const facet.ImageSubresourceRange) void {
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

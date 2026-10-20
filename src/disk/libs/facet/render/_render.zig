// SPDX-License-Identifier: MIT
//! A render pass and a framebuffer.
//!
//! A render pass of facet.library has one subpass, which draws into a
//! colour attachment and, if it has one, a depth attachment: what the
//! rasterizer's target has, its tiles' colour and their depth. How each
//! starts and ends is settled as the pass is made:
//! - the colour: CLEAR clears every tile of the render area; LOAD and
//!   DONT_CARE keep what the image holds, read into a tile only where
//!   something is drawn - a tile nothing touches is neither read nor
//!   written. What is drawn is stored, whatever the store op.
//! - the depth: CLEAR or DONT_CARE, the tiles' depth cleared as each
//!   starts; it is never stored, and its store op is DONT_CARE.

const sdk = @import("sdk");
const facet = sdk.facet;
const raster = @import("raster");
const Device = @import("../device/_device.zig").Device;
const _image = @import("../image/_image.zig");
const ImageView = _image.ImageView;

pub const RenderPass = struct {
    device: *Device,
    attachment_count: u32,
    /// The colour attachment's place among the attachments, and the depth
    /// attachment's if there is one.
    color: u32,
    depth: ?u32,
    color_format: facet.Format,
    /// What the colour starts with.
    color_load: raster.Attachments.Load,
};

pub const Framebuffer = struct {
    device: *Device,
    width: u32,
    height: u32,
    color: *ImageView,
    depth: ?*ImageView,
};

/// The surface a framebuffer's colour attachment is: its image's memory,
/// row after row. Null for an image not bound.
pub fn surfaceOf(framebuffer: *const Framebuffer) ?raster.Surface {
    const image = framebuffer.color.image;
    return .{
        .pixels = image.data orelse return null,
        .pitch = image.pitch,
        .width = image.width,
        .height = image.height,
        .format = _image.surfaceFormat(image.format).?,
    };
}

/// A clear value's colour, 0 to 1 a channel, as 0xAARRGGBB.
pub fn colorOf(value: facet.ClearColorValue) u32 {
    const rgba = value.float32;
    return byteOf(rgba[3]) << 24 | byteOf(rgba[0]) << 16 | byteOf(rgba[1]) << 8 | byteOf(rgba[2]);
}

/// A clear value's depth, 0 to 1, as the depth buffer's 0 to 65535.
pub fn depthOf(value: facet.ClearDepthStencilValue) u16 {
    const depth = if (value.depth >= 0) @min(value.depth, 1) else 0; // a NaN as well
    return @intFromFloat(@round(depth * 65535));
}

fn byteOf(channel: f32) u32 {
    const held = if (channel >= 0) @min(channel, 1) else 0;
    return @intFromFloat(@round(held * 255));
}

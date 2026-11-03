// SPDX-License-Identifier: MIT
//! A render pass and a framebuffer.
//!
//! A render pass of facet.library has up to 4 subpasses, which are played one
//! after another as passes of their own: each draws into its colour
//! attachments and, if it has one, a depth attachment, and what it stored
//! the next may draw over. Input attachments, which would read a subpass's
//! results in the next as it draws, there are none of. A subpass with the
//! very attachments of the one before it goes on in the same tiles, its depth
//! and all: the only way two subpasses share a depth.
//!
//! The tiles have one colour. A subpass of several colour attachments is drawn
//! once for each, up to 4, a `Part` each, its draws played over for each after
//! the first; `shader.Resources.output` says which is being drawn. All drawn
//! the same way: the blend states of a pipeline have to be alike.
//!
//! How each starts and ends is settled as the pass is made:
//! - a colour: CLEAR clears every tile of the render area the first time
//!   it is drawn into; LOAD, DONT_CARE and any time after that keep what the
//!   image holds, read into a tile only where something is drawn - a tile
//!   nothing touches is neither read nor written. What is drawn is stored,
//!   whatever the store op.
//! - the depth: CLEAR or DONT_CARE, the tiles' depth cleared as each
//!   starts; it is never stored, and its store op is DONT_CARE.

const sdk = @import("sdk");
const facet = sdk.facet;
const Device = @import("../device/_device.zig").Device;
const ImageView = @import("../image/_image.zig").ImageView;

/// What a colour attachment starts with: cleared, or what the image holds.
pub const ColorLoad = enum { clear, keep };

pub const most_attachments = 8;
pub const most_subpasses = 4;
pub const most_colors = 4;
pub const most_parts = 8;

/// One colour attachment of a subpass, drawn as a pass of its own.
pub const Part = struct {
    /// The colour attachment's place among the attachments, and the depth
    /// attachment's if there is one.
    color: u32,
    depth: ?u32,
    /// What that attachment has of the two.
    tests_depth: bool,
    tests_stencil: bool,
    color_format: facet.Format,
    /// What the colour starts with.
    color_load: ColorLoad,
    /// Whether the depth attachment is read from its image as the part
    /// starts, and written into it as the part ends: a depth that outlives
    /// the pass (`PhysicalDeviceFeatures.stored_depth`). Both are false for
    /// a depth that lives in the tiles alone.
    loads_depth: bool = false,
    stores_depth: bool = false,
    /// The same for its stencil, which has its own two ops and its own
    /// plane in the image's rows
    /// (`PhysicalDeviceFeatures.stored_stencil`).
    loads_stencil: bool = false,
    stores_stencil: bool = false,
};

pub const Subpass = struct {
    first_part: u32,
    part_count: u32,
    /// Goes on in the tiles of the one before it.
    joined: bool,
};

pub const RenderPass = struct {
    device: *Device,
    attachment_count: u32,
    parts: [most_parts]Part = undefined,
    part_count: u32 = 0,
    subpasses: [most_subpasses]Subpass = undefined,
    subpass_count: u32 = 0,
};

/// What a part of a subpass draws into.
pub const Target = struct {
    width: u32,
    height: u32,
    color: *ImageView,
    depth: ?*ImageView,
};

pub const Framebuffer = struct {
    device: *Device,
    width: u32,
    height: u32,
    /// One for each of the pass's parts.
    targets: [most_parts]Target = undefined,
};

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

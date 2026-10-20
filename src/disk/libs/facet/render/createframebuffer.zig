// SPDX-License-Identifier: MIT
//! CreateFramebuffer: the image views a render pass draws into.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _render = @import("_render.zig");
const ImageView = @import("../image/_image.zig").ImageView;

/// A framebuffer: an image view for each of a render pass's attachments.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateFramebuffer(base: *FacetBase, device: *facet.Device, info: *const facet.FramebufferCreateInfo, framebuffer: *?*facet.Framebuffer) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -212.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - the render pass, a view for each of its attachments in their
///   order, and the size drawn in.
/// - `framebuffer` - where the framebuffer is written; null when it fails.
///
/// RESULT:
/// `success`; `error_initialization_failed` for views that do not fit the
/// pass - another number of them, a colour view of an image not made for a
/// colour attachment or in another format, a depth view of an image not
/// made for depth, an image smaller than the size, more than one layer;
/// `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The colour attachment's view is of its image's first level. The size
/// may be smaller than the images: the framebuffer is their top left.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The framebuffer is the caller's, until DestroyFramebuffer. The views
/// have to last as long as it does, and their images.
///
/// NOTES:
/// The images have to be bound into memory before a pass draws into them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateRenderPass`, `CmdBeginRenderPass`, `DestroyFramebuffer`
///
/// EXAMPLES:
/// ```zig
/// var frame: ?*facet.Framebuffer = null;
/// _ = fb.CreateFramebuffer(device, &.{ .render_pass = pass.?, .attachment_count = 1, .attachments = @ptrCast(&view), .width = 800, .height = 600 }, &frame);
/// ```
pub fn CreateFramebuffer(base: *FacetBase, device: *facet.Device, info: *const facet.FramebufferCreateInfo, framebuffer: *?*facet.Framebuffer) facet.Result {
    framebuffer.* = null;
    const owner = _objects.of(Device, device);
    const pass = _objects.of(_render.RenderPass, info.render_pass);
    if (info.attachment_count != pass.attachment_count or info.layers != 1 or info.width == 0 or info.height == 0) return .error_initialization_failed;
    const views: []const *facet.ImageView = info.attachments[0..info.attachment_count];
    const color = _objects.of(ImageView, views[pass.color]);
    const image = color.image;
    if (image.kind != .rows or image.format != pass.color_format or image.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT == 0) return .error_initialization_failed;
    if (color.base_level != 0 or image.width < info.width or image.height < info.height) return .error_initialization_failed;
    const depth: ?*ImageView = if (pass.depth) |index| depth: {
        const view = _objects.of(ImageView, views[index]);
        if (view.image.kind != .depth or view.image.width < info.width or view.image.height < info.height) return .error_initialization_failed;
        break :depth view;
    } else null;
    const made = _objects.create(base.sys_base, _render.Framebuffer) orelse return .error_out_of_host_memory;
    made.* = .{ .device = owner, .width = info.width, .height = info.height, .color = color, .depth = depth };
    framebuffer.* = _objects.handle(facet.Framebuffer, made);
    return .success;
}

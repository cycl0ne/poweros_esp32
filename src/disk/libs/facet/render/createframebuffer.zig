// SPDX-License-Identifier: MIT
//! CreateFramebuffer: the image views a render pass draws into.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _render = @import("_render.zig");
const _image = @import("../image/_image.zig");
const ImageView = _image.ImageView;

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
/// Each colour attachment's view is of its image's first level. The size
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
    var plan = _render.Framebuffer{ .device = owner, .width = info.width, .height = info.height };
    for (pass.parts[0..pass.part_count], plan.targets[0..pass.part_count]) |part, *target| {
        target.color_count = part.color_count;
        for (part.colors[0..part.color_count], part.color_formats[0..part.color_count], 0..) |index, format, k| {
            const color = _objects.of(ImageView, views[index]);
            const image = color.image;
            if (image.kind != .rows or image.format != format or image.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT == 0) return .error_initialization_failed;
            if (color.base_level != 0 or image.width < info.width or image.height < info.height) return .error_initialization_failed;
            target.colors[k] = color;
        }
        const depth: ?*ImageView = if (part.depth) |index| depth: {
            const view = _objects.of(ImageView, views[index]);
            if (view.image.kind != .depth or view.image.width < info.width or view.image.height < info.height) return .error_initialization_failed;
            // A depth the pass keeps is written into the image's memory, so
            // the image wants memory something is behind: a lazily
            // allocated one has none (`readable`).
            const kept = part.stores_depth or part.loads_depth or part.stores_stencil or part.loads_stencil;
            if (kept and !_image.readable(view.image)) return .error_feature_not_present;
            break :depth view;
        } else null;
        target.width = info.width;
        target.height = info.height;
        target.depth = depth;
    }
    const made = _objects.create(base.sys_base, _render.Framebuffer) orelse return .error_out_of_host_memory;
    made.* = plan;
    framebuffer.* = _objects.handle(facet.Framebuffer, made);
    return .success;
}

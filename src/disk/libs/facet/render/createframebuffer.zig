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
///   order, the size drawn in, and its layers.
/// - `framebuffer` - where the framebuffer is written; null when it fails.
///
/// RESULT:
/// `success`; `error_validation_failed` for views that do not fit the
/// pass - another number of them, or none given where it has some; a
/// colour or resolve view of an image not made for a colour attachment,
/// or in another format than its attachment's - the view's own, which
/// since 1.131 may differ from its image's (CreateImageView,
/// IMAGE_CREATE_MUTABLE_FORMAT); a depth view of an image not made for
/// depth; a view of other samples than its attachment's, or one that
/// swizzles its channels (since 1.120); an image smaller than the size,
/// or a view of fewer layers than the framebuffer has - and for a size or
/// layers of none, or of more than the device takes
/// (`PhysicalDeviceLimits.max_framebuffer_width`, `max_framebuffer_height`
/// and `max_framebuffer_layers`)
/// (VUID-VkFramebufferCreateInfo-attachmentCount-00876, -flags-02778,
/// -pAttachments-00877, -00880, -02633, -00881, -00884, -flags-04533,
/// -04534, -04535, -width-00885, -00886, -height-00887, -00888,
/// -layers-00889, -00890; `error_initialization_failed` until 1.134);
/// `error_feature_not_present` for a view of a level smaller than the
/// size, of an image that is not, which Vulkan allows and this library
/// does not draw into (docs/facet-vulkan10.md item 92;
/// `error_initialization_failed` until 1.134), and for a depth the pass
/// keeps in an image with no memory behind it - both answered once every
/// view has been held to Vulkan's rules, so that a framebuffer breaking
/// one of them as well is `error_validation_failed` (since 1.134);
/// `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// Each colour attachment's view is of any of its image's levels since
/// 1.119, and of its first before, and of any of its layers since 1.91:
/// the pass draws into the level and the layer the view begins at, and it
/// is that level's rows that have to hold the size, as a depth view's do.
/// Vulkan holds only the image's first level to the size
/// (VUID-VkFramebufferCreateInfo-flags-04533, -04534), so a level smaller
/// than it is `error_feature_not_present` here, a pass having no rows past
/// the level's to draw into (docs/facet-vulkan10.md item 92), and an image
/// smaller than it `error_validation_failed`.
/// The size may be smaller than the images: the framebuffer is their top
/// left. So each level of one image, drawn into in turn, is its own mip
/// level, and a later pass samples the image they make (CreateImage).
///
/// A pass with no attachments has a framebuffer of no views, `attachments`
/// null (since 1.113): its size is all there is of it, which the pass
/// draws over, so that is held to the device's most, as Vulkan asks of
/// every framebuffer (VUID-VkFramebufferCreateInfo-width-00886 and
/// -height-00888).
///
/// A framebuffer has layers since 1.91, as many as the device's
/// `max_framebuffer_layers` - 256 on the cores, which is what Vulkan asks,
/// and 1 on the V3D. Each view holds that many from the layer it begins
/// at, and a pass clears every one of them where an attachment's load op
/// clears, as CmdClearAttachments clears the ones a rectangle names. What
/// it draws goes into the first: Vulkan 1.0 has nothing but a geometry
/// shader's `Layer` to pick another, and no device here has one. That is
/// how Mesa's lavapipe plays a pass too (`render_clear` and
/// `handle_clear_attachments`, src/gallium/frontends/lavapipe/lvp_execute.c).
///
/// A depth view names the level and the layer the pass draws into - levels
/// since 1.63, layers since 1.58 - and it is that level's rows that have
/// to hold the size, not the image's first, as for a colour view. So the
/// levels of one depth image are a shadow map and the smaller copies a
/// pass draws for themselves, each through a framebuffer of that level's
/// size.
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
    // VUID-VkFramebufferCreateInfo-attachmentCount-00876, -width-00885,
    // -height-00887.
    if (info.attachment_count != pass.attachment_count or info.width == 0 or info.height == 0) return .error_validation_failed;
    // Layers since 1.91, as many as the device takes: what it says, so a
    // program that reads the limit and keeps to it is never refused here
    // (-layers-00889, -00890).
    const limits = &owner.physical.properties.limits;
    if (info.layers == 0 or info.layers > limits.max_framebuffer_layers) return .error_validation_failed;
    // Its size, which no image bounds where there are none (since 1.113;
    // -width-00886, -height-00888).
    if (info.width > limits.max_framebuffer_width or info.height > limits.max_framebuffer_height) return .error_validation_failed;
    // -flags-02778.
    const views: []const *facet.ImageView = if (info.attachment_count == 0) &.{} else (info.attachments orelse return .error_validation_failed)[0..info.attachment_count];
    // Each view of an image holding the samples its attachment says
    // (VUID-VkFramebufferCreateInfo-pAttachments-00881, since 1.100), and
    // swizzling none of its channels
    // (VUID-VkFramebufferCreateInfo-pAttachments-00884, since 1.120): a
    // pass draws into the pixels as they lie.
    for (views, pass.samples[0..views.len]) |view, samples| {
        const one = _objects.of(ImageView, view);
        if (one.image.samples != samples or !one.swizzle.isIdentity()) return .error_validation_failed;
    }
    var plan = _render.Framebuffer{ .device = owner, .width = info.width, .height = info.height };
    // What Vulkan allows and this library does not draw, answered once
    // every view has been held to Vulkan's rules: a framebuffer that
    // breaks one of them as well is told that (since 1.134).
    var unsupported = false;
    for (pass.parts[0..pass.part_count], plan.targets[0..pass.part_count]) |part, *target| {
        target.color_count = part.color_count;
        // The targets are set a field at a time, so none is left as it
        // was: a part without a resolve has none (since 1.100).
        target.resolves = @splat(null);
        for (part.colors[0..part.color_count], part.color_formats[0..part.color_count], 0..) |index, format, k| {
            const color = _objects.of(ImageView, views[index]);
            const image = color.image;
            // The view's format is the one the pass draws in, which may be
            // another than the image's (since 1.131): an image of another
            // kind is one not made for a colour attachment, or of a depth
            // format (VUID-VkFramebufferCreateInfo-pAttachments-00877, -00880).
            if (image.kind != .rows or color.format != format or image.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT == 0) return .error_validation_failed;
            // The level the view names is what the pass draws into, so it
            // is that level's rows that hold the render area, as a depth
            // attachment's do (levels since 1.119).
            switch (fitOf(image, color.base_level, info)) {
                .held => {},
                .image_smaller => return .error_validation_failed,
                .level_smaller => unsupported = true,
            }
            // Every layer the framebuffer has, or a pass would clear past
            // the image's last (-flags-04535; since 1.91).
            if (color.layer_count < info.layers) return .error_validation_failed;
            target.colors[k] = color;
            // Its resolve attachment, rows of the same format that hold
            // the render area, as the colour does (since 1.100).
            if (part.resolves[k]) |into| {
                const resolve = _objects.of(ImageView, views[into]);
                const rows = resolve.image;
                if (rows.kind != .rows or resolve.format != format or rows.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT == 0) return .error_validation_failed;
                switch (fitOf(rows, resolve.base_level, info)) {
                    .held => {},
                    .image_smaller => return .error_validation_failed,
                    .level_smaller => unsupported = true,
                }
                if (resolve.layer_count < info.layers) return .error_validation_failed;
                target.resolves[k] = resolve;
            }
        }
        const depth: ?*ImageView = if (part.depth) |index| depth: {
            const view = _objects.of(ImageView, views[index]);
            // An image of another kind is one not made for a depth
            // attachment, or of a colour format
            // (VUID-VkFramebufferCreateInfo-pAttachments-02633, -00880).
            if (view.image.kind != .depth) return .error_validation_failed;
            // The level the view names is what the pass draws into, so it
            // is that level's rows that have to hold the render area
            // (levels since 1.63).
            switch (fitOf(view.image, view.base_level, info)) {
                .held => {},
                .image_smaller => return .error_validation_failed,
                .level_smaller => unsupported = true,
            }
            if (view.layer_count < info.layers) return .error_validation_failed;
            // A depth the pass keeps is written into the image's memory, so
            // the image wants memory something is behind: a lazily
            // allocated one has none (`readable`).
            const kept = part.stores_depth or part.loads_depth or part.stores_stencil or part.loads_stencil;
            if (kept and !_image.readable(view.image)) unsupported = true;
            break :depth view;
        } else null;
        target.width = info.width;
        target.height = info.height;
        target.layers = info.layers;
        target.depth = depth;
    }
    if (unsupported) return .error_feature_not_present;
    const made = _objects.create(base.sys_base, _render.Framebuffer) orelse return .error_out_of_host_memory;
    made.* = plan;
    framebuffer.* = _objects.handle(facet.Framebuffer, made);
    return .success;
}

/// How a view of an image's level holds a framebuffer's size. An image
/// smaller than the size breaks Vulkan's rules
/// (VUID-VkFramebufferCreateInfo-flags-04533, -04534); a level smaller
/// than it, of an image that is not, does not, and is a level a pass here
/// has no rows past to draw into (docs/facet-vulkan10.md item 92). (Since
/// 1.134: both were `error_initialization_failed`.)
const Fit = enum { held, image_smaller, level_smaller };

/// How a view of `image` at `level` holds the size `info` asks for.
fn fitOf(image: *const _image.Image, level: u32, info: *const facet.FramebufferCreateInfo) Fit {
    if (image.width < info.width or image.height < info.height) return .image_smaller;
    const size = _image.levelSize(image, level);
    if (size[0] < info.width or size[1] < info.height) return .level_smaller;
    return .held;
}

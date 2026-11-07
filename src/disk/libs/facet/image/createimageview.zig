// SPDX-License-Identifier: MIT
//! CreateImageView: an image as a pipeline or a framebuffer sees it.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _image = @import("_image.zig");
const Image = _image.Image;
const ImageView = _image.ImageView;
const texture = facet.texture;

/// A view of an image: the levels of it a texture descriptor samples, or
/// what a framebuffer draws into.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateImageView(base: *FacetBase, device: *facet.Device, info: *const facet.ImageViewCreateInfo, view: *?*facet.ImageView) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `device` - the device the image was made on.
/// - `info` - the image, bound already, its own format, and the levels
///   the view takes.
/// - `view` - where the view is written; null when it fails.
///
/// RESULT:
/// `success`; `error_format_not_supported` for a view facet.library does
/// not make - of another format than the image's, of a type the image is
/// not for, with a swizzle that is none of Vulkan's seven values, of
/// levels or layers the image has not got, or of an image not yet bound
/// into memory; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// A view of a texture samples its levels from `base_mip_level` on, as a
/// texture of its own whose first level is that one. So, since 1.119, does
/// a view of an attachment drawn into and sampled at once, which is kept
/// in rows: it reads the rows a pass drew into, at the levels and the
/// layers it names. A framebuffer given a view of any image kept in rows
/// draws into the level the view begins at, an image kept in rows having
/// levels since 1.119.
///
/// **Its channels may be swizzled** since 1.120, as Vulkan's
/// `VkComponentMapping` has them: each of `components` names the channel of
/// the texel it reads, its own (`identity`), or 0 or 1. Every read of the
/// view's texels is swizzled - a sample through a sampler or by a fixed
/// form, `colorAt`, `partsAt` and `wholesAt` - and so are the border and
/// what a comparison gave, Vulkan replacing a texel and comparing a depth
/// before it swizzles (`texture.Swizzle`). A channel the format has not got
/// reads 0, or 1 for an alpha, before the swizzle: an R8 view may read its
/// alpha as its red, and reads 1. A depth or a stencil reads (D, 0, 0, 1),
/// as Vulkan converts such a texel, before the swizzle: a swizzle takes 0
/// from its green and its blue and 1 from its alpha (since 1.121 whatever
/// the view's swizzle, since 1.120 where it swizzles). A fixed form
/// compiled for the view's format draws one that swizzles through the
/// run-time sampler, a pixel at a time. A framebuffer takes no view that
/// swizzles, and neither a storage image nor an input attachment may be
/// one, as Vulkan has it (VUID-VkWriteDescriptorSet-descriptorType-00336).
/// On the V3D the TMU swizzles, the view's over the format's own.
///
/// Of type `2d` it is one layer, of a texture with any number of them. Of type
/// `2d_array` it is the layers asked for, for `shader.FixedKind.texture_array`;
/// `cube` is 6 layers of an image made IMAGE_CREATE_CUBE_COMPATIBLE, for
/// `texture_cube`, and `3d` the whole of a 3D image, for `texture_3d`.
///
/// Of type `cube_array` it is as many cubes as its layers divided by six, of
/// such an image, for `texture_cube_array` and, since 1.53,
/// `texture_cube_array_sampled`: its layers are a multiple of six
/// and its first layer begins a cube, so `base_array_layer` is a multiple of
/// six as well (`Capabilities.cube_arrays`, since 1.46).
///
/// **A view of a sampled depth image takes one of its planes** since 1.58
/// (`Capabilities.sampled_depth`): IMAGE_ASPECT_DEPTH is the
/// depth, read at all 16 bits by a sampler that compares and as a grey of
/// its top 8 by one that does not, and IMAGE_ASPECT_STENCIL is the
/// stencil, read as (red, 0, 0, 1) the way a texel of one byte is. A
/// plane the format has not got is `error_format_not_supported`; an
/// aspect naming neither - IMAGE_ASPECT_COLOR, the default, and what every
/// such view asked for before 1.58 - is the format's own plane, its depth
/// where it has one and its stencil where it has not. The plane is a
/// texture over the image's own rows, so a format holding both is two
/// textures inside the same rows, read four bytes apart. Since 1.63 it is
/// the levels the view names as well, each in rows of its own: a sample
/// of such a view reads the level it chooses, as it does of any texture.
///
/// **Both aspects at once**, of a format holding both, is a view since
/// 1.94 and was refused before. It is what a framebuffer is given for a
/// pass's depth/stencil attachment, which draws into both planes whatever
/// the view names, as Vulkan has it. No descriptor may hold such a view,
/// Vulkan having a descriptor's view of a depth/stencil image name one
/// aspect, so its texture is only what a sample would read regardless:
/// the depth, as lavapipe's is (`lvp_create_samplerview` takes the stencil
/// for the stencil alone).
///
/// Since 1.62 the same plane is what a later subpass reads as an **input
/// attachment** (`shader.Attachment`), where the image was made one
/// (IMAGE_USAGE_INPUT_ATTACHMENT): the view's first layer, the depth as
/// `r16`, 0 to 1 and nearest first, and the stencil as `r8u`, the whole
/// number it is. A format holding both is read four bytes from one pixel
/// to the next, the view's aspect saying which plane this is.
///
/// Such a view is of the layers it names as well, of type `2d` or
/// `2d_array`: the image's own rows for that layer, which is what a pass
/// drawing into the view writes and what a sample of it reads. So the
/// layers of one image are the shadow maps of several lights, each drawn
/// into through a framebuffer with a view of that layer.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The view is the caller's, until DestroyImageView, which comes before
/// the image's DestroyImage.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroyImageView`, `CreateImage`, `CreateFramebuffer`
///
/// EXAMPLES:
/// ```zig
/// var view: ?*facet.ImageView = null;
/// const info = facet.ImageViewCreateInfo{ .image = picture.?, .format = .b8g8r8a8_unorm };
/// if (fb.CreateImageView(device, &info, &view) != .success) return error.NoView;
/// ```
pub fn CreateImageView(base: *FacetBase, device: *facet.Device, info: *const facet.ImageViewCreateInfo, view: *?*facet.ImageView) facet.Result {
    _ = device;
    view.* = null;
    const image = _objects.of(Image, info.image);
    if (info.format != image.given_format) return .error_format_not_supported;
    const swizzle = swizzleOf(info.components) orelse return .error_format_not_supported;
    const range = info.subresource_range;
    if (range.base_mip_level >= image.levels or range.base_array_layer >= image.layers) return .error_format_not_supported;
    const layers = if (range.layer_count == facet.REMAINING) image.layers - range.base_array_layer else range.layer_count;
    if (layers == 0 or layers > image.layers - range.base_array_layer) return .error_format_not_supported;
    switch (info.view_type) {
        // A 1D image takes the 1D view types and no other, and a 2D image
        // a row high is not one: the two are different kinds of image to
        // Vulkan however alike their texels lie (since 1.86).
        .@"1d" => if (layers != 1 or !image.line) return .error_format_not_supported,
        .@"1d_array" => if (!image.line) return .error_format_not_supported,
        .@"2d" => if (layers != 1 or image.volume or image.line) return .error_format_not_supported,
        .@"2d_array" => if (image.volume or image.line) return .error_format_not_supported,
        .cube => if (!image.cube or layers != 6) return .error_format_not_supported,
        // Cubes one after another: six layers to each, and the first layer
        // of the view is the first face of a cube (since 1.46).
        .cube_array => if (!image.device.physical.can.cube_arrays or !image.cube or layers % 6 != 0 or range.base_array_layer % 6 != 0) return .error_format_not_supported,
        .@"3d" => if (!image.volume or range.base_array_layer != 0 or layers != image.layers) return .error_format_not_supported,
        else => return .error_format_not_supported,
    }
    const count = if (range.level_count == facet.REMAINING) image.levels - range.base_mip_level else range.level_count;
    if (count == 0 or count > image.levels - range.base_mip_level) return .error_format_not_supported;
    if (image.kind != .depth and image.data == null) return .error_format_not_supported;
    // A depth attachment sampled where it lies: the plane the view's
    // aspect names, of the layers it names (since 1.58). Both planes at
    // once is the depth (since 1.94), one the format has not got is no
    // texture, and an aspect naming neither is the format's own plane.
    const plane = if (_image.sampledDepth(image))
        _image.depthPlane(image, range.aspect_mask, range.base_mip_level, count, range.base_array_layer, layers) orelse return .error_format_not_supported
    else
        null;
    // The same plane as rows, for a later subpass to read pixel by pixel
    // (since 1.62): the view's first layer, the depth 0 to 1 and the
    // stencil the whole number it is.
    const read_rows = if (image.kind == .depth and image.usage & facet.IMAGE_USAGE_INPUT_ATTACHMENT != 0)
        _image.depthRows(image, range.aspect_mask, range.base_mip_level, range.base_array_layer) orelse return .error_format_not_supported
    else
        null;
    const made = _objects.create(base.sys_base, ImageView) orelse return .error_out_of_host_memory;
    made.* = .{ .image = image, .base_level = range.base_mip_level, .level_count = count, .base_layer = range.base_array_layer, .layer_count = layers, .swizzle = swizzle };
    if (image.kind == .texture) made.texels = _image.levelsFrom(image, range.base_mip_level, count, range.base_array_layer, layers);
    // A colour attachment written through as a storage image (since
    // 1.56): its rows are the one level, and a view of it takes them as
    // they are.
    if (_image.writtenRows(image)) made.texels = image.texels;
    // An image kept in rows sampled where they lie: the layers the view
    // names, of every sample (since 1.110), and the levels it names
    // (since 1.119).
    if (_image.sampledRows(image)) made.texels = _image.rowLevels(image, range.base_mip_level, count, range.base_array_layer, layers);
    if (plane) |one| made.texels = one;
    // What a sample, a fetch and a read of the texels give back, swizzled
    // as the view says (since 1.120), and of a depth or a stencil read
    // (D, 0, 0, 1) whatever it says (since 1.121). An input attachment's
    // rows and a storage image's texels are read where Vulkan has the view
    // swizzle nothing (VUID-VkWriteDescriptorSet-descriptorType-00336), so
    // a view that does is not one either may be.
    if (_image.hasTexels(image)) made.texels.swizzle = if (image.kind == .depth) depthRead(swizzle) else swizzle;
    if (read_rows) |one| made.rows = one;
    // Its pixels, for a later subpass to read as an input attachment: the
    // rows of the level and the layer the view begins at, an image kept in
    // rows having layers since 1.91 and levels since 1.119, and of four
    // samples each sample's rows a plane after the one before (since
    // 1.111).
    if (image.kind == .rows) {
        const rows = _image.rowsAt(image, range.base_mip_level, range.base_array_layer);
        const size = _image.levelSize(image, range.base_mip_level);
        const first = image.data.? + rows.at;
        made.rows = .{
            .bytes = first,
            .pitch = rows.pitch,
            .width = size[0],
            .height = size[1],
            .format = _image.rowFormat(image.format),
            .samples = image.samples,
            .sample_bytes = @intCast(image.sample_bytes),
            .others = first + @as(usize, @intCast(image.sample_bytes)),
        };
    }
    view.* = _objects.handle(facet.ImageView, made);
    return .success;
}

/// The view's component swizzle, as the program gave it: null for a value
/// that is none of Vulkan's seven. It is what a framebuffer asks of the
/// view and what the V3D's TMU takes over the format's own.
fn swizzleOf(components: facet.ComponentMapping) ?texture.Swizzle {
    return .{
        .r = sourceOf(components.r, .red) orelse return null,
        .g = sourceOf(components.g, .green) orelse return null,
        .b = sourceOf(components.b, .blue) orelse return null,
        .a = sourceOf(components.a, .alpha) orelse return null,
    };
}

/// The swizzle a depth's or a stencil's texels apply, whatever the view's:
/// the green and the blue read as 0 and the alpha as 1, so the grey this
/// library reads such a texel as, (D, D, D, 1), is read (D, 0, 0, 1), as
/// Vulkan converts it (13.2.2, "(0,0,0,1) for missing (R,G,B,A)
/// components"). This is lavapipe's `conv_depth_swiz`, on every view of a
/// depth or a stencil (src/gallium/frontends/lavapipe/lvp_image.c:337-347,
/// 389-396), over llvmpipe's read of one, the same grey
/// (`lp_build_format_swizzle_soa`,
/// src/gallium/auxiliary/gallivm/lp_bld_format_soa.c:82-101). Since 1.121
/// on a view that swizzles nothing as well (docs/facet-vulkan10.md item
/// 89); since 1.120 on one that does.
fn depthRead(given: texture.Swizzle) texture.Swizzle {
    var made = given;
    inline for (.{ "r", "g", "b", "a" }) |name| @field(made, name) = switch (@field(made, name)) {
        .green, .blue => .zero,
        .alpha => .one,
        else => |same| same,
    };
    return made;
}

/// Where one channel of a view comes from: `identity` is the channel's
/// own, `own`.
fn sourceOf(component: facet.ComponentSwizzle, own: texture.Swizzle.Source) ?texture.Swizzle.Source {
    return switch (component) {
        .identity => own,
        .zero => .zero,
        .one => .one,
        .r => .red,
        .g => .green,
        .b => .blue,
        .a => .alpha,
        _ => null,
    };
}

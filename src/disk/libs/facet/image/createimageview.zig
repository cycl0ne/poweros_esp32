// SPDX-License-Identifier: MIT
//! CreateImageView: an image as a pipeline or a framebuffer sees it.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _image = @import("_image.zig");
const Image = _image.Image;
const ImageView = _image.ImageView;

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
/// not for, with channels swizzled, of levels or layers the image has not
/// got, or of an image not yet bound into memory; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// A view of a texture samples its levels from `base_mip_level` on, as a
/// texture of its own whose first level is that one. A view of an
/// attachment is all of it.
///
/// Of type `2d` it is one layer, of a texture with any number of them. Of type
/// `2d_array` it is the layers asked for, for `shader.FixedKind.texture_array`;
/// `cube` is 6 layers of an image made IMAGE_CREATE_CUBE_COMPATIBLE, for
/// `texture_cube`, and `3d` the whole of a 3D image, for `texture_3d`.
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
    if (info.format != image.given_format or !identity(info.components)) return .error_format_not_supported;
    const range = info.subresource_range;
    if (range.base_mip_level >= image.levels or range.base_array_layer >= image.layers) return .error_format_not_supported;
    const layers = if (range.layer_count == facet.REMAINING) image.layers - range.base_array_layer else range.layer_count;
    if (layers == 0 or layers > image.layers - range.base_array_layer) return .error_format_not_supported;
    switch (info.view_type) {
        .@"2d" => if (layers != 1 or image.volume) return .error_format_not_supported,
        .@"2d_array" => if (image.volume) return .error_format_not_supported,
        .cube => if (!image.cube or layers != 6) return .error_format_not_supported,
        .@"3d" => if (!image.volume or range.base_array_layer != 0 or layers != image.layers) return .error_format_not_supported,
        else => return .error_format_not_supported,
    }
    const count = if (range.level_count == facet.REMAINING) image.levels - range.base_mip_level else range.level_count;
    if (count == 0 or count > image.levels - range.base_mip_level) return .error_format_not_supported;
    if (image.kind != .depth and image.data == null) return .error_format_not_supported;
    const made = _objects.create(base.sys_base, ImageView) orelse return .error_out_of_host_memory;
    made.* = .{ .image = image, .base_level = range.base_mip_level, .level_count = count, .base_layer = range.base_array_layer, .layer_count = layers };
    if (image.kind == .texture) made.texels = _image.levelsFrom(image, range.base_mip_level, count, range.base_array_layer, layers);
    // Its pixels, for a later subpass to read as an input attachment.
    if (image.kind == .rows) made.rows = .{
        .bytes = image.data,
        .pitch = image.pitch,
        .width = image.width,
        .height = image.height,
        .format = _image.rowFormat(image.format),
    };
    view.* = _objects.handle(facet.ImageView, made);
    return .success;
}

/// Whether each channel comes from itself.
fn identity(components: facet.ComponentMapping) bool {
    return (components.r == .identity or components.r == .r) and
        (components.g == .identity or components.g == .g) and
        (components.b == .identity or components.b == .b) and
        (components.a == .identity or components.a == .a);
}

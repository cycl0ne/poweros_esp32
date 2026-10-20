// SPDX-License-Identifier: MIT
//! CreateImage: an image, to be bound into memory.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _image = @import("_image.zig");

/// An image: a texture, an attachment, or what a copy moves.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateImage(base: *FacetBase, device: *facet.Device, info: *const facet.ImageCreateInfo, image: *?*facet.Image) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -92.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - its format, size, levels, tiling and usage.
/// - `image` - where the image is written; null when it fails.
///
/// RESULT:
/// `success`; `error_format_not_supported` for an image facet.library
/// does not make; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// What it is for decides how it lies in its memory:
/// - SAMPLED, in optimal tiling, of B8G8R8A8, R8G8B8A8 or R5G6B5, its
///   sides powers of two, with up to as many levels as halving them
///   gives: a texture, in blocks of 4 x 4 texels, an 8888 texel kept in
///   64 bits (sdk.facet.texture). Its texels come in by
///   CmdCopyBufferToImage.
/// - COLOR_ATTACHMENT, of B8G8R8A8 or R8G8B8A8, one level: rows, each on
///   a cache line, in either tiling.
/// - D16_UNORM with DEPTH_STENCIL_ATTACHMENT, optimal, one level: a depth
///   that lives in the tiles alone, never stored, whose memory may be of
///   the lazily allocated type.
/// - Anything else of a colour format, one level: rows.
///
/// Images are two-dimensional, with one layer and one sample a pixel, up
/// to 8192 wide and high. One both SAMPLED and COLOR_ATTACHMENT is not
/// made: a texture and an attachment lie differently.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The image is the caller's, until DestroyImage.
///
/// NOTES:
/// Layouts change nothing in facet.library's memory: `initial_layout` is
/// taken as it is.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroyImage`, `GetImageMemoryRequirements`, `BindImageMemory`, `GetPhysicalDeviceFormatProperties`
///
/// EXAMPLES:
/// ```zig
/// var picture: ?*facet.Image = null;
/// const info = facet.ImageCreateInfo{
///     .format = .b8g8r8a8_unorm,
///     .extent = .{ .width = 256, .height = 256 },
///     .mip_levels = 9,
///     .usage = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSFER_DST,
/// };
/// if (fb.CreateImage(device, &info, &picture) != .success) return error.NoImage;
/// ```
pub fn CreateImage(base: *FacetBase, device: *facet.Device, info: *const facet.ImageCreateInfo, image: *?*facet.Image) facet.Result {
    image.* = null;
    const shape = _image.shapeOf(_objects.of(Device, device), info) orelse return .error_format_not_supported;
    const made = _objects.create(base.sys_base, _image.Image) orelse return .error_out_of_host_memory;
    made.* = shape;
    image.* = _objects.handle(facet.Image, made);
    return .success;
}

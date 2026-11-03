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
/// - COLOR_ATTACHMENT, of B8G8R8A8, R8G8B8A8 or R5G6B5, one level: rows,
///   each on a cache line, in either tiling. What is drawn into one of
///   R5G6B5 is dithered into it (CmdBeginRenderPass).
/// - D16_UNORM with DEPTH_STENCIL_ATTACHMENT, optimal, one level: a depth
///   that lives in the tiles alone, never stored, whose memory may be of
///   the lazily allocated type.
/// - INPUT_ATTACHMENT, of B8G8R8A8, R8G8B8A8 or R5G6B5, in either
///   tiling: rows, which a later subpass reads pixel by pixel
///   (CreateRenderPass). It goes with COLOR_ATTACHMENT and the transfers,
///   not with SAMPLED, STORAGE or TRANSIENT_ATTACHMENT, which lie
///   otherwise or nowhere.
/// - Anything else of a colour format, one level: rows.
///
/// Images have one sample a pixel, and are up to 8192 wide and high. One both
/// SAMPLED and COLOR_ATTACHMENT is not made: a texture and an attachment lie
/// differently.
///
/// A SAMPLED image may have up to 256 layers, or be 3D, of type `3d`, as deep
/// as a power of two up to 256, with one level. IMAGE_CREATE_CUBE_COMPATIBLE
/// says a view of type cube will be made: of a square image of 6 layers or
/// more.
///
/// A SAMPLED image may be of BC1, BC2, BC3, R16G16B16A16_SFLOAT,
/// R32G32B32A32_SFLOAT, B10G11R11_UFLOAT or E5B9G9R9_UFLOAT, in optimal tiling.
/// It is kept as R8G8B8A8, unpacked as it is copied in: it takes that one's
/// memory, and what is in a float image above 1 or below 0 is lost. There is no
/// copying such an image out, nor another image into it, by CmdCopyImage.
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

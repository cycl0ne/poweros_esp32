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
/// - SAMPLED, in optimal tiling, of B8G8R8A8, R8G8B8A8, R5G6B5 or R8_UNORM, of any
///   sides, with up to as many levels as halving the longer gives -
///   floor(log2(side)) + 1, each level the one before halved and no less
///   than one: a texture, in blocks of 4 x 4 texels, an 8888 texel kept in
///   64 bits (sdk.facet.texture). Its texels come in by
///   CmdCopyBufferToImage. A width that is not a power of two is laid out
///   by the next one up, so such a texture takes up to 2 x the memory of
///   one as wide as a power of two (since 1.42); past the width nothing is
///   ever read.
/// - COLOR_ATTACHMENT, of B8G8R8A8, R8G8B8A8 or R5G6B5, one level: rows,
///   each on a cache line, in either tiling. What is drawn into one of
///   R5G6B5 is dithered into it (CmdBeginRenderPass).
/// - D16_UNORM, S8_UINT or D16_UNORM_S8_UINT with
///   DEPTH_STENCIL_ATTACHMENT, optimal, one level: a depth that lives in
///   the tiles alone, never stored, whose memory may be of the lazily
///   allocated type. With a load or a store op it is kept in rows instead
///   (CreateRenderPass), and with SAMPLED as well those rows are the
///   texture a sampler reads: a shadow map drawn into and sampled out of
///   with nothing copied (`Capabilities.sampled_depth`, since
///   1.39). One sampled wants memory something is behind and is not
///   written through as a storage image.
///   Any of the three formats is sampled since 1.58, and such an image
///   may have layers: a view of it takes one plane - the depth, or the
///   stencil - of the layers it names, and a pass draws into the layer
///   its framebuffer's view begins at (CreateImageView). A layer's rows
///   come after the one before, each on a cache line.
///   Levels of its own since 1.63, as many as halving the longer side
///   gives: a layer holds the whole pyramid, a level's rows after the
///   level before it and each level on a cache line, its pitch as wide
///   as that level is. A pass draws into the level its framebuffer's
///   view names, and a sample reads any of them, so a shadow map and its
///   smaller copies are the levels of one image. It is never of type
///   `3d`: a slice is nothing a pass draws into.
///   With INPUT_ATTACHMENT it is read pixel by pixel by a later subpass
///   instead, or as well (since 1.62): the same rows, the same feature,
///   and the same memory behind them, so TRANSIENT_ATTACHMENT is refused
///   with it too.
/// - INPUT_ATTACHMENT, of B8G8R8A8, R8G8B8A8 or R5G6B5, in either
///   tiling: rows, which a later subpass reads pixel by pixel
///   (CreateRenderPass). It goes with COLOR_ATTACHMENT and the transfers,
///   not with SAMPLED, STORAGE or TRANSIENT_ATTACHMENT, which lie
///   otherwise or nowhere. On a depth format it is the bullet above.
/// - Anything else of a colour format, one level: rows.
///
/// Images are up to 8192 wide and high. One both SAMPLED and
/// COLOR_ATTACHMENT is not made: a texture and an attachment lie
/// differently.
///
/// **An image may have four samples a pixel** on a device that draws them
/// (`Capabilities.multisampling`, since 1.98): 2D, optimal, one level and
/// not cube compatible, of a format that is a colour or a depth
/// attachment, as Vulkan has it. Each sample's plane is the whole image at
/// one sample, every layer of it, the next sample's plane after it. Such an
/// image is drawn into, read as an input attachment, copied and resolved,
/// and since 1.110 sampled: one of a colour format is then kept in rows, as
/// one drawn into is, and those rows are the texture a fragment function
/// fetches each sample of (`texture.Texture.sampleOf`), as it fetches a
/// depth attachment's planes. A colour one is not a colour attachment or
/// an input attachment as well, which a sampled colour image of one sample
/// is not either, and no image of four samples is STORAGE.
///
/// **A colour attachment may be written through as a storage image** since
/// 1.56: COLOR_ATTACHMENT, or INPUT_ATTACHMENT, with STORAGE and without
/// SAMPLED, of B8G8R8A8 or R5G6B5, one level and one layer. The image stays
/// in rows, as an attachment is, and those rows are the texture a function
/// writes (`shader.Resources.written`): a write reaches them at once, where
/// what a subpass draws reaches them when it stores, at the end of its part.
/// So a function may seed the rows before a pass draws into them, or write
/// over them after it, and writing them while the pass that draws into them
/// is open has no order against that store - as it has none in Vulkan
/// without a barrier. R8G8B8A8 is `error_format_not_supported` for this: a
/// texture of 8888 is 0xAARRGGBB, as B8G8R8A8's rows are, and the texture
/// that reads a word with red in its low byte (`texture.Format.rgba8`,
/// since 1.110) is fetched from, not written through.
/// FORMAT_FEATURE_STORAGE_IMAGE in a format's **linear** features says its
/// rows may be written through.
///
/// A SAMPLED image may have up to 256 layers, or be 3D, of type `3d`, of any
/// depth up to 256 and with levels of its own (since 1.46): a level is half
/// as deep as the one before it, and no less than one slice deep, each slice
/// carrying the whole of its own pyramid. IMAGE_CREATE_CUBE_COMPATIBLE says a
/// view of type cube, or of cube_array, will be made: of a square image of 6
/// layers or more, a multiple of six of them for an array of cubes.
///
/// A STORAGE image may have layers and levels the same way, and since
/// 1.55 needs no SAMPLED beside it to have them: a function writing one
/// names the level and the layer of the view it writes
/// (`shader.Resources.written`, `texture.Texture.setColor`). Before that
/// an image of layers was refused unless it was sampled as well.
///
/// A SAMPLED image may be of BC1, BC2, BC3, R16G16B16A16_SFLOAT,
/// R32G32B32A32_SFLOAT, B10G11R11_UFLOAT or E5B9G9R9_UFLOAT, in optimal tiling.
/// A float one is kept as the floats it was copied in as on a device that
/// samples them (`Capabilities.kept_floats`, since 1.45): the two
/// packed formats then take 4 bytes a texel rather than the 8 an unpacked
/// texel is kept spread in, and a copy out gives back what went in. A sample
/// holds each channel inside 0 to 1 and rounds it to 8 bits, the tiles having
/// no more. A device without the feature keeps it as R8G8B8A8, unpacked as it
/// is copied in: it takes that one's memory, and there is no copying it out,
/// nor another image into it, by CmdCopyImage.
///
/// It may also be of ETC2 or EAC - ETC2_R8G8B8, ETC2_R8G8B8A1, ETC2_R8G8B8A8,
/// EAC_R11 or EAC_R11G11 - which no sampler of this library reads: such an
/// image is always kept as R8G8B8A8, its blocks unpacked as they are copied
/// in (`Capabilities.etc2_textures`, since 1.46).
///
/// R32_SFLOAT is an image since 1.57, in optimal tiling: one float a texel,
/// sampled as (red, 0, 0, 1) the way R8_UNORM is read, with the float held
/// between 0 and 1 and rounded to 8 bits for the sample, and written through
/// by a function as the float it is (`texture.Texture.setParts`). A height
/// field, a mask or an accumulation buffer is kept in it. It is not a colour
/// attachment and not a vertex's value.
///
/// A compressed one - BC1, BC2, BC3 - is kept in its blocks on a device that
/// samples them (`Capabilities.kept_compressed`, since 1.44): an
/// eighth to a quarter of that memory, and the blocks are copied in and out
/// as they lie, by CmdCopyBufferToImage, CmdCopyImageToBuffer and CmdCopyImage
/// between two images of the one format, their offsets and extents on a
/// multiple of 4 as Vulkan asks. GetImageMemoryRequirements says which was
/// done. A device without the feature unpacks it as a float image is unpacked.
/// A STORAGE image is written texel by texel, so a compressed one is unpacked
/// there whatever the device: nothing writes one texel of a block, and such
/// an image wants SAMPLED beside it, being unpacked to be sampled. A float
/// one keeps its floats since 1.57, a function writing one texel of them by
/// `texture.Texture.setParts`, so a float storage image needs no SAMPLED
/// either.
///
/// **A texel may be kept smaller than the colour it reads as** on a device
/// that says so (`Capabilities.small_texels`, since 1.48), which
/// is where a texture is large enough that the memory it fills is what it
/// costs:
/// - R8_UNORM is one byte a texel, read as (red, 0, 0, 1) the way Vulkan
///   reads a one-channel format - an eighth of what the same texels kept
///   as 8888 take. For SAMPLED or STORAGE, in optimal tiling; a copy moves
///   the bytes both ways. It is not a colour attachment and not a vertex's
///   value.
/// - IMAGE_CREATE_PACKED_TEXELS on a SAMPLED or STORAGE image of B8G8R8A8
///   or R8G8B8A8 keeps each texel in the 32 bits of its word rather than
///   spread over 64: half the memory, for the spread a sample then does
///   itself. Nothing else of the image changes - the same colours in, the
///   same out, the same copies - and a fixed form compiled for
///   `texture.Format.argb8888` reads it at full speed, while one compiled
///   for `rgba8888` draws it through the run-time sampler as it does any
///   other format it was not built for.
///
/// Both are `error_format_not_supported` where the device has not got
/// them, and so is the flag on an image that is neither sampled nor a
/// storage image, or whose format has no 8888 word to keep.
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

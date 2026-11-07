// SPDX-License-Identifier: MIT
//! An image, a view of one, the formats they come in, and a copy from a
//! buffer into one.
//!
//! **What an image is for decides how it lies in its memory.** Its kind
//! is settled as it is made:
//! - an attachment drawn into, and any linear image, is `rows` - row
//!   after row, each starting on a cache line, as the rasterizer writes
//!   its tiles back and the display reads them;
//! - an optimal image to be sampled is a `texture` - by the rasterizer's
//!   texture layout (sdk.facet.texture): blocks of 4 x 4 texels, an 8888
//!   texel spread to 64 bits, the levels after one another; on a device that
//!   samples in its own way, by that device's (Ops.texture_memory);
//! - a depth attachment is `depth`: its pixels live in the tiles alone,
//!   cleared as each tile starts and never stored, so its memory is never
//!   touched and may be of the lazily allocated type.
//!
//! An image both drawn into and sampled is not one facet.library 1.0
//! makes: the two kinds lie differently.
//!
//! **A texture may have layers**: an array's, a cube's six faces, or a 3D
//! image's slices. Each lies as a whole texture does, `layer_bytes` from the
//! one before. A 3D image has one level, so its slices need not halve.
//!
//! **Some formats are not kept** (`_decode`): compressed and float textures
//! are unpacked as they are copied in. `format` is what is kept, and
//! `given_format` what was asked for.
//!
//! A swapchain's images are `rows` over the display's buffers, made by the
//! swapchain and never bound: what is drawn into one is handed on to the
//! display tile by tile (`Display`), as the display does not see what the
//! processor's caches hold.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const texture = facet.texture;
const shader = facet.shader;
const Device = @import("../device/_device.zig").Device;
const _memory = @import("../memory/_memory.zig");
const DeviceMemory = _memory.DeviceMemory;
const max_image_dimension = @import("../instance/_instance.zig").max_image_dimension;
const drawable = @import("../surface/_surface.zig").drawable;
const _decode = @import("_decode.zig");
const _instance = @import("../instance/_instance.zig");
const rtg = sdk.rtg;
const RtgBase = sdk.interface.rtg.RtgBase;

pub const Kind = enum { rows, texture, depth };

pub const Image = struct {
    device: *Device,
    format: facet.Format,
    /// What the program made it as, and copies texels in as.
    given_format: facet.Format,
    width: u32,
    height: u32,
    levels: u32,
    /// An array's layers, a cube's faces, or a 3D image's slices.
    layers: u32 = 1,
    layer_bytes: u64 = 0,
    /// A 3D image: its slices are reached by z, not by layer.
    volume: bool = false,
    /// A 1D image, which this library keeps as a texture of one row: its
    /// height and depth are 1 and its levels halve its width alone. The
    /// flag is what tells it from a 2D image a row high, which is a
    /// different thing to Vulkan and takes different view types.
    /// (Since 1.86.)
    line: bool = false,
    /// IMAGE_CREATE_CUBE_COMPATIBLE.
    cube: bool = false,
    /// IMAGE_CREATE_PACKED_TEXELS: an 8888 texel kept in the 32 bits of
    /// its word rather than spread over 64 (`texture.Format.argb8888`,
    /// `Capabilities.small_texels`, since 1.48).
    packed_texels: bool = false,
    usage: u32,
    kind: Kind,
    /// `rows`: the bytes from one row to the next.
    pitch: u32 = 0,
    /// What it needs of its memory, and what the memory's offset has to be
    /// a multiple of.
    bytes: u64,
    alignment: u64 = _memory.alignment,
    /// Where it is bound, and its first byte there; null in lazily
    /// allocated memory.
    memory: ?*DeviceMemory = null,
    offset: u64 = 0,
    data: ?[*]u8 = null,
    /// `texture`: its levels as a sample reads them, over its memory once
    /// bound. On a device that samples in its own way these say nothing of
    /// where the texels are.
    texels: texture.Texture = undefined,
    /// Where a device with a processor of its own reaches it; 0 until it has
    /// been asked for.
    driver_address: u32 = 0,
    /// A swapchain's: its memory is a buffer of the display's, never
    /// bound or destroyed by the program.
    presentable: bool = false,
    /// Where what is drawn into it is handed on to; null for memory the
    /// processor alone reads.
    display: ?Display = null,
};

/// A buffer of the display's an image is: each rectangle drawn into it
/// handed on with rtg's RefreshRect.
pub const Display = struct {
    rb: *RtgBase,
    bitmap: *rtg.RtgBitMap,

    pub fn handOn(display: Display, x: u32, y: u32, width: u32, height: u32) void {
        const rect = rtg.RtgRect{ .x = @intCast(x), .y = @intCast(y), .width = @intCast(width), .height = @intCast(height) };
        _ = display.rb.RefreshRect(display.bitmap, &rect);
    }
};

pub const ImageView = struct {
    image: *Image,
    base_level: u32,
    level_count: u32,
    base_layer: u32 = 0,
    layer_count: u32 = 1,
    /// `texture`: the levels it takes, as a sample reads them.
    texels: texture.Texture = undefined,
    /// `rows`: its pixels, for a fragment function of a later subpass to
    /// read (`IMAGE_USAGE_INPUT_ATTACHMENT`, `shader.Resources.input`).
    /// Nothing to read where the image is of another kind.
    rows: shader.Attachment = .{},
};

/// How a row of an image starts: on a cache line.
const row_alignment = 64;

/// Whether a format of an attachment has a depth.
pub fn hasDepth(format: facet.Format) bool {
    return format == .d16_unorm or format == .d16_unorm_s8_uint;
}

/// Whether a format of an attachment has a stencil.
pub fn hasStencil(format: facet.Format) bool {
    return format == .s8_uint or format == .d16_unorm_s8_uint;
}

/// Where a pixel's depth lies in its bytes, and where its stencil does:
/// `d16_unorm_s8_uint` holds the depth first and the stencil after it, and
/// a format of one alone holds it at the pixel's first byte.
pub fn depthOffset(format: facet.Format) u32 {
    _ = format;
    return 0;
}

pub fn stencilOffset(format: facet.Format) u32 {
    return if (hasDepth(format)) 2 else 0;
}

/// How a fragment function reads the pixels of an image kept in rows;
/// `.none` for a format rows are not kept in, a depth among them
/// (`shader.Attachment`).
pub fn rowFormat(format: facet.Format) shader.TexelFormat {
    return switch (format) {
        .b8g8r8a8_unorm => .bgra8888,
        .r8g8b8a8_unorm => .rgba8888,
        .r5g6b5_unorm_pack16 => .rgb565,
        else => .none,
    };
}

/// How a shader function writes the pixels of an image kept in rows, as
/// the texture over them (`texture.Texture.linear`): null for a format
/// whose rows no texture reads, which is every one whose texel is not a
/// word of its own. `r8g8b8a8_unorm` is one of those - a texture of 8888
/// is 0xAARRGGBB, as `b8g8r8a8_unorm`'s rows are, and nothing reads a
/// word with red in its low byte. (Since 1.56.)
pub fn rowTexture(format: facet.Format) ?texture.Format {
    return switch (format) {
        .b8g8r8a8_unorm => .argb8888,
        .r5g6b5_unorm_pack16 => .rgb565,
        else => null,
    };
}

/// Whether a texture of `format` keeps channels of its own rather than
/// the 8888 colour a sample makes of them
/// (`Capabilities.wide_channels`, since 1.69).
pub fn wideChannels(format: facet.Format) bool {
    return switch (format) {
        .r8g8_unorm, .r16_unorm, .r16g16_unorm, .r16g16b16a16_unorm => true,
        else => false,
    };
}

/// Whether a texture of `format` keeps whole numbers rather than a colour
/// or a part of one: Vulkan's `_uint` and `_sint` formats, one channel,
/// two or four, of 8, 16 or 32 bits
/// (`Capabilities.whole_textures`, since 1.70).
pub fn wholeNumbers(format: facet.Format) bool {
    return switch (format) {
        .r8_uint, .r8g8_uint, .r8g8b8a8_uint, .r8_sint, .r8g8_sint, .r8g8b8a8_sint => true,
        .r16_uint, .r16g16_uint, .r16g16b16a16_uint, .r16_sint, .r16g16_sint, .r16g16b16a16_sint => true,
        .r32_uint, .r32g32_uint, .r32g32b32a32_uint, .r32_sint, .r32g32_sint, .r32g32b32a32_sint => true,
        else => false,
    };
}

/// Whether an image kept in rows is written through as a storage image:
/// drawn into and written through at once, its rows being the texture a
/// function writes (`rowTexture`, since 1.56).
pub fn writtenRows(image: *const Image) bool {
    return image.kind == .rows and image.usage & facet.IMAGE_USAGE_STORAGE != 0;
}

/// The bytes a texel, a pixel or a vertex's value of `format` takes; 0
/// for one facet.library does not know.
pub fn bytesOf(format: facet.Format) u32 {
    return switch (format) {
        // One byte of red a texel (since 1.48).
        .s8_uint, .r8_unorm => 1,
        .r5g6b5_unorm_pack16, .d16_unorm => 2,
        // The channels a texture keeps as they lie (since 1.69).
        .r8g8_unorm, .r16_unorm => 2,
        .r16g16_unorm => 4,
        .r16g16b16a16_unorm => 8,
        // The whole numbers of 1.70: one channel, two or four, of 8, 16
        // or 32 bits.
        .r8_uint, .r8_sint => 1,
        .r8g8_uint, .r8g8_sint, .r16_uint, .r16_sint => 2,
        .r8g8b8a8_uint, .r8g8b8a8_sint, .r16g16_uint, .r16g16_sint, .r32_uint, .r32_sint => 4,
        .r16g16b16a16_uint, .r16g16b16a16_sint, .r32g32_uint, .r32g32_sint => 8,
        .r32g32b32a32_uint, .r32g32b32a32_sint => 16,
        .d16_unorm_s8_uint => 4,
        .r8g8b8a8_unorm, .b8g8r8a8_unorm, .r32_sfloat => 4,
        // The float formats a texture keeps as they lie (since 1.45), and
        // the vertex ones, which are the same sizes.
        .b10g11r11_ufloat_pack32, .e5b9g9r9_ufloat_pack32 => 4,
        .r16g16b16a16_sfloat, .r32g32_sfloat => 8,
        .r32g32b32_sfloat => 12,
        .r32g32b32a32_sfloat => 16,
        else => 0,
    };
}

/// How a sampled image of `format` keeps its texels, or null for a format
/// that cannot be sampled.
pub fn textureFormat(format: facet.Format) ?texture.Format {
    return keptFormat(format, false);
}

/// The same, with IMAGE_CREATE_PACKED_TEXELS: an 8888 texel is then kept
/// in the 32 bits of its word rather than spread over 64, which is the
/// same colour in half the memory (`Capabilities.small_texels`,
/// since 1.48). The flag means nothing to any other format.
pub fn keptFormat(format: facet.Format, packed_texels: bool) ?texture.Format {
    return switch (format) {
        .b8g8r8a8_unorm, .r8g8b8a8_unorm => if (packed_texels) .argb8888 else .rgba8888,
        .r5g6b5_unorm_pack16 => .rgb565,
        // One byte of red a texel, read as (red, 0, 0, 1) (since 1.48).
        .r8_unorm => .r8,
        // Kept in their blocks and decoded as they are sampled, on a
        // device that says so (`Capabilities.kept_compressed`).
        .bc1_rgba_unorm_block => .bc1,
        .bc1_rgb_unorm_block => .bc1_rgb,
        .bc2_unorm_block => .bc2,
        .bc3_unorm_block => .bc3,
        // One channel and two, each the block BC3 keeps its alpha in
        // (since 1.72).
        .bc4_unorm_block => .bc4,
        .bc5_unorm_block => .bc5,
        // Subsets, modes and indices, in the same 16 bytes (since 1.73).
        .bc7_unorm_block => .bc7,
        // And BC6H's three channels of half float (since 1.74).
        .bc6h_ufloat_block => .bc6hu,
        .bc6h_sfloat_block => .bc6hs,
        // Kept as the floats they were copied in as, and rounded to 8 bits
        // a channel as they are sampled, on a device that says so
        // (`Capabilities.kept_floats`).
        .r16g16b16a16_sfloat => .rgba16f,
        .r32g32b32a32_sfloat => .rgba32f,
        .b10g11r11_ufloat_pack32 => .rg11b10f,
        .e5b9g9r9_ufloat_pack32 => .rgb9e5,
        // One float a texel, read as (red, 0, 0, 1) (since 1.57): a
        // height field, a mask or an accumulation buffer a function
        // writes through.
        .r32_sfloat => .r32f,
        // Channels of the texture's own, kept as they lie, on a device
        // that says so (`Capabilities.wide_channels`, since
        // 1.69): two bytes of red and green, and 16 bits a channel.
        .r8g8_unorm => .rg8,
        .r16_unorm => .r16,
        .r16g16_unorm => .rg16,
        .r16g16b16a16_unorm => .rgba16,
        // Whole numbers, likewise kept as they lie, on a device that says
        // so (`Capabilities.whole_textures`, since 1.70).
        .r8_uint => .r8u,
        .r8g8_uint => .rg8u,
        .r8g8b8a8_uint => .rgba8u,
        .r8_sint => .r8i,
        .r8g8_sint => .rg8i,
        .r8g8b8a8_sint => .rgba8i,
        .r16_uint => .r16u,
        .r16g16_uint => .rg16u,
        .r16g16b16a16_uint => .rgba16u,
        .r16_sint => .r16i,
        .r16g16_sint => .rg16i,
        .r16g16b16a16_sint => .rgba16i,
        .r32_uint => .r32u,
        .r32g32_uint => .rg32u,
        .r32g32b32a32_uint => .rgba32u,
        .r32_sint => .r32i,
        .r32g32_sint => .rg32i,
        .r32g32b32a32_sint => .rgba32i,
        // A depth sampled where it lies, in rows
        // (`Capabilities.sampled_depth`).
        .d16_unorm => .d16,
        else => null,
    };
}

/// Whether an image is a depth attachment's that may also be sampled: its
/// rows are the texture, so nothing is copied and nothing kept twice.
pub fn sampledDepth(image: *const Image) bool {
    return image.kind == .depth and image.usage & facet.IMAGE_USAGE_SAMPLED != 0;
}

/// Whether a depth attachment's rows are read by anything after the pass
/// that drew them - sampled, or read pixel by pixel as an input attachment
/// (since 1.62) - and so want memory behind them rather than the tiles.
pub fn keptDepth(image: *const Image) bool {
    return image.kind == .depth and image.usage & (facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_INPUT_ATTACHMENT) != 0;
}

/// An image as `info` asks for it, not yet bound; null for one
/// facet.library does not make.
pub fn shapeOf(device: *Device, info: *const facet.ImageCreateInfo) ?Image {
    var made = shapeFor(device.physical, info) orelse return null;
    made.device = device;
    return made;
}

/// The same, for a physical device that no Device was made from yet: what
/// GetPhysicalDeviceImageFormatProperties asks of a shape. The image's
/// `device` is not filled in.
pub fn shapeFor(physical: *_instance.PhysicalDevice, info: *const facet.ImageCreateInfo) ?Image {
    const extent = info.extent;
    const volume = info.image_type == .@"3d";
    // A 1D image is a texture of one row (since 1.86). Vulkan asks that
    // its height and depth be 1, and the layout this library keeps halves
    // the longer side alone, so such a texture's levels come to
    // floor(log2(width)) + 1 of themselves (`texture.Sizes.of`) - which
    // is Vulkan's own rule for a 1D image. Nothing else about it is
    // special: it is sampled, copied and laid out as any texture of its
    // width is.
    const line = info.image_type == .@"1d";
    if ((info.image_type != .@"2d" and !volume and !line) or info.samples != 1) return null;
    if (line and (extent.height != 1 or extent.depth != 1)) return null;
    // A compressed format is no 1D image's, as neither Mesa driver makes
    // one (`lvp_get_image_format_properties`,
    // src/gallium/frontends/lavapipe/lvp_formats.c;
    // `v3dv_get_image_format_properties`, src/broadcom/vulkan/v3dv_formats.c),
    // its blocks being four rows high. Until 1.97 one was made, and the
    // layout of a level a block across overflowed (`texture.Level`).
    if (line and _decode.blockBytes(info.format) != 0) return null;
    const layers = if (volume) extent.depth else info.array_layers;
    if (layers == 0 or (!volume and extent.depth != 1)) return null;
    // A 3D image's depth is its layers, and may be any number since 1.46;
    // its levels are each slice's own (`texture.Texture.slicesAt`).
    if (volume and (info.array_layers != 1 or layers > _instance.max_image_dimension_3d)) return null;
    if (layers > _instance.max_image_array_layers) return null;
    const cube = info.flags & facet.IMAGE_CREATE_CUBE_COMPATIBLE != 0;
    if (cube and (volume or line or layers < 6 or extent.width != extent.height)) return null;
    // A texel kept smaller than the colour it reads as, on a device that
    // keeps one (`Capabilities.small_texels`, since 1.48): an
    // 8888 texel in the 32 bits of its word rather than spread over 64,
    // and a texel of one byte of red. Both are for an image a function
    // reads or writes; nothing else is kept in a texture's layout.
    const in_texels = info.usage & (facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_STORAGE) != 0;
    const packed_texels = info.flags & facet.IMAGE_CREATE_PACKED_TEXELS != 0;
    const packs = switch (info.format) {
        .r8g8b8a8_unorm, .b8g8r8a8_unorm => true,
        else => false,
    };
    if (packed_texels and !(physical.can.small_texels and in_texels and packs)) return null;
    if (info.format == .r8_unorm and !(physical.can.small_texels and in_texels)) return null;
    // A texture whose channels are its own, kept as they lie
    // (`Capabilities.wide_channels`, since 1.69): two bytes of
    // red and green, or 16 bits a channel. Such an image is for a
    // function to read or to write, as a small texel is, and a device
    // that keeps 8 bits a channel refuses it.
    if (wideChannels(info.format) and !(physical.can.wide_channels and in_texels)) return null;
    // And a texture of whole numbers, which a function reads with
    // `texture.Texture.wholesAt` and writes with `setWholes`
    // (`Capabilities.whole_textures`, since 1.70): no colour
    // carries one, so an image of such a format is for a function and
    // nothing else.
    if (wholeNumbers(info.format) and !(physical.can.whole_textures and in_texels)) return null;
    // Layers want `optimal` tiling, as a format unpacked on the way in
    // does: a linear image is one layer, which is all Vulkan promises of
    // one. Until 1.91 an image of layers was also one a function reads or
    // writes - sampled, or written through and never sampled since 1.55 -
    // and an attachment had the one. Since 1.91 an attachment may have
    // them too, a colour attachment's rows or a depth attachment's a
    // layer after the layer before, for a framebuffer of layers
    // (CreateFramebuffer); so may an image a transfer alone touches. A 3D
    // image's slices are not such layers and stay a function's: a pass
    // draws into a slice through a 2D view of it, which is Vulkan 1.1's
    // (VK_KHR_maintenance1's IMAGE_CREATE_2D_ARRAY_COMPATIBLE), not 1.0's.
    if ((layers > 1 or _decode.unpacks(info.format)) and info.tiling != .optimal) return null;
    if (layers > 1 and volume and !in_texels) return null;
    // A compressed image is kept in its blocks, and a float one in its
    // floats, where this device samples them
    // (`Capabilities.kept_compressed`, `kept_floats`); where it
    // does not they are unpacked into 8 bits a channel. A storage image is
    // written texel by texel, which neither kind takes.
    const writes_texels = info.usage & facet.IMAGE_USAGE_STORAGE != 0;
    // An ETC2 or EAC block is never kept: no sampler of this library reads
    // one, so such an image is unpacked whatever the device says.
    const keeps_blocks = physical.can.kept_compressed and _decode.blockBytes(info.format) != 0 and !_decode.etc(info.format) and !writes_texels;
    // A float image keeps its floats even where a function writes it
    // through, since 1.57: `texture.Texture.setParts` writes one texel of
    // floats, where nothing writes one texel of a compressed block.
    const keeps_floats = physical.can.kept_floats and _decode.texelBytes(info.format) != 0;
    const kept_format: facet.Format = if (_decode.unpacks(info.format) and !(keeps_blocks or keeps_floats)) .r8g8b8a8_unorm else info.format;
    // What is unpacked on the way in is unpacked to be sampled: a format
    // kept as it lies - a compressed image's blocks, a float one's floats
    // - is not (since 1.57, where a float image written through keeps its
    // floats and so needs no sampling).
    if (kept_format != info.format and info.usage & facet.IMAGE_USAGE_SAMPLED == 0) return null;
    if (extent.width == 0 or extent.height == 0 or extent.width > max_image_dimension or extent.height > max_image_dimension) return null;
    if (info.mip_levels == 0) return null;
    // A block's bytes stand in for a texel's where the blocks are kept:
    // what rows would take is never asked of such an image, which is
    // sampled and nothing else.
    const pixel = if (keeps_blocks) _decode.blockBytes(info.format) else bytesOf(kept_format);
    if (pixel == 0) return null;
    var image = Image{
        .device = undefined,
        .format = kept_format,
        .given_format = info.format,
        .layers = layers,
        .volume = volume,
        .line = line,
        .cube = cube,
        .packed_texels = packed_texels,
        .width = extent.width,
        .height = extent.height,
        .levels = info.mip_levels,
        .usage = info.usage,
        .kind = .rows,
        .bytes = 0,
    };
    const depth_usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT |
        facet.IMAGE_USAGE_TRANSFER_SRC | facet.IMAGE_USAGE_TRANSFER_DST;
    if (hasDepth(info.format) or hasStencil(info.format)) {
        // Sampled as well, since 1.39: its rows are the texture, and it
        // wants memory behind it, which `requirements` holds to. Any of
        // the three formats since 1.58, each plane read through a view of
        // that aspect (`depthPlane`): the depth as 16 bits, and the
        // stencil as one byte of every four where the format holds both.
        // Read as an input attachment as well, since 1.62: a later
        // subpass reads the plane pixel by pixel where it lies, which
        // wants the same memory behind it that a sampled one does.
        const sampled = info.usage & facet.IMAGE_USAGE_SAMPLED != 0;
        const read_back = info.usage & facet.IMAGE_USAGE_INPUT_ATTACHMENT != 0;
        if (sampled or read_back) {
            if (!physical.can.sampled_depth) return null;
            if (info.usage & facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT != 0) return null;
        }
        var allowed = depth_usage;
        if (sampled) allowed |= facet.IMAGE_USAGE_SAMPLED;
        if (read_back) allowed |= facet.IMAGE_USAGE_INPUT_ATTACHMENT;
        if (info.usage & facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT == 0 or info.usage & ~allowed != 0) return null;
        // Levels since 1.63, and never a volume: a pass draws into the
        // rows of the level its framebuffer's view names, and a slice of
        // a 3D image is nothing it draws into.
        if (info.tiling != .optimal or volume) return null;
        if (info.mip_levels > mostLevels(extent.width, extent.height)) return null;
        image.kind = .depth;
        // Rows, like a colour attachment's: what a render pass that stores
        // its depth writes, and what a transfer reads (`readTexel`). A
        // transient one is never written and takes the same shape.
        image.pitch = std.mem.alignForward(u32, extent.width * pixel, row_alignment);
        // Layers since 1.58, levels since 1.63: a level's rows one after
        // another, each on a cache line, then the level after it, and
        // the whole pyramid again for each layer. A framebuffer's view
        // names the level and the layer a pass draws into, and a sample
        // reads any of them.
        image.layer_bytes = 0;
        for (0..info.mip_levels) |lod| image.layer_bytes += depthLevelBytes(&image, @intCast(lod));
        image.bytes = image.layer_bytes * layers;
        return image;
    }
    if (info.usage & facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT != 0) return null;
    // Drawn into, or read as an input attachment, and written through as a
    // storage image at once (since 1.56): the image stays in rows, as an
    // attachment is, and a function writes those rows. Never sampled as
    // well, a sample wanting the blocked layout, and of a format whose
    // rows a texture reads.
    const rows_written = info.usage & facet.IMAGE_USAGE_STORAGE != 0 and
        info.usage & facet.IMAGE_USAGE_SAMPLED == 0 and
        info.usage & (facet.IMAGE_USAGE_COLOR_ATTACHMENT | facet.IMAGE_USAGE_INPUT_ATTACHMENT) != 0 and
        info.usage & facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT == 0 and
        rowTexture(info.format) != null and info.mip_levels == 1 and layers == 1;
    // Read as an input attachment: its pixels are read out of its rows,
    // so not in a texture's layout and not a transient attachment, which
    // has no memory at all.
    if (info.usage & facet.IMAGE_USAGE_INPUT_ATTACHMENT != 0) {
        const not_rows = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT;
        if (info.usage & not_rows != 0) return null;
        if (info.usage & facet.IMAGE_USAGE_STORAGE != 0 and !rows_written) return null;
    }
    // Sampled, written through as a storage image, or both: all one kind,
    // kept in the layout a sample reads.
    if (info.usage & (facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_STORAGE) != 0 and !rows_written) {
        if (info.tiling != .optimal or info.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT != 0) return null;
        const kept = keptFormat(kept_format, packed_texels) orelse return null;
        image.kind = .texture;
        var one_layer: u64 = texture.Texture.bytes(kept, extent.width, extent.height, info.mip_levels) catch return null;
        one_layer = std.mem.alignForward(u64, one_layer, row_alignment);
        if (physical.ops.texture_memory) |own| {
            const memory = own(kept_format, extent.width, extent.height, info.mip_levels);
            one_layer = std.mem.alignForward(u64, memory.bytes, memory.alignment);
            image.alignment = memory.alignment;
        }
        image.layer_bytes = one_layer;
        image.bytes = one_layer * layers;
        // Its levels' layout, over no memory yet: BindImageMemory moves it.
        image.texels = texelsOver(&image, @ptrFromInt(_memory.alignment)) catch return null;
        return image;
    }
    if (info.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT != 0 and !drawable(info.format)) return null;
    // Rows of a colour format, of one level, and a layer's rows after the
    // layer before (since 1.91): `rowsAt` finds a layer's first row, and a
    // framebuffer's view the layer a pass begins at.
    if (info.mip_levels != 1 or textureFormat(info.format) == null) return null;
    image.pitch = std.mem.alignForward(u32, extent.width * pixel, row_alignment);
    image.layer_bytes = @as(u64, image.pitch) * extent.height;
    image.bytes = image.layer_bytes * layers;
    // Written through as a storage image as well: the rows are the
    // texture a function writes, over no memory yet (since 1.56).
    if (rows_written) image.texels = texelsOver(&image, @ptrFromInt(_memory.alignment)) catch return null;
    return image;
}

/// A texture image's levels and layers as a sample reads them, over `memory`.
/// A depth image's rows are the texture themselves: one level, of whatever
/// size the image is (`texture.Texture.linear`).
pub fn texelsOver(image: *const Image, memory: [*]u8) texture.Texture.Error!texture.Texture {
    // Its own plane, all its layers: the depth where the format has one
    // and the stencil where it has not. The aspect a view asks for picks
    // the plane again (`depthPlane`, since 1.58).
    if (image.kind == .depth) return planeOver(image, 0, 0, image.levels, 0, image.layers, memory).?;
    // A colour attachment written through as a storage image: its rows
    // are the texture, as a sampled depth's are (since 1.56).
    if (writtenRows(image)) return texture.Texture.linear(rowTexture(image.format).?, image.width, image.height, image.pitch, memory);
    var made = try texture.Texture.init(keptFormat(image.format, image.packed_texels).?, image.width, image.height, image.levels, memory);
    made.layer_count = image.layers;
    made.layer_bytes = @intCast(image.layer_bytes);
    return made;
}

/// What an image needs of its memory: a depth attachment any type, the
/// lazily allocated one too; the rest a type with something behind it - a
/// depth one that is sampled among them, its rows being read.
pub fn requirements(image: *const Image) facet.MemoryRequirements {
    const properties = &image.device.physical.memory;
    const anywhere = image.kind == .depth and !keptDepth(image);
    return .{
        .size = image.bytes,
        .alignment = image.alignment,
        .memory_type_bits = if (anywhere) _memory.allTypes(properties) else _memory.backedTypes(properties),
    };
}

/// One plane of a depth attachment's rows as a texture, over `memory`:
/// `aspect` says which, and `first_layer` and `layers` which of them. The
/// depth is 16 bits at the pixel's first byte and the stencil one byte
/// where the pixel keeps it (`depthOffset`, `stencilOffset`), each read
/// `bytesOf` bytes apart - so a format that holds both is two planes
/// inside the same rows. An `aspect` naming neither plane, which is what
/// a view asking for the colour takes - the default, and what every view
/// of such an image took before 1.58 - is the format's own plane: its
/// depth where it has one, and its stencil where it has not. Both planes
/// at once, of a format holding both, is its depth since 1.94: such a view
/// is a framebuffer's, which draws into both whatever the view names, and
/// no descriptor may hold one, so this is only what a sample of it would
/// read regardless - lavapipe's answer, which takes the stencil for the
/// stencil alone (`lvp_create_samplerview`). Null for an aspect the format
/// has not got. (Since 1.58.)
fn planeOver(image: *const Image, aspect: u32, first_level: u32, levels: u32, first_layer: u32, layers: u32, memory: [*]u8) ?texture.Texture {
    const plane = planeAt(image, aspect) orelse return null;
    // The depth is read as 16 bits of depth and the stencil as one byte,
    // which `texture.Format.r8` reads as (red, 0, 0, 1).
    const kept: texture.Format = if (plane.depth) .d16 else .r8;
    const first = levelSize(image, first_level);
    const begins = @as(usize, @intCast(depthLevelAt(image, first_level)));
    var made = texture.Texture.linearBy(kept, first[0], first[1], depthPitch(image, first_level), plane.stride, memory + plane.at + first_layer * @as(usize, @intCast(image.layer_bytes)) + begins);
    // The levels after the first, each in rows as wide as that level is,
    // where it lies inside the layer (since 1.63).
    for (first_level + 1..first_level + levels) |lod| {
        const size = levelSize(image, @intCast(lod));
        const at = @as(usize, @intCast(depthLevelAt(image, @intCast(lod)))) - begins;
        made.linearLevel(size[0], size[1], @intCast(at), depthPitch(image, @intCast(lod)));
    }
    made.layer_count = layers;
    made.layer_bytes = @intCast(image.layer_bytes);
    return made;
}

/// Where one plane of a depth attachment's pixels lies: `at` the bytes
/// into a pixel it begins at, `stride` the bytes from one pixel to the
/// next, and `depth` whether it is the depth or the stencil. (Since 1.62,
/// from `planeOver`, which picked the plane by itself before.)
const Plane = struct { at: u32, stride: u32, depth: bool };

/// The plane `aspect` names, by the rule `planeOver` describes: null for
/// an aspect the format has not got.
/// (Since 1.62.)
fn planeAt(image: *const Image, aspect: u32) ?Plane {
    const both = facet.IMAGE_ASPECT_DEPTH | facet.IMAGE_ASPECT_STENCIL;
    const asked = aspect & both;
    const stride = bytesOf(image.format);
    if (stride == 0) return null;
    // Both at once, of a format that holds both, is the depth (since
    // 1.94). Of a format holding one plane alone it names the other as
    // well, which that format has not got.
    const holds_both = hasDepth(image.format) and hasStencil(image.format);
    const planes = if (asked == both and holds_both)
        facet.IMAGE_ASPECT_DEPTH
    else if (asked != 0)
        asked
    else if (hasDepth(image.format))
        facet.IMAGE_ASPECT_DEPTH
    else
        facet.IMAGE_ASPECT_STENCIL;
    const wants_depth = planes == facet.IMAGE_ASPECT_DEPTH;
    const wants_stencil = planes == facet.IMAGE_ASPECT_STENCIL;
    if (wants_depth and !hasDepth(image.format)) return null;
    if (wants_stencil and !hasStencil(image.format)) return null;
    if (!wants_depth and !wants_stencil) return null;
    const at = if (wants_depth) depthOffset(image.format) else stencilOffset(image.format);
    if (at >= stride) return null;
    return .{ .at = at, .stride = stride, .depth = wants_depth };
}

/// How many levels a depth attachment of that size may have: the longer
/// side halved until it is one, and no more than a texture's layout holds.
/// (Since 1.63.)
fn mostLevels(width: u32, height: u32) u32 {
    const longer = @max(width, height);
    return @min(32 - @clz(longer), texture.most_levels);
}

/// The bytes from one row of a level of a depth attachment to the next:
/// the level's own width in pixels, on a cache line. (Since 1.63.)
pub fn depthPitch(image: *const Image, level: u32) u32 {
    return std.mem.alignForward(u32, @max(image.width >> @intCast(level), 1) * bytesOf(image.format), row_alignment);
}

/// What one level of one layer of a depth attachment takes: its rows, the
/// last of them on a cache line so that the level after it begins on one.
/// (Since 1.63.)
fn depthLevelBytes(image: *const Image, level: u32) u64 {
    const height = @max(image.height >> @intCast(level), 1);
    return std.mem.alignForward(u64, @as(u64, depthPitch(image, level)) * height, row_alignment);
}

/// Where a level of a depth attachment begins inside a layer, in bytes:
/// the levels before it, each its own rows. (Since 1.63.)
pub fn depthLevelAt(image: *const Image, level: u32) u64 {
    var at: u64 = 0;
    for (0..level) |lod| at += depthLevelBytes(image, @intCast(lod));
    return at;
}

/// Where a level of a layer of an image kept in rows begins, in bytes from
/// the image's memory, and the bytes from one of its rows to the next. A
/// depth attachment may have levels since 1.63, each in rows of its own
/// inside the layer; every other image kept in rows has the one level, at
/// the layer's start.
pub fn rowsAt(image: *const Image, level: u32, layer: u32) struct { at: usize, pitch: u32 } {
    const layer_at = layer * @as(usize, @intCast(image.layer_bytes));
    if (image.kind != .depth) return .{ .at = layer_at, .pitch = image.pitch };
    return .{ .at = layer_at + @as(usize, @intCast(depthLevelAt(image, level))), .pitch = depthPitch(image, level) };
}

/// One plane of a depth attachment's rows as an input attachment reads
/// them, pixel by pixel: the layer the view names, the depth as `r16` -
/// 0 to 1, nearest first - and the stencil as `r8u`, the whole number
/// it is, each read `stride` bytes apart so that a format holding both is
/// two planes inside the same rows. Null for an image with no memory
/// behind it, or for an aspect the format has not got. (Since 1.62.)
pub fn depthRows(image: *const Image, aspect: u32, level: u32, first_layer: u32) ?shader.Attachment {
    const data = image.data orelse return null;
    const plane = planeAt(image, aspect) orelse return null;
    const rows = rowsAt(image, level, first_layer);
    const size = levelSize(image, level);
    return .{
        .bytes = data + rows.at + plane.at,
        .pitch = rows.pitch,
        .width = size[0],
        .height = size[1],
        .format = if (plane.depth) .r16 else .r8u,
        .stride = plane.stride,
    };
}

/// The same over the image's own memory, for a view of it: the levels and
/// the layers it names (levels since 1.63). (Since 1.58.)
pub fn depthPlane(image: *const Image, aspect: u32, first_level: u32, levels: u32, first_layer: u32, layers: u32) ?texture.Texture {
    return planeOver(image, aspect, first_level, levels, first_layer, layers, image.data orelse return null);
}

/// A texture image's levels from `base` on, `count` of them, of the layers
/// from `first_layer` on, `layers` of them, over its memory as a sample reads
/// them.
pub fn levelsFrom(image: *const Image, base: u32, count: u32, first_layer: u32, layers: u32) texture.Texture {
    const whole = &image.texels;
    // The levels of the whole from `base` on, laid out as the whole laid
    // them out: a width that is not a power of two is laid out by the next
    // one up, which a texture of that level's own size would not be
    // (`texture.Texture.from`).
    var made = texture.Texture.from(whole, base, count, whole.memory + first_layer * @as(usize, @intCast(image.layer_bytes)) + whole.layout[base].start);
    made.layer_count = layers;
    made.layer_bytes = @intCast(image.layer_bytes);
    return made;
}

/// The layers a copy's subresource and depth reach.
pub const LayerRange = struct { first: u32, count: u32 };

/// Of `image`, the layers a region names and has: by z and depth in a 3D
/// image, as it has them along z, else by the subresource. Null for none.
pub fn layersOf(image: *const Image, subresource: facet.ImageSubresourceLayers, z: i32, depth: u32) ?LayerRange {
    if (image.volume) {
        // A level of a 3D image is as deep as halving its depth that often
        // gives, and no less than one slice (`texture.Texture.slicesAt`).
        const slices = image.texels.slicesAt(subresource.mip_level);
        if (z < 0 or z >= slices or depth == 0) return null;
        const first: u32 = @intCast(z);
        return .{ .first = first, .count = @min(depth, slices - first) };
    }
    if (subresource.base_array_layer >= image.layers or subresource.layer_count == 0) return null;
    return .{ .first = subresource.base_array_layer, .count = @min(subresource.layer_count, image.layers - subresource.base_array_layer) };
}

/// Whether what is copied into an image has to be unpacked.
pub fn unpacks(image: *const Image) bool {
    return image.given_format != image.format;
}

/// Whether an image's texels lie compressed where they were copied in, in
/// blocks of 4 x 4 texels (`Capabilities.kept_compressed`): a
/// sample decodes the block it reads, and a copy moves whole blocks.
pub fn blocked(image: *const Image) bool {
    return _decode.blockBytes(image.format) != 0;
}

/// The bytes of one of a blocked image's blocks; 0 for another image.
pub fn blockBytes(image: *const Image) u32 {
    return _decode.blockBytes(image.format);
}

/// Whether an image's texels are the floats they were copied in as
/// (`Capabilities.kept_floats`): a sample rounds one to 8 bits a
/// channel as it reads it, and a copy moves its bytes as they lie.
pub fn floatTexels(image: *const Image) bool {
    return _decode.texelBytes(image.format) != 0;
}

/// Whether an image's texels are moved as they lie rather than through a
/// colour word of 8 bits a channel: a float one's, and a texture whose
/// channels are its own (`wideChannels`, since 1.69). Both keep what they
/// were copied in as, so a copy out reads it back unchanged.
pub fn keptTexels(image: *const Image) bool {
    return floatTexels(image) or wideChannels(image.format) or wholeNumbers(image.format);
}

/// The block holding texel (x, y) of a level of a layer, into `into`;
/// nothing where the image is not blocked.
pub fn readBlock(image: *const Image, level: u32, layer: u32, x: u32, y: u32, into: []u8) void {
    image.texels.blockBytesAt(layer, level, x, y, into);
}

/// The same written, as a copy into a compressed image moves it.
pub fn writeBlock(image: *Image, level: u32, layer: u32, x: u32, y: u32, from: []const u8) void {
    image.texels.putBlock(layer, level, x, y, from);
}

/// The colour of texel (x, y), 0xAARRGGBB, decoded out of the block it
/// lies in: what a blit reads of a compressed image, there being no texel
/// of its own in memory.
pub fn blockColor(image: *const Image, level: u32, layer: u32, x: u32, y: u32) u32 {
    return image.texels.peekLayer(layer, level, x, y);
}

/// Blocks of a compressed format from a buffer's bytes into a level of an
/// image that keeps them, as they lie: the part of the rectangle outside
/// the image, or past the end of `from`, left out. Blocks start on a
/// multiple of 4, as Vulkan asks.
pub fn copyBlocks(image: *Image, from: []const u8, region: *const facet.BufferImageCopy) void {
    if (image.data == null) return;
    const level = region.image_subresource.mip_level;
    if (level >= image.levels or region.image_offset.x < 0 or region.image_offset.y < 0) return;
    const size = levelSize(image, level);
    const left: u32 = @intCast(region.image_offset.x);
    const top: u32 = @intCast(region.image_offset.y);
    if (left >= size[0] or top >= size[1]) return;
    if (left % 4 != 0 or top % 4 != 0) return;
    const width = @min(region.image_extent.width, size[0] - left);
    const height = @min(region.image_extent.height, size[1] - top);
    const range = layersOf(image, region.image_subresource, region.image_offset.z, region.image_extent.depth) orelse return;
    // A buffer holds a compressed image in blocks: a row of them is
    // `buffer_row_length` texels across, which is what Vulkan counts here.
    const row_length = if (region.buffer_row_length != 0) region.buffer_row_length else region.image_extent.width;
    const slice_height = if (region.buffer_image_height != 0) region.buffer_image_height else region.image_extent.height;
    const start = std.math.cast(usize, region.buffer_offset) orelse return;
    const wide = blockBytes(image);
    const pitch = @as(usize, (row_length + 3) / 4) * wide;
    for (0..range.count) |slice| {
        const layer = range.first + @as(u32, @intCast(slice));
        const slice_at = start + slice * @as(usize, (slice_height + 3) / 4) * pitch;
        for (0..(height + 3) / 4) |row| for (0..(width + 3) / 4) |column| {
            const at = slice_at + row * pitch + column * wide;
            if (at + wide > from.len) return;
            writeBlock(image, level, layer, left + @as(u32, @intCast(column * 4)), top + @as(u32, @intCast(row * 4)), from[at..][0..wide]);
        };
    }
}

/// A rectangle of a compressed or a float format from a buffer's bytes into
/// a level of an image, unpacked; the part of it outside the image, or past
/// the end of `from`, left out. Blocks start on a multiple of 4.
pub fn copyUnpacking(image: *Image, from: []const u8, region: *const facet.BufferImageCopy) void {
    if (image.data == null) return;
    const level = region.image_subresource.mip_level;
    if (level >= image.levels or region.image_offset.x < 0 or region.image_offset.y < 0) return;
    const size = levelSize(image, level);
    const left: u32 = @intCast(region.image_offset.x);
    const top: u32 = @intCast(region.image_offset.y);
    if (left >= size[0] or top >= size[1]) return;
    const width = @min(region.image_extent.width, size[0] - left);
    const height = @min(region.image_extent.height, size[1] - top);
    const range = layersOf(image, region.image_subresource, region.image_offset.z, region.image_extent.depth) orelse return;
    const row_length = if (region.buffer_row_length != 0) region.buffer_row_length else region.image_extent.width;
    const slice_height = if (region.buffer_image_height != 0) region.buffer_image_height else region.image_extent.height;
    const start = std.math.cast(usize, region.buffer_offset) orelse return;
    const block = _decode.blockBytes(image.given_format);
    for (0..range.count) |slice| {
        const layer = range.first + @as(u32, @intCast(slice));
        if (block != 0) {
            if (left % 4 != 0 or top % 4 != 0) return;
            const pitch = @as(usize, (row_length + 3) / 4) * block;
            const slice_at = start + slice * @as(usize, (slice_height + 3) / 4) * pitch;
            for (0..(height + 3) / 4) |row| for (0..(width + 3) / 4) |column| {
                const at = slice_at + row * pitch + column * block;
                if (at + block > from.len) return;
                const texels = _decode.block16(image.given_format, from[at..][0..block]);
                for (texels, 0..) |rgba, k| {
                    const x = left + @as(u32, @intCast(column * 4 + k % 4));
                    const y = top + @as(u32, @intCast(row * 4 + k / 4));
                    if (x < left + width and y < top + height) writeTexel(image, level, layer, x, y, &rgba);
                }
            };
        } else {
            const texel = _decode.texelBytes(image.given_format);
            const pitch = @as(usize, row_length) * texel;
            const slice_at = start + slice * @as(usize, slice_height) * pitch;
            for (0..height) |row| for (0..width) |column| {
                const at = slice_at + row * pitch + column * texel;
                if (at + texel > from.len) return;
                const rgba = _decode.texel(image.given_format, from[at..][0..texel]);
                writeTexel(image, level, layer, left + @as(u32, @intCast(column)), top + @as(u32, @intCast(row)), &rgba);
            };
        }
    }
}

/// A rectangle of texels copied from a buffer's bytes into a level of an
/// image, as `region` says, in the image's format: converted to the
/// texture layout for a texture, row by row for rows. The part of the
/// rectangle outside the image, or past the end of `from`, is left out.
pub fn copyFromBuffer(image: *Image, from: []const u8, region: *const facet.BufferImageCopy) void {
    if (image.data == null) return;
    if (unpacks(image)) return copyUnpacking(image, from, region);
    if (blocked(image)) return copyBlocks(image, from, region);
    const level = region.image_subresource.mip_level;
    if (level >= image.levels or region.image_offset.x < 0 or region.image_offset.y < 0) return;
    const range = layersOf(image, region.image_subresource, region.image_offset.z, region.image_extent.depth) orelse return;
    const level_width = @max(image.width >> @intCast(level), 1);
    const level_height = @max(image.height >> @intCast(level), 1);
    const left: u32 = @intCast(region.image_offset.x);
    const top: u32 = @intCast(region.image_offset.y);
    if (left >= level_width or top >= level_height) return;
    const width = @min(region.image_extent.width, level_width - left);
    const height = @min(region.image_extent.height, level_height - top);
    const pixel = bytesOf(image.format);
    // An image that keeps what it is given - a float one's floats, or a
    // texture's own channels since 1.69 - takes the texel's bytes as they
    // lie rather than through a colour of 8 bits a channel.
    const keeps = keptTexels(image);
    const row_length = if (region.buffer_row_length != 0) region.buffer_row_length else region.image_extent.width;
    const source_pitch = @as(usize, row_length) * pixel;
    const slice_height = if (region.buffer_image_height != 0) region.buffer_image_height else region.image_extent.height;
    const start = std.math.cast(usize, region.buffer_offset) orelse return;
    for (0..range.count) |slice| {
        const layer = range.first + @as(u32, @intCast(slice));
        for (0..height) |row| {
            const at = start + slice * slice_height * source_pitch + row * source_pitch;
            if (at + width * pixel > from.len) return;
            const source = from[at..][0 .. width * pixel];
            const y = top + @as(u32, @intCast(row));
            switch (image.kind) {
                .rows, .depth => {
                    // A depth image may have layers since 1.58 and levels
                    // since 1.63; a rows one has the one level, and
                    // layers since 1.91.
                    const rows = rowsAt(image, level, layer);
                    const into = image.data.? + rows.at + @as(usize, y) * rows.pitch + @as(usize, left) * pixel;
                    @memcpy(into[0..source.len], source);
                },
                .texture => for (0..width) |column| {
                    const x = left + @as(u32, @intCast(column));
                    if (keeps) {
                        image.texels.putTexels(layer, level, x, y, source[column * pixel ..]);
                    } else {
                        image.texels.putLayer(layer, level, x, y, texelOf(image.format, source[column * pixel ..]));
                    }
                },
            }
        }
    }
}

/// A texel as a buffer holds it in `format`, as a texture keeps it:
/// 0xAARRGGBB for 8888, the 16 bits as they are for 565.
fn texelOf(format: facet.Format, bytes: []const u8) u32 {
    return switch (format) {
        .b8g8r8a8_unorm => std.mem.readInt(u32, bytes[0..4], .little),
        .r8g8b8a8_unorm => texel: {
            const color = std.mem.readInt(u32, bytes[0..4], .little);
            break :texel color & 0xFF00_FF00 | (color >> 16 & 0xFF) | (color & 0xFF) << 16;
        },
        .r5g6b5_unorm_pack16 => std.mem.readInt(u16, bytes[0..2], .little),
        // One byte of red, kept as it lies (since 1.48).
        .r8_unorm => bytes[0],
        else => 0,
    };
}

/// Where a level's texels are on a device with a layout of its own, in bytes
/// from the image's memory.
fn deviceOffset(image: *const Image, level: u32, layer: u32, x: u32, y: u32) ?usize {
    const offset = image.device.physical.ops.texture_offset orelse return null;
    return layer * @as(usize, @intCast(image.layer_bytes)) + offset(image, level, x, y);
}

/// Whether an image's texels can be read and written: it has memory, and they
/// are not only in the tiles.
pub fn readable(image: *const Image) bool {
    return image.data != null;
}

/// A level's width and height.
pub fn levelSize(image: *const Image, level: u32) [2]u32 {
    return .{ @max(image.width >> @intCast(level), 1), @max(image.height >> @intCast(level), 1) };
}

/// Texel (x, y) of a level of a layer as a buffer would hold it, in `into`.
pub fn readTexel(image: *const Image, level: u32, layer: u32, x: u32, y: u32, into: []u8) void {
    switch (image.kind) {
        // A depth image is rows as well, of the level and the layer
        // asked for: what a pass that stores its depth wrote.
        .rows, .depth => {
            const pixel = bytesOf(image.format);
            const rows = rowsAt(image, level, layer);
            const from = image.data.? + rows.at + @as(usize, y) * rows.pitch + @as(usize, x) * pixel;
            @memcpy(into[0..pixel], from[0..pixel]);
        },
        .texture => if (deviceOffset(image, level, layer, x, y)) |offset| {
            const pixel = bytesOf(image.format);
            @memcpy(into[0..pixel], (image.data.? + offset)[0..pixel]);
        } else if (keptTexels(image)) {
            // The floats, or the channels, as they lie: what went in
            // comes out again.
            image.texels.texelsAt(layer, level, x, y, into);
        } else {
            bytesOfTexel(image.format, image.texels.peekLayer(layer, level, x, y), into);
        },
    }
}

/// Texel (x, y) of a level of a layer set from what a buffer would hold.
pub fn writeTexel(image: *Image, level: u32, layer: u32, x: u32, y: u32, from: []const u8) void {
    switch (image.kind) {
        .rows, .depth => {
            const pixel = bytesOf(image.format);
            const rows = rowsAt(image, level, layer);
            const into = image.data.? + rows.at + @as(usize, y) * rows.pitch + @as(usize, x) * pixel;
            @memcpy(into[0..pixel], from[0..pixel]);
        },
        .texture => if (deviceOffset(image, level, layer, x, y)) |offset| {
            const pixel = bytesOf(image.format);
            @memcpy((image.data.? + offset)[0..pixel], from[0..pixel]);
        } else if (keptTexels(image)) {
            image.texels.putTexels(layer, level, x, y, from);
        } else {
            image.texels.putLayer(layer, level, x, y, texelOf(image.format, from));
        },
    }
}

/// A texture's texel as a buffer holds it in `format`: `texelOf` undone.
fn bytesOfTexel(format: facet.Format, texel: u32, into: []u8) void {
    switch (format) {
        .b8g8r8a8_unorm => std.mem.writeInt(u32, into[0..4], texel, .little),
        .r8g8b8a8_unorm => std.mem.writeInt(u32, into[0..4], texel & 0xFF00_FF00 | (texel >> 16 & 0xFF) | (texel & 0xFF) << 16, .little),
        .r5g6b5_unorm_pack16 => std.mem.writeInt(u16, into[0..2], @truncate(texel), .little),
        .r8_unorm => into[0] = @truncate(texel),
        else => {},
    }
}

/// What a buffer holds in `format` as 0xAARRGGBB.
pub fn colorOfBytes(format: facet.Format, bytes: []const u8) u32 {
    return switch (format) {
        .b8g8r8a8_unorm => std.mem.readInt(u32, bytes[0..4], .little),
        .r8g8b8a8_unorm => color: {
            const color = std.mem.readInt(u32, bytes[0..4], .little);
            break :color color & 0xFF00_FF00 | (color >> 16 & 0xFF) | (color & 0xFF) << 16;
        },
        .r5g6b5_unorm_pack16 => color: {
            const packed_color: u32 = std.mem.readInt(u16, bytes[0..2], .little);
            const r = packed_color >> 11 & 0x1F;
            const g = packed_color >> 5 & 0x3F;
            const b = packed_color & 0x1F;
            break :color 0xFF00_0000 | (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2);
        },
        // Red alone, as Vulkan reads a one-channel format.
        .r8_unorm => texture.redOf8(bytes[0]),
        // The channels a texture keeps as they lie, as the colour of
        // their top 8 bits (since 1.69).
        .r8g8_unorm, .r16_unorm, .r16g16_unorm, .r16g16b16a16_unorm => texture.channelColor(keptFormat(format, false).?, bytes.ptr),
        else => if (wholeNumbers(format))
            // The whole numbers held to the colour they stand for (since
            // 1.70): nothing, or the channel at the full.
            texture.wholeColor(keptFormat(format, false).?, bytes.ptr)
        else
            0,
    };
}

/// 0xAARRGGBB as a buffer holds it in `format`, rounded where it has less.
pub fn bytesOfColor(format: facet.Format, color: u32, into: []u8) void {
    switch (format) {
        .b8g8r8a8_unorm, .r8g8b8a8_unorm => bytesOfTexel(format, color, into),
        // Each channel of the colour at the width that channel has
        // (since 1.69).
        .r8g8_unorm, .r16_unorm, .r16g16_unorm, .r16g16b16a16_unorm => texture.putChannelParts(keptFormat(format, false).?, into.ptr, texture.partsOfColor(color)),
        // And the colour's four channels as the whole numbers 0 to 255
        // they are (since 1.70).
        .r8_uint, .r8g8_uint, .r8g8b8a8_uint, .r8_sint, .r8g8_sint, .r8g8b8a8_sint, .r16_uint, .r16g16_uint, .r16g16b16a16_uint, .r16_sint, .r16g16_sint, .r16g16b16a16_sint, .r32_uint, .r32g32_uint, .r32g32b32a32_uint, .r32_sint, .r32g32_sint, .r32g32b32a32_sint => texture.putWholeParts(keptFormat(format, false).?, into.ptr, texture.wholesOfColor(color)),
        .r5g6b5_unorm_pack16 => {
            const r = ((color >> 16 & 0xFF) * 31 + 127) / 255;
            const g = ((color >> 8 & 0xFF) * 63 + 127) / 255;
            const b = ((color & 0xFF) * 31 + 127) / 255;
            std.mem.writeInt(u16, into[0..2], @intCast(r << 11 | g << 5 | b), .little);
        },
        .r8_unorm => into[0] = @truncate(color >> 16),
        else => {},
    }
}

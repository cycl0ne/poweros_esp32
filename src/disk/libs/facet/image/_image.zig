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
    /// IMAGE_CREATE_CUBE_COMPATIBLE.
    cube: bool = false,
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

/// The bytes a texel, a pixel or a vertex's value of `format` takes; 0
/// for one facet.library does not know.
pub fn bytesOf(format: facet.Format) u32 {
    return switch (format) {
        .s8_uint => 1,
        .r5g6b5_unorm_pack16, .d16_unorm => 2,
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
    return switch (format) {
        .b8g8r8a8_unorm, .r8g8b8a8_unorm => .rgba8888,
        .r5g6b5_unorm_pack16 => .rgb565,
        // Kept in their blocks and decoded as they are sampled, on a
        // device that says so (`PhysicalDeviceFeatures.kept_compressed`).
        .bc1_rgba_unorm_block => .bc1,
        .bc1_rgb_unorm_block => .bc1_rgb,
        .bc2_unorm_block => .bc2,
        .bc3_unorm_block => .bc3,
        // Kept as the floats they were copied in as, and rounded to 8 bits
        // a channel as they are sampled, on a device that says so
        // (`PhysicalDeviceFeatures.kept_floats`).
        .r16g16b16a16_sfloat => .rgba16f,
        .r32g32b32a32_sfloat => .rgba32f,
        .b10g11r11_ufloat_pack32 => .rg11b10f,
        .e5b9g9r9_ufloat_pack32 => .rgb9e5,
        // A depth sampled where it lies, in rows
        // (`PhysicalDeviceFeatures.sampled_depth`).
        .d16_unorm => .d16,
        else => null,
    };
}

/// Whether an image is a depth attachment's that may also be sampled: its
/// rows are the texture, so nothing is copied and nothing kept twice.
pub fn sampledDepth(image: *const Image) bool {
    return image.kind == .depth and image.usage & facet.IMAGE_USAGE_SAMPLED != 0;
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
    if ((info.image_type != .@"2d" and !volume) or info.samples != 1) return null;
    const layers = if (volume) extent.depth else info.array_layers;
    if (layers == 0 or (!volume and extent.depth != 1)) return null;
    if (volume and (info.array_layers != 1 or info.mip_levels != 1 or !std.math.isPowerOfTwo(layers) or layers > _instance.max_image_dimension_3d)) return null;
    if (layers > _instance.max_image_array_layers) return null;
    const cube = info.flags & facet.IMAGE_CREATE_CUBE_COMPATIBLE != 0;
    if (cube and (volume or layers < 6 or extent.width != extent.height)) return null;
    // Layers are for sampling: an attachment or rows have one.
    if ((layers > 1 or _decode.unpacks(info.format)) and (info.usage & facet.IMAGE_USAGE_SAMPLED == 0 or info.tiling != .optimal)) return null;
    // A compressed image is kept in its blocks, and a float one in its
    // floats, where this device samples them
    // (`PhysicalDeviceFeatures.kept_compressed`, `kept_floats`); where it
    // does not they are unpacked into 8 bits a channel. A storage image is
    // written texel by texel, which neither kind takes.
    const writes_texels = info.usage & facet.IMAGE_USAGE_STORAGE != 0;
    const keeps_blocks = physical.features.kept_compressed and _decode.blockBytes(info.format) != 0 and !writes_texels;
    const keeps_floats = physical.features.kept_floats and _decode.texelBytes(info.format) != 0 and !writes_texels;
    const kept_format: facet.Format = if (_decode.unpacks(info.format) and !(keeps_blocks or keeps_floats)) .r8g8b8a8_unorm else info.format;
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
        .cube = cube,
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
        // Sampled as well, since 1.39: its rows are the texture, so it is
        // a depth alone - there is no stencil texel - and it wants memory
        // behind it, which `requirements` holds to.
        const sampled = info.usage & facet.IMAGE_USAGE_SAMPLED != 0;
        if (sampled) {
            if (!physical.features.sampled_depth) return null;
            if (info.format != .d16_unorm) return null;
            if (info.usage & facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT != 0) return null;
        }
        const allowed = if (sampled) depth_usage | facet.IMAGE_USAGE_SAMPLED else depth_usage;
        if (info.usage & facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT == 0 or info.usage & ~allowed != 0) return null;
        if (info.tiling != .optimal or info.mip_levels != 1) return null;
        image.kind = .depth;
        // Rows, like a colour attachment's: what a render pass that stores
        // its depth writes, and what a transfer reads (`readTexel`). A
        // transient one is never written and takes the same shape.
        image.pitch = std.mem.alignForward(u32, extent.width * pixel, row_alignment);
        image.bytes = @as(u64, image.pitch) * extent.height;
        return image;
    }
    if (info.usage & facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT != 0) return null;
    // Read as an input attachment: its pixels are read out of its rows,
    // so not in a texture's layout and not a transient attachment, which
    // has no memory at all.
    if (info.usage & facet.IMAGE_USAGE_INPUT_ATTACHMENT != 0) {
        const not_rows = facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_STORAGE | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT;
        if (info.usage & not_rows != 0) return null;
    }
    // Sampled, written through as a storage image, or both: all one kind,
    // kept in the layout a sample reads.
    if (info.usage & (facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_STORAGE) != 0) {
        if (info.tiling != .optimal or info.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT != 0) return null;
        const kept = textureFormat(kept_format) orelse return null;
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
    // Rows of a colour format, of one level.
    if (info.mip_levels != 1 or textureFormat(info.format) == null) return null;
    image.pitch = std.mem.alignForward(u32, extent.width * pixel, row_alignment);
    image.bytes = @as(u64, image.pitch) * extent.height;
    return image;
}

/// A texture image's levels and layers as a sample reads them, over `memory`.
/// A depth image's rows are the texture themselves: one level, of whatever
/// size the image is (`texture.Texture.linear`).
pub fn texelsOver(image: *const Image, memory: [*]u8) texture.Texture.Error!texture.Texture {
    if (image.kind == .depth) return texture.Texture.linear(.d16, image.width, image.height, image.pitch, memory);
    var made = try texture.Texture.init(textureFormat(image.format).?, image.width, image.height, image.levels, memory);
    made.layer_count = image.layers;
    made.layer_bytes = @intCast(image.layer_bytes);
    return made;
}

/// What an image needs of its memory: a depth attachment any type, the
/// lazily allocated one too; the rest a type with something behind it - a
/// depth one that is sampled among them, its rows being read.
pub fn requirements(image: *const Image) facet.MemoryRequirements {
    const properties = &image.device.physical.memory;
    const anywhere = image.kind == .depth and !sampledDepth(image);
    return .{
        .size = image.bytes,
        .alignment = image.alignment,
        .memory_type_bits = if (anywhere) _memory.allTypes(properties) else _memory.backedTypes(properties),
    };
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
        if (z < 0 or z >= image.layers or depth == 0) return null;
        const first: u32 = @intCast(z);
        return .{ .first = first, .count = @min(depth, image.layers - first) };
    }
    if (subresource.base_array_layer >= image.layers or subresource.layer_count == 0) return null;
    return .{ .first = subresource.base_array_layer, .count = @min(subresource.layer_count, image.layers - subresource.base_array_layer) };
}

/// Whether what is copied into an image has to be unpacked.
pub fn unpacks(image: *const Image) bool {
    return image.given_format != image.format;
}

/// Whether an image's texels lie compressed where they were copied in, in
/// blocks of 4 x 4 texels (`PhysicalDeviceFeatures.kept_compressed`): a
/// sample decodes the block it reads, and a copy moves whole blocks.
pub fn blocked(image: *const Image) bool {
    return _decode.blockBytes(image.format) != 0;
}

/// The bytes of one of a blocked image's blocks; 0 for another image.
pub fn blockBytes(image: *const Image) u32 {
    return _decode.blockBytes(image.format);
}

/// Whether an image's texels are the floats they were copied in as
/// (`PhysicalDeviceFeatures.kept_floats`): a sample rounds one to 8 bits a
/// channel as it reads it, and a copy moves its bytes as they lie.
pub fn floatTexels(image: *const Image) bool {
    return _decode.texelBytes(image.format) != 0;
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
    // A float image keeps what it is given: the texel's bytes go as they
    // lie rather than through a colour of 8 bits a channel.
    const keeps = floatTexels(image);
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
                    const into = image.data.? + @as(usize, y) * image.pitch + @as(usize, left) * pixel;
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
        // A depth image is rows as well, of one level and one layer: what a
        // pass that stores its depth wrote.
        .rows, .depth => {
            const pixel = bytesOf(image.format);
            const from = image.data.? + @as(usize, y) * image.pitch + @as(usize, x) * pixel;
            @memcpy(into[0..pixel], from[0..pixel]);
        },
        .texture => if (deviceOffset(image, level, layer, x, y)) |offset| {
            const pixel = bytesOf(image.format);
            @memcpy(into[0..pixel], (image.data.? + offset)[0..pixel]);
        } else if (floatTexels(image)) {
            // The floats as they lie: what went in comes out again.
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
            const into = image.data.? + @as(usize, y) * image.pitch + @as(usize, x) * pixel;
            @memcpy(into[0..pixel], from[0..pixel]);
        },
        .texture => if (deviceOffset(image, level, layer, x, y)) |offset| {
            const pixel = bytesOf(image.format);
            @memcpy((image.data.? + offset)[0..pixel], from[0..pixel]);
        } else if (floatTexels(image)) {
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
        else => 0,
    };
}

/// 0xAARRGGBB as a buffer holds it in `format`, rounded where it has less.
pub fn bytesOfColor(format: facet.Format, color: u32, into: []u8) void {
    switch (format) {
        .b8g8r8a8_unorm, .r8g8b8a8_unorm => bytesOfTexel(format, color, into),
        .r5g6b5_unorm_pack16 => {
            const r = ((color >> 16 & 0xFF) * 31 + 127) / 255;
            const g = ((color >> 8 & 0xFF) * 63 + 127) / 255;
            const b = ((color & 0xFF) * 31 + 127) / 255;
            std.mem.writeInt(u16, into[0..2], @intCast(r << 11 | g << 5 | b), .little);
        },
        else => {},
    }
}

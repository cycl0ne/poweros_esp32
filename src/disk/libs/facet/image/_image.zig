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
//! A swapchain's images are `rows` over the display's buffers, made by the
//! swapchain and never bound: what is drawn into one is handed on to the
//! display tile by tile (`Display`), as the display does not see what the
//! processor's caches hold.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const texture = facet.texture;
const Device = @import("../device/_device.zig").Device;
const _memory = @import("../memory/_memory.zig");
const DeviceMemory = _memory.DeviceMemory;
const max_image_dimension = @import("../instance/_instance.zig").max_image_dimension;
const drawable = @import("../surface/_surface.zig").drawable;
const rtg = sdk.rtg;
const RtgBase = sdk.interface.rtg.RtgBase;

pub const Kind = enum { rows, texture, depth };

pub const Image = struct {
    device: *Device,
    format: facet.Format,
    width: u32,
    height: u32,
    levels: u32,
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
    /// `texture`: the levels it takes, as a sample reads them.
    texels: texture.Texture = undefined,
};

/// How a row of an image starts: on a cache line.
const row_alignment = 64;

/// The bytes a texel, a pixel or a vertex's value of `format` takes; 0
/// for one facet.library does not know.
pub fn bytesOf(format: facet.Format) u32 {
    return switch (format) {
        .r5g6b5_unorm_pack16, .d16_unorm => 2,
        .r8g8b8a8_unorm, .b8g8r8a8_unorm, .r32_sfloat => 4,
        .r32g32_sfloat => 8,
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
        else => null,
    };
}

/// An image as `info` asks for it, not yet bound; null for one
/// facet.library does not make.
pub fn shapeOf(device: *Device, info: *const facet.ImageCreateInfo) ?Image {
    const extent = info.extent;
    if (info.image_type != .@"2d" or extent.depth != 1 or info.array_layers != 1 or info.samples != 1) return null;
    if (extent.width == 0 or extent.height == 0 or extent.width > max_image_dimension or extent.height > max_image_dimension) return null;
    if (info.mip_levels == 0) return null;
    const pixel = bytesOf(info.format);
    if (pixel == 0) return null;
    var image = Image{
        .device = device,
        .format = info.format,
        .width = extent.width,
        .height = extent.height,
        .levels = info.mip_levels,
        .usage = info.usage,
        .kind = .rows,
        .bytes = 0,
    };
    const depth_usage = facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | facet.IMAGE_USAGE_TRANSIENT_ATTACHMENT;
    if (info.format == .d16_unorm) {
        if (info.usage & facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT == 0 or info.usage & ~depth_usage != 0) return null;
        if (info.tiling != .optimal or info.mip_levels != 1) return null;
        image.kind = .depth;
        image.bytes = @as(u64, extent.width) * extent.height * 2;
        return image;
    }
    if (info.usage & facet.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT != 0) return null;
    if (info.usage & facet.IMAGE_USAGE_SAMPLED != 0) {
        if (info.tiling != .optimal or info.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT != 0) return null;
        const kept = textureFormat(info.format) orelse return null;
        image.kind = .texture;
        image.bytes = texture.Texture.bytes(kept, extent.width, extent.height, info.mip_levels) catch return null;
        // Its levels' layout, over no memory yet: BindImageMemory moves it.
        image.texels = texture.Texture.init(kept, extent.width, extent.height, info.mip_levels, @ptrFromInt(_memory.alignment)) catch return null;
        if (device.physical.ops.texture_memory) |own| {
            const memory = own(info.format, extent.width, extent.height, info.mip_levels);
            image.bytes = memory.bytes;
            image.alignment = memory.alignment;
        }
        return image;
    }
    if (info.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT != 0 and !drawable(info.format)) return null;
    // Rows of a colour format, of one level.
    if (info.mip_levels != 1 or textureFormat(info.format) == null) return null;
    image.pitch = std.mem.alignForward(u32, extent.width * pixel, row_alignment);
    image.bytes = @as(u64, image.pitch) * extent.height;
    return image;
}

/// What an image needs of its memory: a depth attachment any type, the
/// lazily allocated one too; the rest a type with something behind it.
pub fn requirements(image: *const Image) facet.MemoryRequirements {
    const properties = &image.device.physical.memory;
    return .{
        .size = image.bytes,
        .alignment = image.alignment,
        .memory_type_bits = if (image.kind == .depth) _memory.allTypes(properties) else _memory.backedTypes(properties),
    };
}

/// A texture image's levels from `base` on, `count` of them, over its
/// memory as a sample reads them.
pub fn levelsFrom(image: *const Image, base: u32, count: u32) texture.Texture {
    const whole = &image.texels;
    const width = @max(image.width >> @intCast(base), 1);
    const height = @max(image.height >> @intCast(base), 1);
    // The levels of the whole from `base` lie as those of a texture that
    // starts with that level: each is laid out by its own size alone.
    return texture.Texture.init(whole.format, width, height, count, whole.memory + whole.layout[base].start) catch unreachable;
}

/// A rectangle of texels copied from a buffer's bytes into a level of an
/// image, as `region` says, in the image's format: converted to the
/// texture layout for a texture, row by row for rows. The part of the
/// rectangle outside the image, or past the end of `from`, is left out.
pub fn copyFromBuffer(image: *Image, from: []const u8, region: *const facet.BufferImageCopy) void {
    if (image.kind == .depth or image.data == null) return;
    const level = region.image_subresource.mip_level;
    if (level >= image.levels or region.image_offset.x < 0 or region.image_offset.y < 0) return;
    const level_width = @max(image.width >> @intCast(level), 1);
    const level_height = @max(image.height >> @intCast(level), 1);
    const left: u32 = @intCast(region.image_offset.x);
    const top: u32 = @intCast(region.image_offset.y);
    if (left >= level_width or top >= level_height) return;
    const width = @min(region.image_extent.width, level_width - left);
    const height = @min(region.image_extent.height, level_height - top);
    const pixel = bytesOf(image.format);
    const row_length = if (region.buffer_row_length != 0) region.buffer_row_length else region.image_extent.width;
    const source_pitch = @as(usize, row_length) * pixel;
    const start = std.math.cast(usize, region.buffer_offset) orelse return;
    for (0..height) |row| {
        const at = start + row * source_pitch;
        if (at + width * pixel > from.len) return;
        const source = from[at..][0 .. width * pixel];
        const y = top + @as(u32, @intCast(row));
        switch (image.kind) {
            .rows => {
                const into = image.data.? + @as(usize, y) * image.pitch + @as(usize, left) * pixel;
                @memcpy(into[0..source.len], source);
            },
            .texture => for (0..width) |column| {
                const x = left + @as(u32, @intCast(column));
                image.texels.put(level, x, y, texelOf(image.format, source[column * pixel ..]));
            },
            .depth => unreachable,
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

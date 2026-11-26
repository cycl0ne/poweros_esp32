// SPDX-License-Identifier: MIT
//! Copies between images and buffers, as every driver does them: on the
//! cores, texel by texel, through what `_image` knows of each image's layout.
//! They come after what drew into the images has finished, as a queue plays
//! a command only after the one before it.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const texture = facet.texture;
const shader = facet.shader;
const raster = @import("raster");
const _buffer = @import("../buffer/_buffer.zig");
const _command = @import("../command/_command.zig");
const _stream = @import("../command/_stream.zig");
const _image = @import("../image/_image.zig");
const Image = _image.Image;

/// CmdCopyImage's regions, the part of each inside both images. Texels go as
/// they are: images of the same size of texel. A multisampled image's
/// samples go each to the same sample of the other, whose count Vulkan
/// has be the same (VUID-vkCmdCopyImage-srcImage-00136): plane by plane, as
/// llvmpipe lays them (`Image.samples`, since 1.99).
pub fn copyImage(command: *const _command.CopyImage) void {
    if (command.source.samples != command.destination.samples) return;
    for (0..command.source.samples) |sample| {
        const source = _image.sampleOf(command.source, @intCast(sample));
        var destination = _image.sampleOf(command.destination, @intCast(sample));
        copyPlane(command, &source, &destination);
    }
}

/// CmdCopyImage's regions between two images of one sample a pixel, or
/// one sample's plane of each. What is copied is the bits, between any two
/// formats of one size (58.1.8's size-compatible, which
/// VUID-vkCmdCopyImage-srcImage-01548 asks of them): each texel goes as
/// the bytes a buffer would hold it in, whatever the two images keep it
/// as, and since 1.132 that is so for every such pair. lavapipe hands each
/// copy to `resource_copy_region` (`handle_copy_image`,
/// src/gallium/frontends/lavapipe/lvp_execute.c:2784-2867), which llvmpipe
/// does over the bytes as they lie (`lp_resource_copy`,
/// src/gallium/drivers/llvmpipe/lp_surface.c:86-116); before, two images
/// that kept their texels differently, or kept them as given in formats
/// of their own, took nothing.
fn copyPlane(command: *const _command.CopyImage, source: *const Image, destination: *Image) void {
    if (!_image.readable(source) or !_image.readable(destination)) return;
    if (_image.unpacks(source) or _image.unpacks(destination)) return;
    const from_blocks = _image.blocked(source);
    const to_blocks = _image.blocked(destination);
    // Both keeping their blocks, of one size (of one format before 1.132):
    // the blocks go as they lie, nothing decoded
    // (`Capabilities.kept_compressed`).
    if (from_blocks and to_blocks) {
        if (_image.blockBytes(source) == _image.blockBytes(destination)) copyBlocks(command, source, destination);
        return;
    }
    // A block to a texel as large, or a texel to a block (since 1.132).
    if (from_blocks or to_blocks) return copyAcross(command, source, destination);
    const pixel = _image.bytesOf(source.format);
    if (pixel != _image.bytesOf(destination.format)) return;
    // A depth or a stencil goes into an image of its own format alone
    // (VUID-vkCmdCopyImage-srcImage-01548): D16_UNORM_S8_UINT and
    // D24_UNORM_S8_UINT are both four bytes a pixel, laid out apart.
    const planes = _image.hasDepth(source.format) or _image.hasStencil(source.format);
    if ((planes or _image.hasDepth(destination.format) or _image.hasStencil(destination.format)) and source.format != destination.format) return;
    for (_stream.items(_command.CopyImage, facet.ImageCopy, command, command.count)) |*region| {
        // One aspect of a format that holds two moves its own bytes and
        // leaves the other's where they lie (since 1.222), as lavapipe
        // copies one aspect (`handle_copy_image`,
        // src/gallium/frontends/lavapipe/lvp_execute.c:2835-2855); both
        // aspects at once, or a format of one, move the whole pixel.
        const lane = if (planes) _image.laneOf(source.format, region.src_subresource.aspect_mask) else null;
        const partly = if (lane) |one| one.bytes < pixel and _image.hasDepth(source.format) and _image.hasStencil(source.format) else false;
        const from_level = region.src_subresource.mip_level;
        const to_level = region.dst_subresource.mip_level;
        if (from_level >= source.levels or to_level >= destination.levels) continue;
        if (region.src_offset.x < 0 or region.src_offset.y < 0 or region.dst_offset.x < 0 or region.dst_offset.y < 0) continue;
        const from_size = _image.levelSize(source, from_level);
        const to_size = _image.levelSize(destination, to_level);
        const from_x: u32 = @intCast(region.src_offset.x);
        const from_y: u32 = @intCast(region.src_offset.y);
        const to_x: u32 = @intCast(region.dst_offset.x);
        const to_y: u32 = @intCast(region.dst_offset.y);
        if (from_x >= from_size[0] or from_y >= from_size[1] or to_x >= to_size[0] or to_y >= to_size[1]) continue;
        const width = @min(region.extent.width, from_size[0] - from_x, to_size[0] - to_x);
        const height = @min(region.extent.height, from_size[1] - from_y, to_size[1] - to_y);
        const from_layers = _image.layersOf(source, region.src_subresource, region.src_offset.z, region.extent.depth) orelse continue;
        const to_layers = _image.layersOf(destination, region.dst_subresource, region.dst_offset.z, region.extent.depth) orelse continue;
        // As wide as the widest texel kept: four floats of 32 bits.
        var texel: [16]u8 = undefined;
        for (0..@min(from_layers.count, to_layers.count)) |layer_number| {
            const layer: u32 = @intCast(layer_number);
            for (0..height) |row| for (0..width) |column| {
                const into_x = to_x + @as(u32, @intCast(column));
                const into_y = to_y + @as(u32, @intCast(row));
                _image.readTexel(source, from_level, from_layers.first + layer, from_x + @as(u32, @intCast(column)), from_y + @as(u32, @intCast(row)), &texel);
                if (partly) {
                    var there: [4]u8 = undefined;
                    _image.readTexel(destination, to_level, to_layers.first + layer, into_x, into_y, &there);
                    _image.laneIn(lane.?, texel[lane.?.at..], &there);
                    @memcpy(texel[0..4], &there);
                }
                _image.writeTexel(destination, to_level, to_layers.first + layer, into_x, into_y, &texel);
            };
        }
    }
}

/// CmdCopyImage between two images that keep their blocks, of the one
/// format: block by block, the offsets and the extent on a multiple of 4 as
/// Vulkan asks of a compressed image. A region whose offsets are not is
/// left out.
fn copyBlocks(command: *const _command.CopyImage, source: *const Image, destination: *Image) void {
    const wide = _image.blockBytes(source);
    for (_stream.items(_command.CopyImage, facet.ImageCopy, command, command.count)) |*region| {
        const from_level = region.src_subresource.mip_level;
        const to_level = region.dst_subresource.mip_level;
        if (from_level >= source.levels or to_level >= destination.levels) continue;
        if (region.src_offset.x < 0 or region.src_offset.y < 0 or region.dst_offset.x < 0 or region.dst_offset.y < 0) continue;
        const from_size = _image.levelSize(source, from_level);
        const to_size = _image.levelSize(destination, to_level);
        const from_x: u32 = @intCast(region.src_offset.x);
        const from_y: u32 = @intCast(region.src_offset.y);
        const to_x: u32 = @intCast(region.dst_offset.x);
        const to_y: u32 = @intCast(region.dst_offset.y);
        if (from_x % 4 != 0 or from_y % 4 != 0 or to_x % 4 != 0 or to_y % 4 != 0) continue;
        if (from_x >= from_size[0] or from_y >= from_size[1] or to_x >= to_size[0] or to_y >= to_size[1]) continue;
        const width = @min(region.extent.width, from_size[0] - from_x, to_size[0] - to_x);
        const height = @min(region.extent.height, from_size[1] - from_y, to_size[1] - to_y);
        const from_layers = _image.layersOf(source, region.src_subresource, region.src_offset.z, region.extent.depth) orelse continue;
        const to_layers = _image.layersOf(destination, region.dst_subresource, region.dst_offset.z, region.extent.depth) orelse continue;
        var block: [16]u8 = undefined;
        for (0..@min(from_layers.count, to_layers.count)) |layer_number| {
            const layer: u32 = @intCast(layer_number);
            for (0..(height + 3) / 4) |row| for (0..(width + 3) / 4) |column| {
                const across: u32 = @intCast(column * 4);
                const down: u32 = @intCast(row * 4);
                _image.readBlock(source, from_level, from_layers.first + layer, from_x + across, from_y + down, block[0..wide]);
                _image.writeBlock(destination, to_level, to_layers.first + layer, to_x + across, to_y + down, block[0..wide]);
            };
        }
    }
}

/// CmdCopyImage's regions between a block image and an uncompressed one
/// whose texel is as large as its block (since 1.132): each block of the
/// one is the bytes of a texel of the other. A region's offsets are each
/// in its own image's texels and its extent in the source's, so a source
/// of blocks writes a quarter as many texels each way as its extent says,
/// and a source of texels as many blocks as it has texels: Vulkan's size
/// adjustment (26.3, 58.1.8), which `util_resource_copy_region` makes by
/// counting the region in blocks of each format.
fn copyAcross(command: *const _command.CopyImage, source: *const Image, destination: *Image) void {
    const from_blocks = _image.blocked(source);
    const wide = if (from_blocks) _image.blockBytes(source) else _image.blockBytes(destination);
    if (wide != _image.bytesOf(if (from_blocks) destination.format else source.format)) return;
    // How far a block or a texel reaches each way, in its own texels.
    const from_step: u32 = if (from_blocks) 4 else 1;
    const to_step: u32 = if (from_blocks) 1 else 4;
    for (_stream.items(_command.CopyImage, facet.ImageCopy, command, command.count)) |*region| {
        const from_level = region.src_subresource.mip_level;
        const to_level = region.dst_subresource.mip_level;
        if (from_level >= source.levels or to_level >= destination.levels) continue;
        if (region.src_offset.x < 0 or region.src_offset.y < 0 or region.dst_offset.x < 0 or region.dst_offset.y < 0) continue;
        const from_size = _image.levelSize(source, from_level);
        const to_size = _image.levelSize(destination, to_level);
        const from_x: u32 = @intCast(region.src_offset.x);
        const from_y: u32 = @intCast(region.src_offset.y);
        const to_x: u32 = @intCast(region.dst_offset.x);
        const to_y: u32 = @intCast(region.dst_offset.y);
        if (from_x % from_step != 0 or from_y % from_step != 0 or to_x % to_step != 0 or to_y % to_step != 0) continue;
        if (from_x >= from_size[0] or from_y >= from_size[1] or to_x >= to_size[0] or to_y >= to_size[1]) continue;
        // The region in blocks of the block image, which are texels of
        // the other, as far as both images reach.
        const across = @min(divCeil(@min(region.extent.width, from_size[0] - from_x), from_step), divCeil(to_size[0] - to_x, to_step));
        const down = @min(divCeil(@min(region.extent.height, from_size[1] - from_y), from_step), divCeil(to_size[1] - to_y, to_step));
        const from_layers = _image.layersOf(source, region.src_subresource, region.src_offset.z, region.extent.depth) orelse continue;
        const to_layers = _image.layersOf(destination, region.dst_subresource, region.dst_offset.z, region.extent.depth) orelse continue;
        var bytes: [16]u8 = undefined;
        for (0..@min(from_layers.count, to_layers.count)) |layer_number| {
            const from_layer = from_layers.first + @as(u32, @intCast(layer_number));
            const to_layer = to_layers.first + @as(u32, @intCast(layer_number));
            for (0..down) |row| for (0..across) |column| {
                const r: u32 = @intCast(row);
                const c: u32 = @intCast(column);
                const fx = from_x + c * from_step;
                const fy = from_y + r * from_step;
                const tx = to_x + c * to_step;
                const ty = to_y + r * to_step;
                if (from_blocks) {
                    _image.readBlock(source, from_level, from_layer, fx, fy, bytes[0..wide]);
                    _image.writeTexel(destination, to_level, to_layer, tx, ty, bytes[0..wide]);
                } else {
                    _image.readTexel(source, from_level, from_layer, fx, fy, &bytes);
                    _image.writeBlock(destination, to_level, to_layer, tx, ty, bytes[0..wide]);
                }
            };
        }
    }
}

fn divCeil(value: u32, step: u32) u32 {
    return (value + step - 1) / step;
}

/// CmdResolveImage's regions, the part of each inside both images: each
/// pixel of the destination the average of the source's samples at the
/// same place (since 1.101). lavapipe has llvmpipe blit the region
/// (`handle_resolve_image`, lvp_execute.c), and the resolve averages the
/// samples, their sum times one over their count (`build_tex_resolve`,
/// vk_meta_blit_resolve.c), and Vulkan has the write take one of the two
/// values nearest to that and should take the nearer (Fixed-Point Data
/// Conversions). Here that is done in whole numbers
/// (`raster.average8888`, `raster.average565`): the same average, and its
/// nearest value, a tie taken upward. A pass's resolve attachment is
/// given the same average (since 1.109).
///
/// Vulkan has the source of more than one sample, the destination of one,
/// both of the one format (VUID-vkCmdResolveImage-srcImage-00257,
/// VUID-vkCmdResolveImage-dstImage-00259,
/// VUID-vkCmdResolveImage-srcImage-12546): a command that is not is left
/// out, and so is a source of any count but four, the one this library
/// makes. An image of four samples is of an attachment's format
/// (`_image.shapeFor`), so it is 8888 or 565 and never one of whole
/// numbers, whose resolve would take one sample instead.
pub fn resolveImage(command: *const _command.ResolveImage) void {
    const source = command.source;
    const destination = command.destination;
    if (source.samples != 4 or destination.samples != 1 or source.format != destination.format) return;
    if (!_image.readable(source) or !_image.readable(destination)) return;
    // A depth or a stencil is no resolve's (VUID-VkImageResolve-aspectMask-00266):
    // a format of 24 bits of depth is four bytes a pixel too (since 1.222).
    if (_image.hasDepth(source.format) or _image.hasStencil(source.format)) return;
    const pixel = _image.bytesOf(source.format);
    if (pixel != 4 and source.format != .r5g6b5_unorm_pack16 and !_image.drawnRows(source)) return;
    for (_stream.items(_command.ResolveImage, facet.ImageResolve, command, command.count)) |*region| {
        const to_level = region.dst_subresource.mip_level;
        if (region.src_subresource.mip_level != 0 or to_level >= destination.levels) continue;
        if (region.src_offset.x < 0 or region.src_offset.y < 0 or region.dst_offset.x < 0 or region.dst_offset.y < 0) continue;
        const from_size = _image.levelSize(source, 0);
        const to_size = _image.levelSize(destination, to_level);
        const from_x: u32 = @intCast(region.src_offset.x);
        const from_y: u32 = @intCast(region.src_offset.y);
        const to_x: u32 = @intCast(region.dst_offset.x);
        const to_y: u32 = @intCast(region.dst_offset.y);
        if (from_x >= from_size[0] or from_y >= from_size[1] or to_x >= to_size[0] or to_y >= to_size[1]) continue;
        const width = @min(region.extent.width, from_size[0] - from_x, to_size[0] - to_x);
        const height = @min(region.extent.height, from_size[1] - from_y, to_size[1] - to_y);
        const from_layers = _image.layersOf(source, region.src_subresource, region.src_offset.z, region.extent.depth) orelse continue;
        const to_layers = _image.layersOf(destination, region.dst_subresource, region.dst_offset.z, region.extent.depth) orelse continue;
        for (0..@min(from_layers.count, to_layers.count)) |layer_number| {
            const layer: u32 = @intCast(layer_number);
            resolveRectangle(source, from_layers.first + layer, .{ from_x, from_y }, destination, to_level, to_layers.first + layer, .{ to_x, to_y }, width, height);
        }
    }
}

/// Each pixel of a `width` by `height` rectangle of `source`'s layer
/// `from_layer`, from `from`, the average of its four samples, written into
/// `destination`'s level and layer at `to`: what CmdResolveImage does for a
/// region, every sample read where its image keeps it (`_image.sampleOf`),
/// and what the V3D does after a pass whose resolve it cannot do in its
/// tiles (since 1.148). Both of one format of 8888 or 565, the source of
/// four samples, and the rectangle inside both; or of a format the tiles
/// keep in its own bytes, whose four samples are read as floats, averaged
/// and written back in the format, as a pass resolves one
/// (`raster.resolveTexels`, since 1.226).
pub fn resolveRectangle(source: *const Image, from_layer: u32, from: [2]u32, destination: *Image, to_level: u32, to_layer: u32, to: [2]u32, width: u32, height: u32) void {
    const pixel = _image.bytesOf(source.format);
    var planes: [4]Image = undefined;
    for (&planes, 0..) |*plane, sample| plane.* = _image.sampleOf(source, @intCast(sample));
    const texels = if (_image.drawnRows(source)) _image.targetTexels(source.format) else shader.TexelFormat.none;
    for (0..height) |row| for (0..width) |column| {
        const x: u32 = @intCast(column);
        const y: u32 = @intCast(row);
        if (texels != .none) {
            var sum: [4]f32 = .{ 0, 0, 0, 0 };
            for (&planes) |*plane| {
                var bytes: [16]u8 = @splat(0);
                _image.readTexel(plane, 0, from_layer, from[0] + x, from[1] + y, &bytes);
                const one = shader.Texels{ .bytes = &bytes, .count = 1, .format = texels, .writable = false };
                for (&sum, one.at(0)) |*total, part| total.* += part;
            }
            for (&sum) |*total| total.* *= 0.25;
            var bytes: [16]u8 = @splat(0);
            var one = shader.Texels{ .bytes = &bytes, .count = 1, .format = texels, .writable = true };
            one.set(0, sum);
            _image.writeTexel(destination, to_level, to_layer, to[0] + x, to[1] + y, bytes[0..pixel]);
            continue;
        }
        var words: [4]u32 = undefined;
        for (&planes, &words) |*plane, *word| {
            var bytes: [4]u8 = @splat(0);
            _image.readTexel(plane, 0, from_layer, from[0] + x, from[1] + y, &bytes);
            word.* = std.mem.readInt(u32, &bytes, .little);
        }
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, if (pixel == 4) raster.average8888(words) else raster.average565(words), .little);
        _image.writeTexel(destination, to_level, to_layer, to[0] + x, to[1] + y, bytes[0..pixel]);
    };
}

/// CmdCopyImageToBuffer's regions: the part of each inside the image, as far
/// as the buffer goes.
pub fn copyImageToBuffer(command: *const _command.CopyImageToBuffer) void {
    const image = command.image;
    if (!_image.readable(image) or _image.unpacks(image)) return;
    // A multisampled image is no buffer copy's (VUID-vkCmdCopyImageToBuffer-srcImage-07973).
    if (image.samples != 1) return;
    const into = _buffer.bytes(command.destination, 0, facet.WHOLE_SIZE) orelse return;
    if (_image.blocked(image)) return blocksToBuffer(command, into);
    for (_stream.items(_command.CopyImageToBuffer, facet.BufferImageCopy, command, command.count)) |*region| {
        // A depth or a stencil as Vulkan has the aspect lie in a buffer
        // (since 1.222, `_image.laneOf`); a colour as it lies.
        const lane = _image.laneOf(image.format, region.image_subresource.aspect_mask);
        const pixel = if (lane) |one| one.buffer else _image.bytesOf(image.format);
        const level = region.image_subresource.mip_level;
        if (level >= image.levels or region.image_offset.x < 0 or region.image_offset.y < 0) continue;
        const size = _image.levelSize(image, level);
        const left: u32 = @intCast(region.image_offset.x);
        const top: u32 = @intCast(region.image_offset.y);
        if (left >= size[0] or top >= size[1]) continue;
        const width = @min(region.image_extent.width, size[0] - left);
        const height = @min(region.image_extent.height, size[1] - top);
        const row_length = if (region.buffer_row_length != 0) region.buffer_row_length else region.image_extent.width;
        const pitch = @as(usize, row_length) * pixel;
        const start = std.math.cast(usize, region.buffer_offset) orelse continue;
        const layers = _image.layersOf(image, region.image_subresource, region.image_offset.z, region.image_extent.depth) orelse continue;
        const slice_height = if (region.buffer_image_height != 0) region.buffer_image_height else region.image_extent.height;
        for (0..layers.count) |slice| for (0..height) |row| {
            const at = start + slice * slice_height * pitch + row * pitch;
            if (at + width * pixel > into.len) break;
            for (0..width) |column| {
                const x = left + @as(u32, @intCast(column));
                const y = top + @as(u32, @intCast(row));
                const layer = layers.first + @as(u32, @intCast(slice));
                if (lane) |one| {
                    var texel: [4]u8 = undefined;
                    _image.readTexel(image, level, layer, x, y, &texel);
                    _image.laneOut(one, &texel, into[at + column * pixel ..]);
                } else _image.readTexel(image, level, layer, x, y, into[at + column * pixel ..]);
            }
        };
    }
}

/// CmdCopyImageToBuffer of an image that keeps its blocks: the blocks as
/// they lie, a row of them `buffer_row_length` texels across, the offsets
/// on a multiple of 4.
fn blocksToBuffer(command: *const _command.CopyImageToBuffer, into: []u8) void {
    const image = command.image;
    const wide = _image.blockBytes(image);
    for (_stream.items(_command.CopyImageToBuffer, facet.BufferImageCopy, command, command.count)) |*region| {
        const level = region.image_subresource.mip_level;
        if (level >= image.levels or region.image_offset.x < 0 or region.image_offset.y < 0) continue;
        const size = _image.levelSize(image, level);
        const left: u32 = @intCast(region.image_offset.x);
        const top: u32 = @intCast(region.image_offset.y);
        if (left % 4 != 0 or top % 4 != 0) continue;
        if (left >= size[0] or top >= size[1]) continue;
        const width = @min(region.image_extent.width, size[0] - left);
        const height = @min(region.image_extent.height, size[1] - top);
        const row_length = if (region.buffer_row_length != 0) region.buffer_row_length else region.image_extent.width;
        const pitch = @as(usize, (row_length + 3) / 4) * wide;
        const start = std.math.cast(usize, region.buffer_offset) orelse continue;
        const layers = _image.layersOf(image, region.image_subresource, region.image_offset.z, region.image_extent.depth) orelse continue;
        const slice_height = if (region.buffer_image_height != 0) region.buffer_image_height else region.image_extent.height;
        for (0..layers.count) |slice| for (0..(height + 3) / 4) |row| for (0..(width + 3) / 4) |column| {
            const at = start + slice * @as(usize, (slice_height + 3) / 4) * pitch + row * pitch + column * wide;
            if (at + wide > into.len) return;
            _image.readBlock(image, level, layers.first + @as(u32, @intCast(slice)), left + @as(u32, @intCast(column * 4)), top + @as(u32, @intCast(row * 4)), into[at..][0..wide]);
        };
    }
}

/// The colours of a level read by way of 0xAARRGGBB: the colour a sample
/// reads of each texel, whatever the image keeps it as.
fn colorAt(image: *const Image, level: u32, layer: u32, x: u32, y: u32) u32 {
    // A compressed image has no texel of its own in memory: the one it
    // holds is decoded out of the block it lies in.
    if (_image.blocked(image)) return _image.blockColor(image, level, layer, x, y);
    // Room for the widest texel, four floats (since 1.126). A texel kept
    // as it was given is read as it lies, and was cut to the four bytes of
    // a colour word before: one of 8 or 16 bytes read as nothing, or as
    // what lay past the word, and a float one as nothing at all.
    var texel: [16]u8 = undefined;
    _image.readTexel(image, level, layer, x, y, &texel);
    return _image.colorOfBytes(image.format, &texel);
}

/// Where a destination's pixel centre falls in the source, along one axis.
fn along(pixel: i32, to: [2]i32, from: [2]i32) f32 {
    const part = (@as(f32, @floatFromInt(pixel)) + 0.5 - @as(f32, @floatFromInt(to[0]))) / @as(f32, @floatFromInt(to[1] - to[0]));
    return @as(f32, @floatFromInt(from[0])) + part * @as(f32, @floatFromInt(from[1] - from[0]));
}

fn held(value: i32, size: u32) u32 {
    return @intCast(std.math.clamp(value, 0, @as(i32, @intCast(size)) - 1));
}

/// Two 0xAARRGGBB, `part` of the way from one to the other.
fn mixed(a: u32, b: u32, part: f32) u32 {
    var made: u32 = 0;
    inline for ([4]u5{ 0, 8, 16, 24 }) |shift| {
        const from: f32 = @floatFromInt(a >> shift & 0xFF);
        const to: f32 = @floatFromInt(b >> shift & 0xFF);
        made |= @as(u32, @intFromFloat(from + (to - from) * part + 0.5)) << shift;
    }
    return made;
}

/// CmdBlitImage's regions, by way of 0xAARRGGBB: scaled, turned round as the
/// corners say, and in the destination's format.
/// CmdClearColorImage: every texel of the levels and layers named set to
/// the colour. False, and nothing written, for a format whose texel this
/// cannot write - a compressed one, whose texels go in as whole blocks.
///
/// Whole levels are written, so how a level's texels lie does not matter:
/// each takes the same value, in whatever order they are kept.
pub fn clearColorImage(command: *const _command.ClearColorImage) bool {
    const image = command.image;
    const data = image.data orelse return true;
    const texel = texelOf(image, command.color, command.parts, command.words) orelse return false;
    for (_stream.items(_command.ClearColorImage, facet.ImageSubresourceRange, command, command.count)) |range| {
        const first_level = range.base_mip_level;
        if (first_level >= image.levels) continue;
        const levels = if (range.level_count == facet.REMAINING) image.levels - first_level else @min(range.level_count, image.levels - first_level);
        const first_layer = range.base_array_layer;
        if (first_layer >= image.layers) continue;
        const layers = if (range.layer_count == facet.REMAINING) image.layers - first_layer else @min(range.layer_count, image.layers - first_layer);
        // Every sample's plane, each the whole image at one sample (since
        // 1.99), or the one memory of four samples kept together, all of
        // which a level's span is (`_image.planesOf`, since 1.146).
        for (0.._image.planesOf(image)) |sample| for (first_level..first_level + levels) |level| {
            const sample_at = @as(usize, @intCast(image.sample_bytes)) * sample;
            // A 3D image's level is every slice it has, fewer at each
            // level, whatever the range: Vulkan's names its one array
            // layer (since 1.141; until then its slices were taken for
            // layers, and the first alone cleared where the range said 1).
            const from: usize, const to: usize = if (image.volume) .{ 0, image.texels.slicesAt(@intCast(level)) } else .{ first_layer, first_layer + layers };
            for (from..to) |layer| {
                const span = spanOf(image, @intCast(level), @intCast(layer)) orelse continue;
                if (sample_at + span.at + span.bytes > image.bytes) continue;
                fill(data + sample_at + span.at, span.bytes, texel);
            }
        };
    }
    return true;
}

/// CmdClearDepthStencilImage's ranges: a depth image's rows set to the
/// depth given, its stencil's to the stencil, each range's aspects alone,
/// over the levels and the layers it names.
/// The padding at a row's end goes with them where a whole row is one
/// value, being the image's own memory and read by nothing. False, and
/// nothing written, for an image this cannot write at all.
///
/// An image with no memory behind it - a transient attachment, whose pixels
/// live in the tiles - is left alone and answers true: there is nothing
/// there to clear, and the pass clears the tiles as they start.
pub fn clearDepthImage(command: *const _command.ClearDepthStencilImage) bool {
    const image = command.image;
    if (image.kind != .depth) return false;
    const data = image.data orelse return true;
    const stride = _image.bytesOf(image.format);
    const depth_lane = _image.laneOf(image.format, facet.IMAGE_ASPECT_DEPTH);
    const stencil_lane = _image.laneOf(image.format, facet.IMAGE_ASPECT_STENCIL);
    // A pixel as the clear leaves it, each aspect in its own bytes: a
    // depth of 24 bits in the top three of its word (since 1.222).
    var cleared = [4]u8{ 0, 0, 0, 0 };
    var depth_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &depth_bytes, command.depth, .little);
    if (depth_lane) |lane| _image.laneIn(lane, &depth_bytes, &cleared);
    if (stencil_lane) |lane| _image.laneIn(lane, &.{command.stencil}, &cleared);
    const value: Texel = switch (stride) {
        1 => .{ .one = cleared[0] },
        2 => .{ .two = std.mem.readInt(u16, cleared[0..2], .little) },
        else => .{ .four = std.mem.readInt(u32, &cleared, .little) },
    };
    for (_stream.items(_command.ClearDepthStencilImage, facet.ImageSubresourceRange, command, command.count)) |range| {
        // The levels and the layers the range names: a depth image may
        // have layers since 1.58 and levels since 1.63.
        if (range.base_mip_level >= image.levels or range.base_array_layer >= image.layers) continue;
        if (range.level_count == 0 or range.layer_count == 0) continue;
        const levels = @min(if (range.level_count == facet.REMAINING) image.levels else range.level_count, image.levels - range.base_mip_level);
        const layers = @min(if (range.layer_count == facet.REMAINING) image.layers else range.layer_count, image.layers - range.base_array_layer);
        const clears_depth = depth_lane != null and range.aspect_mask & facet.IMAGE_ASPECT_DEPTH != 0;
        const clears_stencil = stencil_lane != null and range.aspect_mask & facet.IMAGE_ASPECT_STENCIL != 0;
        if (!clears_depth and !clears_stencil) continue;
        // Every plane the format has cleared: every byte of the level is
        // the one value. Otherwise the one plane's bytes of each pixel,
        // the other's left as they lie.
        const whole = (clears_depth or stencil_lane == null) and (clears_stencil or depth_lane == null);
        const lane = if (clears_depth) depth_lane.? else stencil_lane.?;
        // Every sample's plane, as a colour clear does (since 1.99).
        for (0.._image.planesOf(image)) |sample| for (0..layers) |one| for (0..levels) |step| {
            const level = range.base_mip_level + @as(u32, @intCast(step));
            const layer = range.base_array_layer + @as(u32, @intCast(one));
            // Laid out by its device (since 1.142): the level where the
            // device keeps it, all of it the one value, as a depth or a
            // stencil alone is in rows.
            if (_image.deviceLaid(image)) {
                const span = image.device.physical.ops.texture_level.?(image, level, layer);
                const into: [*]u8 = data + @as(usize, @intCast(span.at));
                if (whole) {
                    fill(into, @intCast(span.bytes), value);
                } else {
                    // Its device keeps a pixel's bytes together as well.
                    var at: usize = 0;
                    while (at + stride <= span.bytes) : (at += stride) _image.laneIn(lane, cleared[lane.at..], (into + at)[0..stride]);
                }
                continue;
            }
            const rows = _image.rowsAt(image, level, layer);
            const size = _image.levelSize(image, level);
            const into_level = data + sample * @as(usize, @intCast(image.sample_bytes)) + rows.at;
            // Every plane: every byte of every row is the one value.
            if (whole) {
                fill(into_level, @as(usize, rows.pitch) * size[1], value);
                continue;
            }
            // One plane of a format that holds both: each pixel's own
            // bytes, the padding at a row's end left as it is.
            for (0..size[1]) |row| {
                const into = into_level + row * rows.pitch;
                for (0..size[0]) |column| _image.laneIn(lane, cleared[lane.at..], (into + column * stride)[0..stride]);
            }
        };
    }
    return true;
}

/// Where a level of a layer lies, from the image's memory, and how many
/// bytes it is. Null for a level the image does not keep that way.
fn spanOf(image: *const Image, level: u32, layer: u32) ?struct { at: usize, bytes: usize } {
    switch (image.kind) {
        // A level's rows, each of the level's own pitch: the padding at a
        // row's end is written too, being the image's own memory and read
        // by nothing. An image kept in rows has levels since 1.119.
        .rows => {
            // Four samples kept together, where its device says: the
            // whole level, every sample of it (since 1.146). And since
            // 1.210 one sampled as well, or of more than one level, which
            // such a device lays out as a texture (`_image.deviceLaid`):
            // the level of that layer, the padding of its tiles with it.
            if (_image.deviceLaid(image)) {
                const span = image.device.physical.ops.texture_level.?(image, level, layer);
                return .{ .at = @intCast(span.at), .bytes = @intCast(span.bytes) };
            }
            const rows = _image.rowsAt(image, level, layer);
            return .{ .at = rows.at, .bytes = @as(usize, rows.pitch) * _image.levelSize(image, level)[1] };
        },
        .texture => {
            if (level >= image.levels) return null;
            // On a device of a layout of its own, where its driver says
            // (since 1.141): the cores' places for the levels are not the
            // V3D's, whose level 0 lies last.
            if (image.device.physical.ops.texture_level) |own| {
                const span = own(image, level, layer);
                return .{ .at = @intCast(span.at), .bytes = @intCast(span.bytes) };
            }
            const texels = &image.texels;
            if (level >= texels.levels) return null;
            const layer_at = @as(usize, @intCast(image.layer_bytes)) * layer;
            const at = texels.layout[level].start;
            const end = if (level + 1 < texels.levels) texels.layout[level + 1].start else @as(u32, @intCast(image.layer_bytes));
            return if (end <= at) null else .{ .at = layer_at + at, .bytes = end - at };
        },
        .depth => return null,
    }
}

/// One texel written over `count` bytes of them.
fn fill(into: [*]u8, count: usize, texel: Texel) void {
    switch (texel) {
        .one => |value| @memset(into[0..count], value),
        .two => |value| {
            const halves: [*]align(1) u16 = @ptrCast(into);
            @memset(halves[0 .. count / 2], value);
        },
        .four => |value| {
            const words: [*]align(1) u32 = @ptrCast(into);
            @memset(words[0 .. count / 4], value);
        },
        .eight => |value| {
            const pairs: [*]align(1) u64 = @ptrCast(into);
            @memset(pairs[0 .. count / 8], value);
        },
        .sixteen => |value| {
            const quads: [*]align(1) u128 = @ptrCast(into);
            @memset(quads[0 .. count / 16], value);
        },
    }
}

/// A texel as it lies in memory, which is as wide as that memory keeps one.
const Texel = union(enum) { one: u8, two: u16, four: u32, eight: u64, sixteen: u128 };

/// The colour, 0xAARRGGBB, as this image keeps a texel, or its channels as
/// they were given where the format holds more than a byte of each; null
/// for memory whose texel this cannot write. How wide one is depends on the
/// image's kind and not only on its format: a `texture` keeps an 8888 texel
/// spread over 64 bits, ready for the filter to mix, which is what
/// `texture.spread` makes of it.
fn texelOf(image: *const Image, color: u32, parts: [4]f32, words: [4]u32) ?Texel {
    // An image of whole numbers reads the colour's own words, signed
    // where its format is (since 1.70): a number above 1 is what such a
    // format carries and `float32` cannot say.
    var wholes = [4]i64{ 0, 0, 0, 0 };
    if (image.kind == .texture) if (image.texels.format.wholesOf()) |one| {
        for (&wholes, words) |*whole, word| whole.* = if (one.signed) @as(i32, @bitCast(word)) else word;
    };
    return switch (image.kind) {
        .rows => switch (image.format) {
            .b8g8r8a8_unorm => .{ .four = color },
            .r8g8b8a8_unorm => .{ .four = color & 0xFF00_FF00 | (color >> 16 & 0xFF) | (color & 0xFF) << 16 },
            .r5g6b5_unorm_pack16 => .{ .two = narrow(color) },
            // A colour attachment the tiles keep in its own bytes (since
            // 1.226): the clear's floats in the format, as a tile's clear
            // writes them (`raster.encodeWords`).
            else => partsTexel(_image.targetTexels(image.format), parts),
        },
        // On a device of a layout of its own a texel is kept as a buffer
        // holds it in the image's format (`_image.readTexel`), not as the
        // cores keep it: until 1.141 the clear wrote the cores' 64-bit
        // texel there, every second word of it read as a texel.
        .texture => if (image.device.physical.ops.texture_offset != null) switch (image.format) {
            .b8g8r8a8_unorm => .{ .four = color },
            .r8g8b8a8_unorm => .{ .four = color & 0xFF00_FF00 | (color >> 16 & 0xFF) | (color & 0xFF) << 16 },
            .r5g6b5_unorm_pack16 => .{ .two = narrow(color) },
            .r8_unorm => .{ .one = @truncate(color >> 16) },
            else => null,
        } else switch (image.texels.format) {
            .rgba8888 => .{ .eight = texture.spread(color) },
            // A texel kept smaller than its colour (since 1.48): the word
            // as it is, and the red alone.
            .argb8888 => .{ .four = color },
            .r8 => .{ .one = @truncate(color >> 16) },
            .rgb565 => .{ .two = narrow(color) },
            // A float texture takes the four channels as they were
            // given, put into its own texel the way a copy of one would
            // be (since 1.61): a channel above 1 or below 0 goes in as
            // far as the format reaches, rather than being rounded to a
            // byte on the way.
            .rgba16f => .{ .eight = pattern(.rgba16f, u64, parts) },
            .rgba32f => .{ .sixteen = pattern(.rgba32f, u128, parts) },
            .rg11b10f => .{ .four = pattern(.rg11b10f, u32, parts) },
            .rgb9e5 => .{ .four = pattern(.rgb9e5, u32, parts) },
            .r32f => .{ .four = pattern(.r32f, u32, parts) },
            // A texture whose channels are its own takes them the same
            // way (since 1.69): each held to 0 to 1 and written at the
            // width that channel has, where a colour of 8 bits would
            // throw half of a 16-bit one away.
            .rg8 => .{ .two = channelPattern(.rg8, u16, parts) },
            .r16 => .{ .two = channelPattern(.r16, u16, parts) },
            .rg16 => .{ .four = channelPattern(.rg16, u32, parts) },
            .rgba16 => .{ .eight = channelPattern(.rgba16, u64, parts) },
            // A texture of whole numbers takes the numbers themselves
            // (since 1.70), each held to what its channel holds: a clear
            // of such an image reads `uint32` or `int32` of the colour
            // rather than `float32`, as Vulkan has it.
            .r8u, .r8i => .{ .one = wholePattern(image.texels.format, u8, wholes) },
            .rg8u, .rg8i, .r16u, .r16i => .{ .two = wholePattern(image.texels.format, u16, wholes) },
            .rgba8u, .rgba8i, .rg16u, .rg16i, .r32u, .r32i => .{ .four = wholePattern(image.texels.format, u32, wholes) },
            .rgba16u, .rgba16i, .rg32u, .rg32i => .{ .eight = wholePattern(image.texels.format, u64, wholes) },
            .rgba32u, .rgba32i => .{ .sixteen = wholePattern(image.texels.format, u128, wholes) },
            // R8G8B8A8's four bytes as they lie, red first: how a texture a
            // view of another format may be made of keeps them (since
            // 1.131), and the same bytes its rows would hold.
            .rgba8 => .{ .four = color & 0xFF00_FF00 | (color >> 16 & 0xFF) | (color & 0xFF) << 16 },
            // A clear of a colour is not for a depth texture:
            // CmdClearDepthStencilImage writes that one. Nor for a
            // compressed image, whose texels are written as whole blocks
            // and which nothing here compresses.
            .d16, .d24, .bc1, .bc1_rgb, .bc2, .bc3, .bc4, .bc5, .bc7, .bc6hu, .bc6hs => null,
        },
        // Its pixels are rows of depth, which a clear of a colour does
        // not write; a transient one's live in the tiles.
        .depth => null,
    };
}

/// The four floats of a clear written as one texel of `format`, for a fill:
/// held to 0 to 1 for a format of those, an sRGB one's through the
/// transfer function, and a float format's as they are at its width.
/// Null for `.none`. (Since 1.226.)
fn partsTexel(format: shader.TexelFormat, parts: [4]f32) ?Texel {
    if (format == .none) return null;
    var bytes: [16]u8 = @splat(0);
    var one = shader.Texels{ .bytes = &bytes, .count = 1, .format = format, .writable = true };
    one.set(0, parts);
    return switch (format.bytes()) {
        1 => .{ .one = bytes[0] },
        2 => .{ .two = std.mem.readInt(u16, bytes[0..2], .little) },
        4 => .{ .four = std.mem.readInt(u32, bytes[0..4], .little) },
        8 => .{ .eight = std.mem.readInt(u64, bytes[0..8], .little) },
        16 => .{ .sixteen = std.mem.readInt(u128, bytes[0..16], .little) },
        else => null,
    };
}

/// A float format's texel as the word a fill writes over and over: the
/// channels put into the format's own bytes, red first, which is the same
/// encoder a copy into such an image uses. (Since 1.61.)
fn pattern(comptime format: texture.Format, comptime Word: type, parts: [4]f32) Word {
    var bytes: [@sizeOf(Word)]u8 = @splat(0);
    texture.putFloatTexel(format, &bytes, parts);
    return @bitCast(bytes);
}

/// The same for a format whose channels are its own: each channel put
/// into its own bytes, red first, by the encoder a copy into such an
/// image uses. (Since 1.69.)
fn channelPattern(format: texture.Format, comptime Word: type, parts: [4]f32) Word {
    var bytes: [@sizeOf(Word)]u8 = @splat(0);
    texture.putChannelParts(format, &bytes, parts);
    return @bitCast(bytes);
}

/// The same for a format of whole numbers: the four numbers put into
/// their own bytes, red first, by the encoder a copy into such an image
/// uses. (Since 1.70.)
fn wholePattern(format: texture.Format, comptime Word: type, wholes: [4]i64) Word {
    var bytes: [@sizeOf(Word)]u8 = @splat(0);
    texture.putWholeParts(format, &bytes, wholes);
    return @bitCast(bytes);
}

/// A colour, 0xAARRGGBB, as 565.
fn narrow(color: u32) u16 {
    return @truncate(color >> 8 & 0xF800 | color >> 5 & 0x07E0 | color >> 3 & 0x001F);
}

pub fn blitImage(command: *const _command.BlitImage) void {
    const source = command.source;
    const destination = command.destination;
    if (!_image.readable(source) or !_image.readable(destination)) return;
    // An image of more than one sample is no blit's, either way
    // (VUID-vkCmdBlitImage-srcImage-00233, VUID-vkCmdBlitImage-dstImage-00234).
    if (source.samples != 1 or destination.samples != 1) return;
    // A depth is blitted into an image of its own format alone, and
    // without a filter (VUID-vkCmdBlitImage-srcImage-00231, -00232): each
    // pixel takes the nearest one's depth as it lies (since 1.126), which
    // is lavapipe's blit of the depth aspect (`handle_blit_image`,
    // src/gallium/frontends/lavapipe/lvp_execute.c:3040-3047). D16_UNORM
    // and X8_D24_UNORM_PACK32 (since 1.222) are the formats that say so;
    // one with a stencil is left alone. Before 1.126 a blit into a depth
    // image wrote two bytes it never set.
    const depth = source.kind == .depth;
    if (depth or destination.kind == .depth) {
        if (source.format != destination.format) return;
        if (source.format != .d16_unorm and source.format != .x8_d24_unorm_pack32) return;
    } else if ((_image.blocked(destination) or _image.keptTexels(destination)) and !_image.drawnRows(destination)) {
        // A compressed source is read block by block and scaled like any
        // other, and a float one texel by texel; nothing here compresses
        // or makes floats, so a destination that keeps what it was given
        // is left alone, as Vulkan does not allow a compressed one either.
        return;
    }
    for (_stream.items(_command.BlitImage, facet.ImageBlit, command, command.count)) |*region| {
        const from_level = region.src_subresource.mip_level;
        const to_level = region.dst_subresource.mip_level;
        if (from_level >= source.levels or to_level >= destination.levels) continue;
        const from_size = _image.levelSize(source, from_level);
        const to_size = _image.levelSize(destination, to_level);
        const to_x = [2]i32{ region.dst_offsets[0].x, region.dst_offsets[1].x };
        const to_y = [2]i32{ region.dst_offsets[0].y, region.dst_offsets[1].y };
        const from_x = [2]i32{ region.src_offsets[0].x, region.src_offsets[1].x };
        const from_y = [2]i32{ region.src_offsets[0].y, region.src_offsets[1].y };
        if (to_x[0] == to_x[1] or to_y[0] == to_y[1] or from_x[0] == from_x[1] or from_y[0] == from_y[1]) continue;
        const left = @max(@min(to_x[0], to_x[1]), 0);
        const right = @min(@max(to_x[0], to_x[1]), @as(i32, @intCast(to_size[0])));
        const top = @max(@min(to_y[0], to_y[1]), 0);
        const bottom = @min(@max(to_y[0], to_y[1]), @as(i32, @intCast(to_size[1])));
        const from_layers = _image.layersOf(source, region.src_subresource, @min(region.src_offsets[0].z, region.src_offsets[1].z), @abs(region.src_offsets[1].z - region.src_offsets[0].z)) orelse continue;
        const to_layers = _image.layersOf(destination, region.dst_subresource, @min(region.dst_offsets[0].z, region.dst_offsets[1].z), @abs(region.dst_offsets[1].z - region.dst_offsets[0].z)) orelse continue;
        for (0..to_layers.count) |slice| {
            const to_layer = to_layers.first + @as(u32, @intCast(slice));
            const from_layer = from_layers.first + @as(u32, @intCast(slice * from_layers.count / to_layers.count));
            var y = top;
            while (y < bottom) : (y += 1) {
                const v = along(y, to_y, from_y);
                var x = left;
                while (x < right) : (x += 1) {
                    const u = along(x, to_x, from_x);
                    if (depth) {
                        var texel: [4]u8 = undefined;
                        _image.readTexel(source, from_level, from_layer, held(@intFromFloat(@floor(u)), from_size[0]), held(@intFromFloat(@floor(v)), from_size[1]), &texel);
                        _image.writeTexel(destination, to_level, to_layer, @intCast(x), @intCast(y), &texel);
                        continue;
                    }
                    const color = if (command.filter == .linear) linear: {
                        const low_u = u - 0.5;
                        const low_v = v - 0.5;
                        const whole_u = @floor(low_u);
                        const whole_v = @floor(low_v);
                        const first_u: i32 = @intFromFloat(whole_u);
                        const first_v: i32 = @intFromFloat(whole_v);
                        const across = low_u - whole_u;
                        const upper = mixed(colorAt(source, from_level, from_layer, held(first_u, from_size[0]), held(first_v, from_size[1])), colorAt(source, from_level, from_layer, held(first_u + 1, from_size[0]), held(first_v, from_size[1])), across);
                        const lower = mixed(colorAt(source, from_level, from_layer, held(first_u, from_size[0]), held(first_v + 1, from_size[1])), colorAt(source, from_level, from_layer, held(first_u + 1, from_size[0]), held(first_v + 1, from_size[1])), across);
                        break :linear mixed(upper, lower, low_v - whole_v);
                    } else colorAt(source, from_level, from_layer, held(@intFromFloat(@floor(u)), from_size[0]), held(@intFromFloat(@floor(v)), from_size[1]));
                    // Room for the widest, four floats (since 1.226).
                    var texel: [16]u8 = undefined;
                    _image.bytesOfColor(destination.format, color, &texel);
                    _image.writeTexel(destination, to_level, to_layer, @intCast(x), @intCast(y), &texel);
                }
            }
        }
    }
}

test "scaled, turned round and rounded as it should" {
    const testing = std.testing;
    try testing.expectEqual(@as(f32, 2), along(0, .{ 0, 4 }, .{ 0, 16 }));
    try testing.expectEqual(@as(f32, 14), along(0, .{ 4, 0 }, .{ 0, 16 }));
    try testing.expectEqual(@as(u32, 0x8080_8080), mixed(0, 0xFFFF_FFFF, 0.5));
    try testing.expectEqual(@as(u32, 0), held(-3, 8));
    try testing.expectEqual(@as(u32, 7), held(30, 8));
}

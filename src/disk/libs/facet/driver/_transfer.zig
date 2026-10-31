// SPDX-License-Identifier: MIT
//! Copies between images and buffers, as every driver does them: on the
//! cores, texel by texel, through what `_image` knows of each image's layout.
//! They come after what drew into the images has finished, as a queue plays
//! a command only after the one before it.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const _buffer = @import("../buffer/_buffer.zig");
const _command = @import("../command/_command.zig");
const _stream = @import("../command/_stream.zig");
const _image = @import("../image/_image.zig");
const Image = _image.Image;

/// CmdCopyImage's regions, the part of each inside both images. Texels go as
/// they are: images of the same size of texel.
pub fn copyImage(command: *const _command.CopyImage) void {
    const source = command.source;
    const destination = command.destination;
    if (!_image.readable(source) or !_image.readable(destination)) return;
    const pixel = _image.bytesOf(source.format);
    if (pixel != _image.bytesOf(destination.format)) return;
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
        if (from_x >= from_size[0] or from_y >= from_size[1] or to_x >= to_size[0] or to_y >= to_size[1]) continue;
        const width = @min(region.extent.width, from_size[0] - from_x, to_size[0] - to_x);
        const height = @min(region.extent.height, from_size[1] - from_y, to_size[1] - to_y);
        var texel: [4]u8 = undefined;
        for (0..height) |row| for (0..width) |column| {
            _image.readTexel(source, from_level, from_x + @as(u32, @intCast(column)), from_y + @as(u32, @intCast(row)), &texel);
            _image.writeTexel(destination, to_level, to_x + @as(u32, @intCast(column)), to_y + @as(u32, @intCast(row)), &texel);
        };
    }
}

/// CmdCopyImageToBuffer's regions: the part of each inside the image, as far
/// as the buffer goes.
pub fn copyImageToBuffer(command: *const _command.CopyImageToBuffer) void {
    const image = command.image;
    if (!_image.readable(image)) return;
    const into = _buffer.bytes(command.destination, 0, facet.WHOLE_SIZE) orelse return;
    const pixel = _image.bytesOf(image.format);
    for (_stream.items(_command.CopyImageToBuffer, facet.BufferImageCopy, command, command.count)) |*region| {
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
        for (0..height) |row| {
            const at = start + row * pitch;
            if (at + width * pixel > into.len) break;
            for (0..width) |column| {
                _image.readTexel(image, level, left + @as(u32, @intCast(column)), top + @as(u32, @intCast(row)), into[at + column * pixel ..]);
            }
        }
    }
}

/// The colours of a level read by way of 0xAARRGGBB.
fn colorAt(image: *const Image, level: u32, x: u32, y: u32) u32 {
    var texel: [4]u8 = undefined;
    _image.readTexel(image, level, x, y, &texel);
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
pub fn blitImage(command: *const _command.BlitImage) void {
    const source = command.source;
    const destination = command.destination;
    if (!_image.readable(source) or !_image.readable(destination)) return;
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
        var y = top;
        while (y < bottom) : (y += 1) {
            const v = along(y, to_y, from_y);
            var x = left;
            while (x < right) : (x += 1) {
                const u = along(x, to_x, from_x);
                const color = if (command.filter == .linear) linear: {
                    const low_u = u - 0.5;
                    const low_v = v - 0.5;
                    const whole_u = @floor(low_u);
                    const whole_v = @floor(low_v);
                    const first_u: i32 = @intFromFloat(whole_u);
                    const first_v: i32 = @intFromFloat(whole_v);
                    const across = low_u - whole_u;
                    const upper = mixed(colorAt(source, from_level, held(first_u, from_size[0]), held(first_v, from_size[1])), colorAt(source, from_level, held(first_u + 1, from_size[0]), held(first_v, from_size[1])), across);
                    const lower = mixed(colorAt(source, from_level, held(first_u, from_size[0]), held(first_v + 1, from_size[1])), colorAt(source, from_level, held(first_u + 1, from_size[0]), held(first_v + 1, from_size[1])), across);
                    break :linear mixed(upper, lower, low_v - whole_v);
                } else colorAt(source, from_level, held(@intFromFloat(@floor(u)), from_size[0]), held(@intFromFloat(@floor(v)), from_size[1]));
                var texel: [4]u8 = undefined;
                _image.bytesOfColor(destination.format, color, &texel);
                _image.writeTexel(destination, to_level, @intCast(x), @intCast(y), &texel);
            }
        }
    }
}

test "scaled, turned round and rounded as it should" {
    const testing = std.testing;
    try testing.expectEqual(@as(f32, 2), along(0, .{ 0, 4 }, .{ 0, 16 }));
    try testing.expectEqual(@as(f32, 14), along(0, .{ 4, 0 }, .{ 0, 16 }) );
    try testing.expectEqual(@as(u32, 0x8080_8080), mixed(0, 0xFFFF_FFFF, 0.5));
    try testing.expectEqual(@as(u32, 0), held(-3, 8));
    try testing.expectEqual(@as(u32, 7), held(30, 8));
}

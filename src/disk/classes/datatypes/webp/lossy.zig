// SPDX-License-Identifier: MIT
//! A lossy WebP picture (`VP8 `): one VP8 key frame, decoded by vp8.vcodec's
//! decoder (`vp8core`), and its brightness and two colour differences
//! made red, green and blue a row at a time.
//!
//! The colour planes are at half the size each way. **A pixel's colour
//! is taken smoothly** from the four samples around it, nine sixteenths
//! of the nearest, three of each of the two beside it and one of the far
//! one - the way the format's own decoder brings them to full size, its
//! rounding too: a row is made from the colour row nearest it and the
//! one beyond, the first and last rows from the nearest alone. The sum
//! is made in two steps, the diagonals first, as that decoder makes it.
//!
//! The colours are BT.601's in its limited range, in fourteen-bit steps
//! as that decoder has them.

const vp8 = @import("vp8core");

pub const Env = vp8.Env;
pub const Error = vp8.Error;

/// A decoded picture: the decoder that holds its planes, and the frame.
pub const Picture = struct {
    decoder: *vp8.Decoder,
    frame: *const vp8.Frame,
    width: u32,
    height: u32,

    /// The planes given back.
    pub fn deinit(picture: *Picture) void {
        picture.decoder.release();
        picture.decoder.destroy();
    }
};

/// The size a VP8 chunk's key frame says, or null for one that is not a
/// key frame.
pub fn sizeOf(data: []const u8) ?[2]u32 {
    if (data.len < 10) return null;
    if (data[0] & 1 != 0) return null;
    if (data[3] != 0x9D or data[4] != 0x01 or data[5] != 0x2A) return null;
    const width = (@as(u32, data[6]) | @as(u32, data[7]) << 8) & 0x3FFF;
    const height = (@as(u32, data[8]) | @as(u32, data[9]) << 8) & 0x3FFF;
    if (width == 0 or height == 0) return null;
    return .{ width, height };
}

/// The chunk's key frame decoded.
pub fn decode(env: Env, data: []const u8) Error!Picture {
    if (sizeOf(data) == null) return Error.Corrupt;
    const decoder = vp8.Decoder.create(env) orelse return Error.NoMemory;
    errdefer decoder.destroy();
    try decoder.decodeFrame(data, 0, false);
    decoder.flush();
    // A frame not meant to be shown is no picture.
    const frame = decoder.next() orelse return Error.Corrupt;
    return .{ .decoder = decoder, .frame = frame, .width = frame.shown_width, .height = frame.shown_height };
}

/// Row `y` of the picture as red, green, blue and full coverage, four
/// bytes a pixel, into `into`.
pub fn row(picture: *const Picture, y: u32, into: [*]u8) void {
    const frame = picture.frame;
    const colour_rows = (picture.height + 1) / 2;
    // The colour row nearest this one, and the one on its far side.
    const near = y / 2;
    const far = if (y & 1 == 0) (if (near == 0) 0 else near - 1) else @min(near + 1, colour_rows - 1);
    const bright = frame.planes[0] + @as(usize, y) * frame.stride[0];
    const near_blue = frame.planes[1] + @as(usize, near) * frame.stride[1];
    const near_red = frame.planes[2] + @as(usize, near) * frame.stride[2];
    const far_blue = frame.planes[1] + @as(usize, far) * frame.stride[1];
    const far_red = frame.planes[2] + @as(usize, far) * frame.stride[2];
    const width = picture.width;

    // The first pixel: three of the nearest sample to one of the far.
    pixel(bright[0], edge(near_blue[0], far_blue[0]), edge(near_red[0], far_red[0]), into);
    const pairs = (width - 1) / 2;
    var pair: u32 = 1;
    while (pair <= pairs) : (pair += 1) {
        const left = pair - 1;
        const blue = Mixed.of(near_blue[left], near_blue[pair], far_blue[left], far_blue[pair]);
        const red = Mixed.of(near_red[left], near_red[pair], far_red[left], far_red[pair]);
        const odd = 2 * pair - 1;
        pixel(bright[odd], blue.left, red.left, into + odd * 4);
        pixel(bright[odd + 1], blue.right, red.right, into + (odd + 1) * 4);
    }
    // An even width ends on a pixel of its own, from the last samples.
    if (width & 1 == 0) {
        const last = width - 1;
        const sample = pairs;
        pixel(bright[last], edge(near_blue[sample], far_blue[sample]), edge(near_red[sample], far_red[sample]), into + last * 4);
    }
}

/// Three of the near sample to one of the far.
fn edge(near: u8, far: u8) u8 {
    return @intCast((3 * @as(u32, near) + far + 2) >> 2);
}

/// The two pixels between two columns of samples: the one nearer the
/// left column, and the one nearer the right.
const Mixed = struct {
    left: u8,
    right: u8,

    fn of(near_left: u8, near_right: u8, far_left: u8, far_right: u8) Mixed {
        const nl: u32 = near_left;
        const nr: u32 = near_right;
        const fl: u32 = far_left;
        const fr: u32 = far_right;
        const all = nl + nr + fl + fr + 8;
        // Each diagonal's mix, then each pixel halfway from it to its
        // nearest sample: 9/16, 3/16, 3/16, 1/16.
        const toward_left = (all + 2 * (nr + fl)) >> 3;
        const toward_right = (all + 2 * (nl + fr)) >> 3;
        return .{
            .left = @intCast((toward_left + nl) >> 1),
            .right = @intCast((toward_right + nr) >> 1),
        };
    }
};

fn highPart(value: i32, factor: i32) i32 {
    return (value * factor) >> 8;
}

/// A fourteen-bit sum held to a byte.
fn clip(value: i32) u8 {
    if (value & ~@as(i32, (256 << 6) - 1) == 0) return @intCast(value >> 6);
    return if (value < 0) 0 else 255;
}

/// One pixel from its brightness and colour differences.
fn pixel(bright: u8, blue_difference: u8, red_difference: u8, into: [*]u8) void {
    const y: i32 = bright;
    const u: i32 = blue_difference;
    const v: i32 = red_difference;
    into[0] = clip(highPart(y, 19077) + highPart(v, 26149) - 14234);
    into[1] = clip(highPart(y, 19077) - highPart(u, 6419) - highPart(v, 13320) + 8708);
    into[2] = clip(highPart(y, 19077) + highPart(u, 33050) - 17685);
    into[3] = 0xFF;
}

const std = @import("std");
const testing = std.testing;

test "a key frame's size, and what is not one" {
    const data = [_]u8{ 0x50, 0x01, 0x00, 0x9D, 0x01, 0x2A, 100, 0x40, 50, 0 };
    const size = sizeOf(&data).?;
    try testing.expectEqual(@as(u32, 100), size[0]);
    try testing.expectEqual(@as(u32, 50), size[1]);
    var inter = data;
    inter[0] |= 1;
    try testing.expect(sizeOf(&inter) == null);
}

test "the colours of grey, black and white" {
    var into: [4]u8 = undefined;
    pixel(126, 128, 128, &into);
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255 }, &into);
    pixel(16, 128, 128, &into);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, &into);
    pixel(235, 128, 128, &into);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, &into);
}

test "between four samples: nine sixteenths of the nearest" {
    const mixed = Mixed.of(160, 0, 0, 0);
    try testing.expectEqual(@as(u8, 90), mixed.left);
    try testing.expectEqual(@as(u8, 30), mixed.right);
    try testing.expectEqual(@as(u8, 120), edge(160, 0));
}

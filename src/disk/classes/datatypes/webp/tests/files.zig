// SPDX-License-Identifier: MIT
//! Host tests of the WebP decoder on whole files - a lossless picture
//! with coverage, a lossy one with its coverage chunk, and an animation
//! of lossy frames laid over one another - against the pixels the
//! format's own decoder makes of them, by a hash of each picture's red,
//! green, blue and coverage bytes.

const std = @import("std");
const decode = @import("../decode.zig");

const testing = std.testing;

/// FNV-1a, 64 bits, of a picture's pixels as bytes of red, green, blue
/// and coverage.
fn hashOf(pixels: []const u32) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (pixels) |pixel| {
        const bytes = [4]u8{ @truncate(pixel >> 16), @truncate(pixel >> 8), @truncate(pixel), @truncate(pixel >> 24) };
        for (bytes) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    }
    return hash;
}

fn stillHash(file: []const u8) !u64 {
    const info = try decode.readInfo(file);
    const pixels = try testing.allocator.alloc(u32, @as(usize, info.width) * info.height);
    defer testing.allocator.free(pixels);
    try decode.decodeImage(testing_env, info.image.?, info.width, info.height, pixels);
    return hashOf(pixels);
}

test "a lossless picture with coverage, as the format's decoder makes it" {
    try testing.expectEqual(@as(u64, 0x95a852c98bc8c489), try stillHash(@embedFile("Lossless.webp")));
}

test "a lossy picture and its coverage, as the format's decoder makes them" {
    try testing.expectEqual(@as(u64, 0x3d135a6e279917d7), try stillHash(@embedFile("Lossy.webp")));
}

test "an animation's frames laid on one another, as the format's decoder lays them" {
    const file = @embedFile("Animation.webp");
    const info = try decode.readInfo(file);
    try testing.expect(info.animated);
    try testing.expect(decode.isAnimation(file[0..decode.animation_test_bytes]));
    try testing.expectEqual(@as(u32, 6), try decode.countFrames(file, &info, 100));
    const expected = [_]u64{ 0x447730edcc0d0376, 0xe0965049db2542e7, 0xa3efa7cea7ed3886, 0x086a59e921815995, 0x71e75ba4a4e9700a, 0x82c28889387bcc65 };
    const total = @as(usize, info.width) * info.height;
    const canvas_pixels = try testing.allocator.alloc(u32, total);
    defer testing.allocator.free(canvas_pixels);
    const unpacked = try testing.allocator.alloc(u32, total);
    defer testing.allocator.free(unpacked);
    var canvas = decode.Canvas{ .pixels = canvas_pixels, .width = info.width, .height = info.height };
    canvas.reset();
    var at = info.frames_at;
    for (expected) |hash| {
        const frame = (try decode.readFrame(file, &info, at)).?;
        const pixels = unpacked[0 .. @as(usize, frame.width) * frame.height];
        try decode.decodeImage(testing_env, frame.image, frame.width, frame.height, pixels);
        canvas.add(&frame, pixels);
        try testing.expectEqual(hash, hashOf(canvas_pixels));
        at = frame.next_at;
    }
    try testing.expect(try decode.readFrame(file, &info, at) == null);
}

test "a file cut short or spoilt is refused, not misread" {
    const file = @embedFile("Lossless.webp");
    const info = try decode.readInfo(file);
    const pixels = try testing.allocator.alloc(u32, @as(usize, info.width) * info.height);
    defer testing.allocator.free(pixels);
    var cut = info.image.?;
    cut.data = cut.data[0 .. cut.data.len / 2];
    try testing.expectError(decode.Error.Corrupt, decode.decodeImage(testing_env, cut, info.width, info.height, pixels));
    try testing.expectError(decode.Error.Corrupt, decode.readInfo(file[0..20]));
}

/// Memory for the tests, from the testing allocator.
const testing_env = decode.Env{ .ctx = undefined, .alloc = testingAlloc, .free = testingFree };

fn testingAlloc(_: *anyopaque, length: usize, clear: bool) ?[*]u8 {
    const memory = testing.allocator.alignedAlloc(u8, .@"16", length) catch return null;
    if (clear) @memset(memory, 0);
    return memory.ptr;
}

fn testingFree(_: *anyopaque, memory: [*]u8, length: usize) void {
    const aligned: [*]align(16) u8 = @alignCast(memory);
    testing.allocator.free(aligned[0..length]);
}

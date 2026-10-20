// SPDX-License-Identifier: MPL-2.0
//! The golden mix: a fixed set of voices - every sample form, rates above
//! and below the output's, a pan to each side, loops, a write played for
//! ever, a queue handed on as it plays and a burst loud enough to clip -
//! mixed for a tenth of a second in buffers of the device's size, and the
//! reference it is held to.
//!
//! The reference, `golden.pcm`, is the mix as 16-bit stereo frames in
//! little-endian order. The test below compares the two byte for byte, so
//! a change to the mixer that changes what is heard shows here; one that
//! is meant to is made with `./zig build audio-golden`, which writes the
//! file again from `render`, and the difference is looked at before the
//! new file is kept. Nothing here touches hardware; every sample is worked
//! out with integers, so the mix is the same on every host.

const std = @import("std");
pub const mixer = @import("mixer.zig");

/// What is rendered: a tenth of a second at the output's 48 kHz, in
/// buffers of the device's 256 frames, so the queue's refills and the
/// loops fall across buffer boundaries as they do on a board.
pub const frames: usize = 4800;
pub const buffer_frames: usize = 256;
pub const bytes: usize = frames * 2 * 2;

const out_rate: u32 = 48_000;

/// A triangle of `period` frames between -amplitude and amplitude, as
/// 16-bit samples.
fn triangle(comptime count: usize, comptime period: usize, comptime amplitude: i32) [count * 2]u8 {
    @setEvalBranchQuota(100_000);
    var data: [count * 2]u8 = undefined;
    for (0..count) |i| {
        const phase: i32 = @intCast(i % period);
        const half: i32 = @intCast(period / 2);
        const rising = if (phase < half) phase else @as(i32, @intCast(period)) - phase;
        const sample: i16 = @intCast(@divTrunc(rising * 4 * amplitude, @as(i32, @intCast(period))) - amplitude);
        const word: u16 = @bitCast(sample);
        data[i * 2] = @truncate(word);
        data[i * 2 + 1] = @truncate(word >> 8);
    }
    return data;
}

/// 8-bit stereo: a saw on the left, a square on the right.
fn sawAndSquare(comptime count: usize) [count * 2]u8 {
    @setEvalBranchQuota(100_000);
    var data: [count * 2]u8 = undefined;
    for (0..count) |i| {
        const saw: i8 = @intCast(@as(i32, @intCast(i * 4 % 256)) - 128);
        const square: i8 = if (i % 16 < 8) 90 else -90;
        data[i * 2] = @bitCast(saw);
        data[i * 2 + 1] = @bitCast(square);
    }
    return data;
}

/// 32-bit mono noise, low bytes set, so the cut to 16 bits is heard.
fn noise32(comptime count: usize) [count * 4]u8 {
    @setEvalBranchQuota(100_000);
    var data: [count * 4]u8 = undefined;
    var state: u32 = 0x1234_5678;
    for (0..count) |i| {
        state = state *% 1_664_525 +% 1_013_904_223;
        // A quarter of full scale, so the sum stays inside 16 bits.
        const sample: i32 = @as(i32, @bitCast(state)) >> 2;
        const word: u32 = @bitCast(sample);
        data[i * 4] = @truncate(word);
        data[i * 4 + 1] = @truncate(word >> 8);
        data[i * 4 + 2] = @truncate(word >> 16);
        data[i * 4 + 3] = @truncate(word >> 24);
    }
    return data;
}

/// 16-bit stereo blocks for the queue: a ramp on each side, each block
/// starting where the last ended.
fn stereoBlock(comptime count: usize, comptime start: i32) [count * 4]u8 {
    @setEvalBranchQuota(100_000);
    var data: [count * 4]u8 = undefined;
    for (0..count) |i| {
        const at: i32 = start + @as(i32, @intCast(i));
        const left: i16 = @intCast(@mod(at * 37, 16_000) - 8_000);
        const right: i16 = @intCast(8_000 - @mod(at * 53, 16_000));
        for ([_]i16{ left, right }, 0..) |sample, side| {
            const word: u16 = @bitCast(sample);
            data[i * 4 + side * 2] = @truncate(word);
            data[i * 4 + side * 2 + 1] = @truncate(word >> 8);
        }
    }
    return data;
}

const tri = triangle(300, 50, 12_000);
const saw_square = sawAndSquare(64);
const noise = noise32(1000);
const blocks = [_][500 * 4]u8{ stereoBlock(500, 0), stereoBlock(500, 500), stereoBlock(500, 1000) };
const burst = triangle(40, 40, 30_000);

/// The queue's blocks handed over one at a time, as the device hands on a
/// stream's writes.
const Queue = struct {
    given: usize = 1,

    fn next(context: *anyopaque, _: usize) ?mixer.Queued {
        const queue: *Queue = @ptrCast(@alignCast(context));
        if (queue.given == blocks.len) return null;
        const block = &blocks[queue.given];
        queue.given += 1;
        return .{ .data = block, .frames = 500, .loops = 1, .format = mixer.s16, .channels = 2 };
    }
};

fn voice(data: []const u8, format: u8, channels: u8, rate: u32, volume: u32, pan: i32, loops: u32) mixer.Voice {
    const sample_bytes: usize = switch (format) {
        mixer.s8 => 1,
        mixer.s32 => 4,
        else => 2,
    };
    const frame = @as(usize, channels) * sample_bytes;
    const g = mixer.gains(volume, pan);
    return .{
        .data = data.ptr,
        .frames = @intCast(data.len / frame),
        .format = format,
        .channels = channels,
        .loops = loops,
        .endless = if (loops == 0) 1 else 0,
        .step = mixer.stepFor(rate, out_rate),
        .gain_left = g.left,
        .gain_right = g.right,
    };
}

/// The golden mix into `out`: `frames` stereo frames, two samples each.
pub fn render(out: *[frames * 2]i16) void {
    var voices: [mixer.max_voices]mixer.Voice = @splat(.{});
    // A 16-bit triangle at half the output's rate, leaning left, three
    // times over.
    voices[0] = voice(&tri, mixer.s16, 1, 22_050, 0x10000, -0x8000, 3);
    // 8-bit stereo, slow and quiet, for ever.
    voices[1] = voice(&saw_square, mixer.s8, 2, 11_025, 0x6000, 0, 0);
    // 32-bit noise at twice the output's rate, right only, at half.
    voices[2] = voice(&noise, mixer.s32, 1, 96_000, 0x8000, 0x10000, 1);
    // A queue of 16-bit stereo blocks at 44.1 kHz, the next handed on as
    // each is taken.
    var queue: Queue = .{};
    voices[3] = voice(&blocks[0], mixer.s16, 2, 44_100, 0x10000, 0x4000, 1);
    voices[3].queued = Queue.next(&queue, 3).?;
    // A burst at twice its volume, which clips, once.
    voices[4] = voice(&burst, mixer.s16, 1, 48_000, 0x20000, 0, 1);
    const master = mixer.masterGain(0xC000);
    var at: usize = 0;
    while (at < frames) : (at += buffer_frames) {
        const count: usize = @min(buffer_frames, frames - at);
        _ = mixer.fill(&voices, out[at * 2 ..][0 .. count * 2], .left_first, master, .{ .context = &queue, .next = Queue.next });
    }
}

/// The mix as the reference file holds it: little-endian bytes.
pub fn bytesOf(mix: *const [frames * 2]i16, into: *[bytes]u8) void {
    for (mix, 0..) |sample, i| {
        const word: u16 = @bitCast(sample);
        into[i * 2] = @truncate(word);
        into[i * 2 + 1] = @truncate(word >> 8);
    }
}

test "the golden mix is the reference, byte for byte" {
    var mix: [frames * 2]i16 = undefined;
    render(&mix);
    var made: [bytes]u8 = undefined;
    bytesOf(&mix, &made);
    const reference = @embedFile("golden.pcm");
    try std.testing.expectEqual(bytes, reference.len);
    try std.testing.expect(std.mem.eql(u8, reference, &made));
}

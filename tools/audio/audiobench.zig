// SPDX-License-Identifier: MPL-2.0
//! audiobench: how fast audio.device's mixer is on this host, for 1, 4, 8
//! and 16 voices playing at once. Run by `./zig build audio-bench`.
//!
//! Each voice is a 16-bit write played for ever at a rate of its own -
//! a 44.1 kHz stream into the 48 kHz output, so every frame is a blend of
//! two - and the voices are mixed for twenty seconds of sound in buffers
//! of the device's 256 frames. What it prints is a measure to compare one
//! change of the mixer with the one before, on the same host: what one
//! second of sound costs, and how many times faster than it plays. A
//! board's own figure is `Audio BENCH`'s.

const std = @import("std");
const golden = @import("golden");
const mixer = golden.mixer;

const out_rate: u32 = 48_000;
const seconds: u32 = 20;
const buffer_frames = golden.buffer_frames;

pub fn main(init: std.process.Init) !void {
    var data: [4096]u8 = undefined;
    for (0..data.len / 2) |i| {
        const sample: i16 = @intCast(@as(i32, @intCast(i * 97 % 20_000)) - 10_000);
        const word: u16 = @bitCast(sample);
        data[i * 2] = @truncate(word);
        data[i * 2 + 1] = @truncate(word >> 8);
    }
    var out: [buffer_frames * 2]i16 = undefined;
    std.debug.print("audio.device mixer, {d} s of sound at {d} Hz in buffers of {d} frames\n", .{ seconds, out_rate, buffer_frames });
    for ([_]usize{ 1, 4, 8, 16 }) |count| {
        var voices: [mixer.max_voices]mixer.Voice = @splat(.{});
        for (voices[0..count], 0..) |*v, n| {
            const g = mixer.gains(0x10000 / @as(u32, @intCast(count)), @as(i32, @intCast(n % 3)) * 0x4000 - 0x4000);
            v.* = .{
                .data = &data,
                .frames = data.len / 2,
                .format = mixer.s16,
                .channels = 1,
                .endless = 1,
                .step = mixer.stepFor(44_100 - @as(u32, @intCast(n)) * 100, out_rate),
                .gain_left = g.left,
                .gain_right = g.right,
            };
        }
        var check: i64 = 0;
        const buffers = seconds * out_rate / buffer_frames;
        const start = std.Io.Timestamp.now(init.io, .awake);
        for (0..buffers) |_| {
            _ = mixer.fill(&voices, &out, .left_first, mixer.gain_unity, null);
            check +%= out[0] +% out[out.len - 1];
        }
        const end = std.Io.Timestamp.now(init.io, .awake);
        const ns: u64 = @intCast(start.durationTo(end).nanoseconds);
        const per_second_us = ns / 1000 / seconds;
        const faster = @as(u64, seconds) * std.time.ns_per_s / @max(ns, 1);
        std.debug.print("{d:>3} voices: {d:>6} us a second of sound, {d:>5}x real time (check {d})\n", .{ count, per_second_us, faster, check });
    }
}

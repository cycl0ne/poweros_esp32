// SPDX-License-Identifier: MIT
//! A DTS channel's subbands turned into sound (ETSI TS 102 114 C.3.6), and
//! the channels mixed into the stream's.
//!
//! **The filter bank** is the spec's own form: each of a channel's 32
//! subbands gives a sample, a cosine modulation of them is put in the
//! history, and a window of 512 taps makes 32 samples, half of them added
//! to the next. Two sets of taps; the frame says which.
//!
//! **The mix** into two channels is the one the other kinds' streams get:
//! the centre and the surrounds at -3 dB, a single surround at -3 dB more
//! each way, the LFE left out, each side's weights scaled to sum to one -
//! so a mix never clips. A mix the stream carries for the purpose is not
//! read. A frame of one channel is heard on both, and a stream of one
//! channel hears the two sides' sum at -6 dB.

const frame = @import("frame.zig");
const tables = @import("tables.zig");
const header = @import("header.zig");

pub const SAMPLES = frame.SUBFRAME_BLOCKS * 32;

/// One channel's filter bank.
const Bank = struct {
    /// The modulated samples, newest first from `at`: `window` is long so
    /// they are copied back only now and then.
    window: [1024]f32,
    at: usize,
    /// The half of the output left for the next block.
    overlap: [32]f32,
};

pub const Synthesis = struct {
    banks: [frame.CHANNELS]Bank,
    output: [frame.CHANNELS][SAMPLES]f32,
};

/// What the filter's samples are multiplied by for 16-bit sound.
const OUTPUT_SCALE: f32 = 0.70710678;

const modulation = blk: {
    @setEvalBranchQuota(100000);
    const pi = 3.14159265358979323846;
    var m: struct { a: [16][16]f32, b: [16][16]f32, sum: [16]f32, difference: [16]f32 } = undefined;
    for (0..16) |k| {
        for (0..16) |i| {
            m.a[k][i] = @floatCast(@cos(@as(f64, (2 * i + 1) * (2 * k + 1)) * pi / 64.0));
            m.b[k][i] = @floatCast(@cos(@as(f64, i * (2 * k + 1)) * pi / 32.0));
        }
        const angle = @as(f64, 2 * k + 1) * pi / 128.0;
        m.sum[k] = @floatCast(0.25 / (2.0 * @cos(angle)));
        m.difference[k] = @floatCast(-0.25 / (2.0 * @sin(angle)));
    }
    const final = m;
    break :blk final;
};

pub fn clear(s: *Synthesis) void {
    for (&s.banks) |*bank| {
        @memset(&bank.window, 0);
        @memset(&bank.overlap, 0);
        bank.at = bank.window.len - 512;
    }
}

/// `count` blocks of a channel's subbands into its output.
pub fn channel(s: *Synthesis, d: *const frame.Decoder, ch: usize, count: usize) void {
    const bank = &s.banks[ch];
    const taps: *const [512]f32 = if (d.fields.perfect) &tables.fir_perfect else &tables.fir_nonperfect;
    const active = d.active[ch];
    const bands = &d.samples[ch];
    const out = &s.output[ch];
    var input: [32]f32 = undefined;
    for (0..count) |block| {
        for (0..32) |i| input[i] = if (i < active) bands[i][frame.FIRST + block] else 0;
        if (bank.at < 32) {
            const back = bank.window.len - 480;
            @memcpy(bank.window[back..], bank.window[bank.at..][0..480]);
            bank.at = back;
        }
        bank.at -= 32;
        const x = bank.window[bank.at..][0..512];

        var a: [16]f32 = undefined;
        var b: [16]f32 = undefined;
        for (0..16) |i| {
            a[i] = input[2 * i] + input[2 * i + 1];
            b[i] = if (i == 0) input[0] else input[2 * i] + input[2 * i - 1];
        }
        for (0..16) |k| {
            var sum_a: f32 = 0;
            var sum_b: f32 = 0;
            for (0..16) |i| {
                sum_a += a[i] * modulation.a[k][i];
                sum_b += b[i] * modulation.b[k][i];
            }
            x[k] = modulation.sum[k] * (sum_a + sum_b);
            x[31 - k] = modulation.difference[k] * (sum_a - sum_b);
        }

        const pcm = out[block * 32 ..][0..32];
        for (0..32) |i| {
            const k = 31 - i;
            var first: f32 = 0;
            var second: f32 = 0;
            var j: usize = 0;
            while (j < 512) : (j += 64) {
                first += taps[i + j] * (x[i + j] - x[j + k]);
                second += taps[32 + i + j] * (-x[i + j] - x[j + k]);
            }
            pcm[i] = (bank.overlap[i] + first) * OUTPUT_SCALE;
            bank.overlap[i] = second;
        }
    }
}

/// The frame's sum and difference coding undone over `length` samples of output.
pub fn undoSums(s: *Synthesis, d: *const frame.Decoder, mode: u32, length: usize) void {
    const f = &d.fields;
    if ((f.sum_front and mode > 0) or mode == header.SUM_DIFFERENCE) {
        const front: usize = if (mode == 5 or mode == 7 or mode == 9) 1 else 0;
        butterfly(s.output[front][0..length], s.output[front + 1][0..length]);
    }
    if (f.sum_surround and mode >= 8) {
        const surround: usize = if (mode == 9) 3 else 2;
        butterfly(s.output[surround][0..length], s.output[surround + 1][0..length]);
    }
}

fn butterfly(a: []f32, b: []f32) void {
    for (a, b) |*x, *y| {
        const sum = x.* + y.*;
        y.* = x.* - y.*;
        x.* = sum;
    }
}

/// A channel's part in each side of the mix.
const Weights = [frame.CHANNELS][2]f32;
const M3: f32 = 0.70710678;

fn normal(comptime w: []const [2]f32) Weights {
    var left: f32 = 0;
    var right: f32 = 0;
    for (w) |c| {
        left += c[0];
        right += c[1];
    }
    var out: Weights = @splat(.{ 0, 0 });
    for (w, 0..) |c, i| out[i] = .{ c[0] / left, c[1] / right };
    return out;
}

const L = [2]f32{ 1, 0 };
const R = [2]f32{ 0, 1 };
const C = [2]f32{ M3, M3 };
const LS = [2]f32{ M3, 0 };
const RS = [2]f32{ 0, M3 };
const S = [2]f32{ 0.5, 0.5 };

const mixes = [10]Weights{
    normal(&.{.{ 1, 1 }}),
    normal(&.{ L, R }),
    normal(&.{ L, R }),
    normal(&.{ L, R }),
    normal(&.{ L, R }),
    normal(&.{ C, L, R }),
    normal(&.{ L, R, S }),
    normal(&.{ C, L, R, S }),
    normal(&.{ L, R, LS, RS }),
    normal(&.{ C, L, R, LS, RS }),
};

fn sample16(value: f32) i16 {
    if (value >= 32767.0) return 32767;
    if (!(value > -32768.0)) return -32768;
    return @intFromFloat(@round(value));
}

/// The output from `first` up to `last`, mixed into `channels` channels in
/// `pcm`.
pub fn samples(s: *const Synthesis, mode: u32, count: usize, channels: usize, first: usize, last: usize, pcm: [*]i16) void {
    const weights = &mixes[mode];
    var at: usize = 0;
    for (first..last) |i| {
        var left: f32 = 0;
        var right: f32 = 0;
        for (0..count) |ch| {
            const value = s.output[ch][i];
            left += value * weights[ch][0];
            right += value * weights[ch][1];
        }
        if (channels == 1) {
            pcm[at] = sample16((left + right) * 0.5);
        } else {
            pcm[at] = sample16(left);
            pcm[at + 1] = sample16(right);
        }
        at += channels;
    }
}

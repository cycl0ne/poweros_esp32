// SPDX-License-Identifier: MIT
//! A block's coefficients turned into sound (A/52 7.9) and mixed into
//! the stream's channels (7.8).
//!
//! **The transform** of a long block is an inverse MDCT of 512 samples
//! from 256 coefficients; a block switched to short ones holds two of
//! 256 from 128 each, its coefficients interleaved. The middle half of
//! each - the rest follows from it - is windowed with a Kaiser-Bessel
//! derived window (alpha 5) and added to the half the block before left:
//! FFmpeg's arrangement, the first short transform laid against the
//! block before, the second kept for the next. The transform is the one
//! Vorbis uses (`vorbis/imdct.zig`), its middle half negated, as FFmpeg's
//! comes out.
//!
//! **The mix** into two channels is FFmpeg's: the stream's centre and
//! surround levels, the LFE left out, each side's weights scaled to sum
//! to one - so a mix never clips; into one channel the two sides' summed
//! at -3 dB. The mix is made of the channels' samples, after the
//! transforms - FFmpeg mixes the coefficients where it can, which comes
//! to the same.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const imdct = @import("../vorbis/imdct.zig");
const setup = @import("../vorbis/setup.zig");
const filterbank = @import("../aac/filterbank.zig");
const tables = @import("tables.zig");
const header = @import("header.zig");

pub const Synthesis = struct {
    long: imdct.Transform,
    short: imdct.Transform,
    /// The rising half of the window, 256 samples.
    window: [*]f32,
    /// A transform's samples.
    buffer: [*]f32,
    /// Each channel's half block left for the next, and its block's
    /// samples: the full-bandwidth channels, then the LFE.
    delay: [6][*]f32,
    output: [6][*]f32,
    /// How the channels make the stream's: as they are, the one channel
    /// on both, or mixed by `mix`, the weights of each into left and
    /// right.
    mixing: Mixing,
    mix: [2][5]f32,
};

pub const Mixing = enum { direct, both, mixed };

/// The transforms, the window and the buffers, made in `pool`: false
/// without memory.
pub fn init(sys: *ExecBase, pool: *anyopaque, s: *Synthesis) bool {
    if (!imdct.init(sys, pool, 512, &s.long)) return false;
    if (!imdct.init(sys, pool, 256, &s.short)) return false;
    s.window = setup.allocate(sys, pool, f32, 256) orelse return false;
    s.buffer = setup.allocate(sys, pool, f32, 512) orelse return false;
    for (0..6) |ch| {
        s.delay[ch] = setup.allocate(sys, pool, f32, 128) orelse return false;
        s.output[ch] = setup.allocate(sys, pool, f32, 256) orelse return false;
    }
    filterbank.kaiserBessel(s.window[0..256], 5.0);
    return true;
}

/// Nothing left over from blocks before: after a seek.
pub fn clear(s: *Synthesis) void {
    for (s.delay) |delay| @memset(delay[0..128], 0);
}

/// One channel's block: its 256 samples into `output[index]`.
pub fn channel(s: *Synthesis, coeffs: *const [256]f32, short: bool, index: usize) void {
    const buffer = s.buffer;
    const delay = s.delay[index];
    const out = s.output[index];
    if (short) {
        for (0..128) |i| buffer[i] = coeffs[2 * i];
        imdct.inverse(&s.short, buffer);
        overlap(s.window, delay, buffer + 64, out);
        for (0..128) |i| buffer[i] = coeffs[2 * i + 1];
        imdct.inverse(&s.short, buffer);
        for (0..128) |i| delay[i] = -buffer[64 + i];
    } else {
        @memcpy(buffer[0..256], coeffs);
        imdct.inverse(&s.long, buffer);
        overlap(s.window, delay, buffer + 128, out);
        for (0..128) |i| delay[i] = -buffer[256 + i];
    }
}

/// The 256 samples of a block: the half the block before left, and the
/// first quarter of this one's middle half - negated - mirrored, both
/// windowed.
fn overlap(window: [*]const f32, delay: [*]const f32, middle: [*]const f32, out: [*]f32) void {
    for (0..128) |k| {
        const before = delay[k];
        const now = -middle[127 - k];
        const rising = window[k];
        const falling = window[255 - k];
        out[k] = before * falling - now * rising;
        out[255 - k] = before * rising + now * falling;
    }
}

/// How a frame's channels make `channels` of the stream's.
pub fn setMix(s: *Synthesis, h: *const header.Header, channels: u32) void {
    const fbw: usize = tables.mode_channels[h.mode];
    if (fbw == channels) {
        s.mixing = .direct;
        return;
    }
    if (fbw == 1) {
        s.mixing = .both;
        return;
    }
    s.mixing = .mixed;
    const mix = &s.mix;
    for (0..fbw) |ch| {
        mix[0][ch] = tables.gain_levels[tables.default_mix[h.mode][ch][0]];
        mix[1][ch] = tables.gain_levels[tables.default_mix[h.mode][ch][1]];
    }
    const center = tables.gain_levels[h.center_mix];
    const surround = tables.gain_levels[h.surround_mix];
    if (h.mode > 1 and h.mode & 1 != 0) {
        mix[0][1] = center;
        mix[1][1] = center;
    }
    if (h.mode == 4 or h.mode == 5) {
        const at = h.mode - 2;
        mix[0][at] = surround * 0.7071067811865476;
        mix[1][at] = surround * 0.7071067811865476;
    }
    if (h.mode == 6 or h.mode == 7) {
        const at = h.mode - 4;
        mix[0][at] = surround;
        mix[1][at + 1] = surround;
    }
    var sums: [2]f32 = .{ 0, 0 };
    for (0..fbw) |ch| {
        sums[0] += mix[0][ch];
        sums[1] += mix[1][ch];
    }
    const scale: [2]f32 = .{ 1.0 / sums[0], 1.0 / sums[1] };
    for (0..fbw) |ch| {
        mix[0][ch] *= scale[0];
        mix[1][ch] *= scale[1];
    }
    if (channels == 1) {
        for (0..fbw) |ch| mix[0][ch] = (mix[0][ch] + mix[1][ch]) * 0.7071067811865476;
    }
}

/// Samples `first` to `last` of the block into `pcm`, the stream's
/// channels interleaved, 16 bits.
pub fn samples(s: *const Synthesis, fbw: usize, channels: usize, first: usize, last: usize, pcm: [*]i16) void {
    var at: usize = 0;
    for (first..last) |i| {
        switch (s.mixing) {
            .direct => for (0..channels) |ch| {
                pcm[at + ch] = toSixteen(s.output[ch][i]);
            },
            .both => {
                const value = toSixteen(s.output[0][i]);
                pcm[at] = value;
                pcm[at + 1] = value;
            },
            .mixed => for (0..channels) |side| {
                var sum: f32 = 0;
                for (0..fbw) |ch| sum += s.output[ch][i] * s.mix[side][ch];
                pcm[at + side] = toSixteen(sum);
            },
        }
        at += channels;
    }
}

/// A sample of -1 to 1 in 16 bits, rounded to the nearest - an even one
/// at a half - and held to the range.
fn toSixteen(sample: f32) i16 {
    const held = @max(-32768.0, @min(sample * 32768.0, 32767.0));
    // Added to 1.5 * 2^23, the sum's low bits are the rounded value.
    const sum: f32 = held + 12582912.0;
    const word: u32 = @bitCast(sum);
    return @truncate(@as(i32, @bitCast(word)) - 0x4B40_0000);
}

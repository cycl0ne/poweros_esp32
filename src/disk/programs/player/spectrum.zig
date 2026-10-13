// SPDX-License-Identifier: MIT
//! The spectrum of what is playing, for the bars: a run of samples through
//! a Hann window and a 2048-point FFT, the magnitudes gathered into bands
//! spaced evenly in pitch - each a fixed fraction of an octave, from
//! 40 Hz to 16 kHz or half the rate - in decibels. 2048 points is a bin
//! every 21.5 Hz at 44.1 kHz, which keeps the bass's bands apart: at that
//! end of the scale a band is narrower than a bin of a shorter run.
//!
//! A band's level jumps up with the sound and falls back slowly, so a beat
//! is seen at once and the bars do not flicker; a peak mark above each
//! stays a moment, then falls too. Nothing here touches the system: the
//! host tests hold it.

pub const fft_size = 2048;
const fft_bits = 11;
pub const max_bands = 48;

/// The quietest level shown, in decibels below a full-scale sine.
const floor_db: f32 = 60.0;
/// How far a level and a peak fall each look, of the bar's height, and
/// how many looks a peak stays.
const level_fall: f32 = 0.035;
const peak_fall: f32 = 0.012;
const peak_hold: u8 = 12;

pub const Spectrum = struct {
    window: [fft_size]f32 = @splat(0),
    reversed: [fft_size]u16 = @splat(0),
    twiddle_re: [fft_size / 2]f32 = @splat(0),
    twiddle_im: [fft_size / 2]f32 = @splat(0),
    re: [fft_size]f32 = @splat(0),
    im: [fft_size]f32 = @splat(0),
    /// The bands' levels and peaks, 0 to 1, and how long each peak has
    /// stayed.
    levels: [max_bands]f32 = @splat(0),
    peaks: [max_bands]f32 = @splat(0),
    held: [max_bands]u8 = @splat(0),

    /// The window, the bit-reversed order and the twiddles worked out once.
    pub fn init(s: *Spectrum) void {
        const pi = 3.14159265358979;
        for (0..fft_size) |i| {
            const x = @as(f32, @floatFromInt(i)) / @as(f32, fft_size - 1);
            s.window[i] = 0.5 - 0.5 * @cos(2.0 * pi * x);
            var r: u16 = 0;
            var v: u16 = @intCast(i);
            for (0..fft_bits) |_| {
                r = (r << 1) | (v & 1);
                v >>= 1;
            }
            s.reversed[i] = r;
        }
        for (0..fft_size / 2) |k| {
            const angle = -2.0 * pi * @as(f32, @floatFromInt(k)) / fft_size;
            s.twiddle_re[k] = @cos(angle);
            s.twiddle_im[k] = @sin(angle);
        }
    }

    /// `samples` - `fft_size` of them, -1 to 1 - into `bands` levels: the
    /// spectrum of a sound at `rate` frames a second.
    pub fn analyse(s: *Spectrum, samples: []const f32, rate: u32, bands: usize) void {
        for (0..fft_size) |i| {
            const j = s.reversed[i];
            s.re[j] = samples[i] * s.window[i];
            s.im[j] = 0;
        }
        fft(s);

        const count = @min(bands, max_bands);
        const nyquist = @as(f32, @floatFromInt(rate)) / 2.0;
        const low: f32 = 40.0;
        const high: f32 = @min(16000.0, nyquist);
        const bin_hz = @as(f32, @floatFromInt(rate)) / fft_size;
        // A full-scale sine through the Hann window peaks at a quarter of
        // the FFT's length.
        const full: f32 = fft_size / 4;
        for (0..count) |b| {
            const f0 = low * pow(high / low, @as(f32, @floatFromInt(b)) / @as(f32, @floatFromInt(count)));
            const f1 = low * pow(high / low, @as(f32, @floatFromInt(b + 1)) / @as(f32, @floatFromInt(count)));
            var first: usize = @intFromFloat(@floor(f0 / bin_hz));
            var last: usize = @intFromFloat(@floor(f1 / bin_hz));
            first = @max(first, 1);
            last = @min(@max(last, first), fft_size / 2 - 1);
            // The loudest bin, compared squared: one root for the band.
            var most: f32 = 0;
            for (first..last + 1) |k| most = @max(most, s.re[k] * s.re[k] + s.im[k] * s.im[k]);
            const db = 20.0 * @log10(@max(@sqrt(most) / full, 1e-6));
            const level = @min(@max((db + floor_db) / floor_db, 0.0), 1.0);
            settle(s, b, level);
        }
    }

    /// A band's new level: up at once, down slowly; its peak held, then
    /// falling.
    fn settle(s: *Spectrum, b: usize, level: f32) void {
        s.levels[b] = if (level > s.levels[b]) level else @max(level, s.levels[b] - level_fall);
        if (s.levels[b] >= s.peaks[b]) {
            s.peaks[b] = s.levels[b];
            s.held[b] = peak_hold;
        } else if (s.held[b] > 0) {
            s.held[b] -= 1;
        } else {
            s.peaks[b] = @max(s.levels[b], s.peaks[b] - peak_fall);
        }
    }

    /// Everything back to silence: after a stop or a seek.
    pub fn quiet(s: *Spectrum) void {
        s.levels = @splat(0);
        s.peaks = @splat(0);
        s.held = @splat(0);
    }
};

/// The radix-2 FFT in place, `re` and `im` already in bit-reversed order.
fn fft(s: *Spectrum) void {
    var size: usize = 2;
    while (size <= fft_size) : (size *= 2) {
        const half = size / 2;
        const step = fft_size / size;
        var start: usize = 0;
        while (start < fft_size) : (start += size) {
            for (0..half) |k| {
                const wr = s.twiddle_re[k * step];
                const wi = s.twiddle_im[k * step];
                const a = start + k;
                const b = a + half;
                const tr = s.re[b] * wr - s.im[b] * wi;
                const ti = s.re[b] * wi + s.im[b] * wr;
                s.re[b] = s.re[a] - tr;
                s.im[b] = s.im[a] - ti;
                s.re[a] += tr;
                s.im[a] += ti;
            }
        }
    }
}

fn pow(base: f32, exponent: f32) f32 {
    return @exp(exponent * @log(base));
}

// --- tests --------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

fn sine(into: []f32, hz: f32, rate: f32, amplitude: f32) void {
    for (into, 0..) |*x, i| x.* = amplitude * @sin(2.0 * 3.14159265358979 * hz * @as(f32, @floatFromInt(i)) / rate);
}

test "a sine lights the band it is in, and little else" {
    var s: Spectrum = .{};
    s.init();
    var samples: [fft_size]f32 = undefined;
    sine(&samples, 1000, 44100, 1.0);
    s.analyse(&samples, 44100, 24);
    var loudest: usize = 0;
    for (0..24) |b| {
        if (s.levels[b] > s.levels[loudest]) loudest = b;
    }
    // 1 kHz sits about half way between 40 Hz and 16 kHz in pitch.
    try testing.expect(loudest >= 10 and loudest <= 14);
    try testing.expect(s.levels[loudest] > 0.9);
    try testing.expect(s.levels[0] < 0.3);
    try testing.expect(s.levels[23] < 0.3);
}

test "silence is no bar; a level falls back slowly, its peak stays a while" {
    var s: Spectrum = .{};
    s.init();
    var samples: [fft_size]f32 = @splat(0);
    s.analyse(&samples, 44100, 16);
    for (s.levels[0..16]) |level| try testing.expectEqual(@as(f32, 0), level);

    sine(&samples, 200, 44100, 1.0);
    s.analyse(&samples, 44100, 16);
    var band: usize = 0;
    for (0..16) |b| {
        if (s.levels[b] > s.levels[band]) band = b;
    }
    const top = s.levels[band];
    samples = @splat(0);
    s.analyse(&samples, 44100, 16);
    try testing.expect(s.levels[band] < top and s.levels[band] > top - 0.1);
    try testing.expectEqual(top, s.peaks[band]);
}

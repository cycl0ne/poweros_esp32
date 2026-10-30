// SPDX-License-Identifier: MIT
//! AC-3's bit allocation (A/52 7.2): how many bits each mantissa has,
//! worked out from the exponents alone, as the encoder did - integers
//! throughout, so every decoder comes to the same.
//!
//! The exponents make a power spectrum (`psd`), summed by log-addition
//! into 50 bands of about a sixth of an octave. Spread over the bands
//! that follow - a fast and a slow leak, a boost below 20 bands - it is
//! the excitation, and with the threshold of hearing under it the
//! masking curve (`mask`), which the stream may move up or down band by
//! band (delta bit allocation). What a bin's power stands above the
//! curve, less the stream's offset, picks its bap from a table (`bap`).

const tables = @import("tables.zig");

/// The model's parameters: the stream's codes looked up, the decays
/// shifted down at a lower sample rate.
pub const Params = struct {
    sr_code: u32 = 0,
    sr_shift: u32 = 0,
    slow_decay: i32 = 0,
    fast_decay: i32 = 0,
    slow_gain: i32 = 0,
    db_per_bit: i32 = 0,
    floor: i32 = 0,
    cpl_fast_leak: i32 = 0,
    cpl_slow_leak: i32 = 0,
};

/// Delta bit allocation: whether the stream moves the mask, and where.
pub const REUSE: u32 = 0;
pub const NEW: u32 = 1;
pub const NONE: u32 = 2;
pub const RESERVED: u32 = 3;

pub const Delta = struct {
    mode: u32 = NONE,
    segments: u32 = 0,
    offsets: [8]u8 = @splat(0),
    lengths: [8]u8 = @splat(0),
    values: [8]u8 = @splat(0),
};

/// The power of each bin from its exponent, `start` to `end`, and of each
/// band - the first 28 a bin each, the rest log-added.
pub fn psd(exps: *const [256]i8, start: usize, end: usize, power: *[256]i16, band_power: *[50]i16) void {
    for (start..end) |bin| power[bin] = 3072 - (@as(i16, exps[bin]) << 7);
    var bin = start;
    while (bin < @min(end, 28)) : (bin += 1) band_power[bin] = power[bin];
    if (bin >= end) return;
    var band: usize = tables.bin_to_band[bin];
    while (true) {
        var sum: i32 = power[bin];
        bin += 1;
        const band_end = @min(tables.band_start[band + 1], end);
        while (bin < band_end) : (bin += 1) {
            const p: i32 = power[bin];
            const most = @max(sum, p);
            const apart: usize = @intCast(@min(most - ((sum + p + 1) >> 1), 255));
            sum = most + tables.log_add[apart];
        }
        band_power[band] = @intCast(sum);
        band += 1;
        if (end <= tables.band_start[band]) break;
    }
}

/// The boost of the low bands, which mask less than the model's slopes
/// would say.
fn lowComp(a: i32, b0: i32, b1: i32, band: usize) i32 {
    if (band >= 20) return @max(a - 128, 0);
    if (b0 + 256 == b1) return if (band < 7) 384 else 320;
    if (b0 > b1) return @max(a - 64, 0);
    return a;
}

/// The masking curve of the bands `start` to `end` reach, moved by the
/// delta bit allocation; false when the delta runs past the bands.
pub fn mask(p: *const Params, band_power: *const [50]i16, start: usize, end: usize, fast_gain: i32, lfe: bool, delta: *const Delta, out: *[50]i16) bool {
    if (end == 0) return false;
    var excite: [50]i32 = undefined;
    const first: usize = tables.bin_to_band[start];
    const last: usize = @as(usize, tables.bin_to_band[end - 1]) + 1;
    const bp = band_power;
    var begin: usize = undefined;
    var fast: i32 = undefined;
    var slow: i32 = undefined;
    if (first == 0) {
        // The low bands, with their boost; the LFE's last band has none.
        var low: i32 = lowComp(0, bp[0], bp[1], 0);
        excite[0] = bp[0] - fast_gain - low;
        low = lowComp(low, bp[1], bp[2], 1);
        excite[1] = bp[1] - fast_gain - low;
        begin = 7;
        for (2..7) |band| {
            const last_of_lfe = lfe and band == 6;
            if (!last_of_lfe) low = lowComp(low, bp[band], bp[band + 1], band);
            fast = bp[band] - fast_gain;
            slow = bp[band] - p.slow_gain;
            excite[band] = fast - low;
            if (!last_of_lfe and bp[band] <= bp[band + 1]) {
                begin = band + 1;
                break;
            }
        }
        for (@min(begin, last, 22)..@min(last, 22)) |band| {
            if (!(lfe and band == 6)) low = lowComp(low, bp[band], bp[band + 1], band);
            fast = @max(fast - p.fast_decay, bp[band] - fast_gain);
            slow = @max(slow - p.slow_decay, bp[band] - p.slow_gain);
            excite[band] = @max(fast - low, slow);
        }
        // The LFE's few bands end here.
        begin = 22;
    } else {
        // The coupling channel: the leaks start where the stream says.
        begin = first;
        fast = (p.cpl_fast_leak << 8) + 768;
        slow = (p.cpl_slow_leak << 8) + 768;
    }
    for (@min(begin, last)..last) |band| {
        fast = @max(fast - p.fast_decay, bp[band] - fast_gain);
        slow = @max(slow - p.slow_decay, bp[band] - p.slow_gain);
        excite[band] = @max(fast, slow);
    }
    for (first..last) |band| {
        const below = p.db_per_bit - bp[band];
        if (below > 0) excite[band] += below >> 2;
        const hearing: i32 = tables.hearing[band >> @intCast(p.sr_shift)][p.sr_code];
        out[band] = @intCast(@max(hearing, excite[band]));
    }
    if (delta.mode == REUSE or delta.mode == NEW) {
        var band = first;
        for (0..delta.segments) |seg| {
            band += delta.offsets[seg];
            if (band >= 50 or delta.lengths[seg] > 50 - band) return false;
            const value: i32 = delta.values[seg];
            const step: i32 = if (value >= 4) (value - 3) * 128 else (value - 4) * 128;
            for (0..delta.lengths[seg]) |_| {
                out[band] +%= @intCast(step);
                band += 1;
            }
        }
    }
    return true;
}

/// Each bin's bap, `start` to `end`: its power over the band's mask,
/// less the offset, in steps of 6 dB, through `table`. An offset of
/// -960 - all the stream's offsets 0 - gives none at all.
pub fn bap(band_mask: *const [50]i16, power: *const [256]i16, start: usize, end: usize, snr_offset: i32, floor: i32, table: *const [64]u8, out: *[256]u8) void {
    if (snr_offset == -960) {
        @memset(out, 0);
        return;
    }
    var bin = start;
    while (bin < end) {
        const band: usize = tables.bin_to_band[bin];
        const band_end = @min(tables.band_start[band + 1], end);
        const m = (@max(band_mask[band] - snr_offset - floor, 0) & 0x1FE0) + floor;
        while (bin < band_end) : (bin += 1) {
            const address = @min(@max((power[bin] - m) >> 5, 0), 63);
            out[bin] = table[@intCast(address)];
        }
    }
}

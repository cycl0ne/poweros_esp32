// SPDX-License-Identifier: MIT
//! What E-AC-3 adds to AC-3's blocks (A/52 Annex E), as FFmpeg decodes
//! it.
//!
//! **The frame's data** (`frame`, E2.2.3) says up front what AC-3 says
//! block by block: which of the blocks' fields are there at all, in
//! which blocks coupling is used, the exponent strategies - each
//! channel's six by one code - the SNR offset for the whole frame, and
//! which channels are coded with AHT.
//!
//! **AHT** (`ahtMantissas`, E3.4) sends a bin's six mantissas, one a
//! block, all in the first block: a single index into a table of vectors
//! for a few bits, or six of a quantizer whose large values may take a
//! gain (GAQ) - and a DCT of six makes them the blocks' values.
//!
//! **Spectral extension** (`applySpx`, E3.6) codes no high bins at all:
//! the decoder copies lower ones up, band by band, and blends them with
//! noise as the stream's coordinates say - the noise from the dither's
//! generator, as FFmpeg draws it.
//!
//! Not decoded, as in FFmpeg: enhanced coupling (the block is refused),
//! reduced sample rates, substreams other than the first, dependent
//! frames - the channels past 5.1 they carry.

const std = @import("std");
const tables = @import("tables.zig");
const vq = @import("vq.zig").vq;
const header = @import("header.zig");
const frame_ = @import("frame.zig");
const Decoder = frame_.Decoder;
const Error = frame_.Error;
const CPL = frame_.CPL;
const max_channels = frame_.max_channels;
const Bits = @import("../aac/bits.zig").Bits;

pub const Spx = struct {
    in_use: bool,
    channel: [max_channels]bool,
    first_coords: [max_channels]bool,
    /// The bins copied from, `dst_start` up to `src_start`, and the
    /// extended ones, `src_start` up to `dst_end`.
    dst_start: usize,
    src_start: usize,
    dst_end: usize,
    bands: usize,
    band_sizes: [17]u8,
    band_struct: [17]u8,
    noise_blend: [max_channels][17]f32,
    signal_blend: [max_channels][17]f32,
    /// The notch at each band's edge: a code, or -1 for none.
    atten: [max_channels]i8,
};

/// The frame's data after the bit stream info.
pub fn frame(d: *Decoder, bits: *Bits) Error!void {
    const h = &d.h;
    if (h.sr_shift != 0) return error.Unsupported;
    const fbw = d.fbw;
    var ac3_strategies = true;
    var aht = false;
    if (h.blocks == 6) {
        ac3_strategies = bits.bit();
        aht = bits.bit();
    }
    d.snr_offset_strategy = bits.read(2);
    const transients = bits.bit();
    d.block_switch_syntax = bits.bit();
    if (!d.block_switch_syntax) d.block_switch = @splat(false);
    d.dither_flag_syntax = bits.bit();
    if (!d.dither_flag_syntax) {
        for (1..fbw + 1) |ch| d.dither[ch] = true;
    }
    d.dither[CPL] = false;
    d.dither[d.lfe_ch] = false;
    d.bit_allocation_syntax = bits.bit();
    if (!d.bit_allocation_syntax) {
        d.params.slow_decay = tables.slow_decay[2];
        d.params.fast_decay = tables.fast_decay[1];
        d.params.slow_gain = tables.slow_gain[1];
        d.params.db_per_bit = tables.db_per_bit[2];
        d.params.floor = tables.floors[7];
    }
    d.fast_gain_syntax = bits.bit();
    d.dba_syntax = bits.bit();
    d.skip_syntax = bits.bit();
    const spx_atten = bits.bit();

    var cpl_blocks: usize = 0;
    if (h.mode > 1) {
        for (0..h.blocks) |blk| {
            d.cpl_strategy_exists[blk] = blk == 0 or bits.bit();
            d.cpl_in_use[blk] = if (d.cpl_strategy_exists[blk]) bits.bit() else d.cpl_in_use[blk - 1];
            cpl_blocks += @intFromBool(d.cpl_in_use[blk]);
        }
    } else {
        d.cpl_in_use = @splat(false);
        d.cpl_strategy_exists = @splat(false);
    }

    if (ac3_strategies) {
        for (0..h.blocks) |blk| {
            const first: usize = if (d.cpl_in_use[blk]) CPL else 1;
            for (first..fbw + 1) |ch| d.exp_strategy[blk][ch] = @intCast(bits.read(2));
        }
    } else {
        const first: usize = if (h.mode > 1 and cpl_blocks != 0) CPL else 1;
        for (first..fbw + 1) |ch| {
            const code = bits.read(5);
            for (0..6) |blk| d.exp_strategy[blk][ch] = tables.frame_strategies[code][blk];
        }
    }
    if (h.lfe) {
        for (0..h.blocks) |blk| d.exp_strategy[blk][d.lfe_ch] = @intFromBool(bits.bit());
    }
    // The strategies of the AC-3 stream this one was converted from.
    if (h.kind == header.INDEPENDENT and (h.blocks == 6 or bits.bit())) bits.skip(5 * fbw);

    d.uses_aht = @splat(false);
    if (aht) {
        // AHT only where blocks 1 to 5 reuse block 0's exponents - and
        // the coupling channel's only where all six couple alike.
        const first: usize = if (cpl_blocks == 6) CPL else 1;
        for (first..d.channels + 1) |ch| {
            var reused = true;
            for (1..6) |blk| {
                if (d.exp_strategy[blk][ch] != frame_.REUSE or (ch == CPL and d.cpl_strategy_exists[blk])) {
                    reused = false;
                    break;
                }
            }
            d.uses_aht[ch] = reused and bits.bit();
        }
    }
    if (d.snr_offset_strategy == 0) {
        const coarse = (@as(i32, @intCast(bits.read(6))) - 15) * 16;
        const snr = (coarse + @as(i32, @intCast(bits.read(4)))) * 4;
        for (0..d.channels + 1) |ch| d.snr_offset[ch] = snr;
    }
    if (transients) {
        for (1..fbw + 1) |_| {
            if (bits.bit()) bits.skip(10 + 8);
        }
    }
    for (1..fbw + 1) |ch| {
        d.spx.atten[ch] = if (spx_atten and bits.bit()) @intCast(bits.read(5)) else -1;
    }
    // Where each block starts: a hint for decoders that skip blocks.
    if (h.blocks > 1 and bits.bit()) {
        bits.skip((h.blocks - 1) * (4 + std.math.log2_int(u32, h.size - 2)));
    }
    for (1..fbw + 1) |ch| {
        d.spx.first_coords[ch] = true;
        d.first_cpl_coords[ch] = true;
    }
    d.first_cpl_leak = true;
    if (bits.overrun()) return error.Corrupt;
}

/// Which channels are extended, from where to where (E2.3.3.3).
pub fn spxStrategy(d: *Decoder, bits: *Bits, blk: usize) Error!void {
    const spx = &d.spx;
    if (d.h.mode == 1) {
        spx.channel[1] = true;
    } else {
        for (1..d.fbw + 1) |ch| spx.channel[ch] = bits.bit();
    }
    const dst_code = bits.read(2);
    var start_band = bits.read(3) + 2;
    if (start_band > 7) start_band += start_band - 7;
    var end_band = bits.read(3) + 5;
    if (end_band > 7) end_band += end_band - 7;
    const dst_start = dst_code * 12 + 25;
    const src_start = start_band * 12 + 25;
    if (start_band >= end_band or dst_start >= src_start) return error.Corrupt;
    spx.dst_start = dst_start;
    spx.src_start = src_start;
    spx.dst_end = end_band * 12 + 25;
    frame_.bandStructure(bits, blk, true, start_band, end_band, &tables.default_spx_bands, &spx.bands, &spx.band_sizes, &spx.band_struct);
}

/// Each extended channel's blending of signal and noise in each band,
/// when sent (E3.6.4).
pub fn spxCoordinates(d: *Decoder, bits: *Bits) void {
    const spx = &d.spx;
    for (1..d.fbw + 1) |ch| {
        if (!spx.channel[ch]) {
            spx.first_coords[ch] = true;
            continue;
        }
        if (!spx.first_coords[ch] and !bits.bit()) continue;
        spx.first_coords[ch] = false;
        const blend = @as(f32, @floatFromInt(bits.read(5))) * (1.0 / 32.0);
        const master = bits.read(2) * 3;
        var bin = spx.src_start;
        for (0..spx.bands) |band| {
            const size: usize = spx.band_sizes[band];
            const end: f32 = @floatFromInt(spx.dst_end);
            var ratio = @as(f32, @floatFromInt(bin + (size >> 1))) / end - blend;
            ratio = @max(0.0, @min(ratio, 1.0));
            // Noise of unit variance: sqrt(3) a uniform's.
            const noise = @sqrt(3.0 * ratio);
            const signal = @sqrt(1.0 - ratio);
            bin += size;
            const exp = bits.read(4);
            var mant = bits.read(2);
            if (exp == 15) mant <<= 1 else mant += 4;
            mant <<= @intCast(25 - exp - master);
            const coord = @as(f32, @floatFromInt(mant)) * (1.0 / 8388608.0);
            spx.noise_blend[ch][band] = noise * coord;
            spx.signal_blend[ch][band] = signal * coord;
        }
    }
}

/// The extended bins: lower ones copied up - wrapping round to the copy
/// region's start when they run out - their notch at each band edge, and
/// each band's copy scaled and blended with noise of its power.
pub fn applySpx(d: *Decoder) void {
    const spx = &d.spx;
    var wrap: [17]bool = @splat(false);
    wrap[0] = true;
    var copies: [18]usize = undefined;
    var copy_count: usize = 0;
    var bin = spx.dst_start;
    for (0..spx.bands) |band| {
        const size: usize = spx.band_sizes[band];
        if (bin + size > spx.src_start) {
            copies[copy_count] = bin - spx.dst_start;
            copy_count += 1;
            bin = spx.dst_start;
            wrap[band] = true;
        }
        var i: usize = 0;
        while (i < size) {
            if (bin == spx.src_start) {
                copies[copy_count] = bin - spx.dst_start;
                copy_count += 1;
                bin = spx.dst_start;
            }
            const step = @min(size - i, spx.src_start - bin);
            bin += step;
            i += step;
        }
    }
    copies[copy_count] = bin - spx.dst_start;
    copy_count += 1;

    for (1..d.fbw + 1) |ch| {
        if (!spx.channel[ch]) continue;
        const c = &d.coeffs[ch];
        bin = spx.src_start;
        for (copies[0..copy_count]) |size| {
            for (0..size) |i| c[bin + i] = c[spx.dst_start + i];
            bin += size;
        }
        var energy: [17]f32 = undefined;
        bin = spx.src_start;
        for (0..spx.bands) |band| {
            const size: usize = spx.band_sizes[band];
            var sum: f32 = 0;
            for (0..size) |_| {
                sum += c[bin] * c[bin];
                bin += 1;
            }
            energy[band] = @sqrt(sum / @as(f32, @floatFromInt(size)));
        }
        if (spx.atten[ch] >= 0) {
            const code: f64 = @floatFromInt(spx.atten[ch]);
            var notch: [3]f32 = undefined;
            for (0..3) |i| notch[i] = @floatCast(std.math.exp2(-(@as(f64, @floatFromInt(i + 1)) * (code + 1.0)) / 15.0));
            bin = spx.src_start - 2;
            for (0..spx.bands) |band| {
                if (wrap[band]) {
                    c[bin] *= notch[0];
                    c[bin + 1] *= notch[1];
                    c[bin + 2] *= notch[2];
                    c[bin + 3] *= notch[1];
                    c[bin + 4] *= notch[0];
                }
                bin += spx.band_sizes[band];
            }
        }
        bin = spx.src_start;
        for (0..spx.bands) |band| {
            // The generator's word as a signed fraction, times -1.
            const noise_scale = spx.noise_blend[ch][band] * energy[band] * (1.0 / -2147483648.0);
            const signal_scale = spx.signal_blend[ch][band];
            for (0..spx.band_sizes[band]) |_| {
                const word: i32 = @bitCast(d.noise.next());
                c[bin] *= signal_scale;
                c[bin] += noise_scale * @as(f32, @floatFromInt(word));
                bin += 1;
            }
        }
    }
}

/// An AHT channel's six blocks of mantissas, each bin's in the 24-bit
/// fractions the others use (E3.4).
pub fn ahtMantissas(d: *Decoder, bits: *Bits, ch: usize) void {
    const start = d.start[ch];
    const end = d.end[ch];
    const baps = &d.bap[ch];
    const gaq_mode = bits.read(2);
    const end_bap: u8 = if (gaq_mode < 2) 12 else 17;
    // The gains of the bins GAQ may scale: 0 none, 1 two, 2 four.
    var gains: [256]u8 = undefined;
    var count: usize = 0;
    if (gaq_mode == 1 or gaq_mode == 2) {
        for (start..end) |bin| {
            if (baps[bin] > 7 and baps[bin] < end_bap) {
                gains[count] = @intCast(bits.read(1) << @intCast(gaq_mode - 1));
                count += 1;
            }
        }
    } else if (gaq_mode == 3) {
        // Three gains of 0 to 2 in 5 bits.
        var left: u32 = 0;
        for (start..end) |bin| {
            if (baps[bin] > 7 and baps[bin] < 17) {
                if (left == 0) {
                    const word = @min(bits.read(5), 26);
                    gains[count] = @intCast(word / 9);
                    gains[count + 1] = @intCast(word % 9 / 3);
                    gains[count + 2] = @intCast(word % 3);
                    count += 3;
                    left = 3;
                }
                left -= 1;
            }
        }
    }
    count = 0;
    for (start..end) |bin| {
        const hebap = baps[bin];
        const size: u5 = @intCast(tables.hebap_bits[hebap]);
        const pre = &d.pre_mantissa[ch][bin];
        if (hebap == 0) {
            for (pre) |*m| m.* = @as(i32, @intCast(d.noise.next() & 0x7FFFFF)) - 0x400000;
        } else if (hebap < 8) {
            const vector = &vq[hebap][bits.read(size)];
            for (pre, vector) |*m, v| m.* = @as(i32, v) * 256;
        } else {
            var gain: u5 = 0;
            if (gaq_mode != 0 and hebap < end_bap) {
                gain = @intCast(gains[count]);
                count += 1;
            }
            const gbits = size - gain;
            for (pre) |*m| {
                var mant = signed(bits, gbits);
                if (gain != 0 and mant == -(@as(i32, 1) << (gbits - 1))) {
                    // A large mantissa, in bits the gain left out.
                    const mbits = size - (2 - gain);
                    mant = signed(bits, mbits);
                    mant = @bitCast(@as(u32, @bitCast(mant)) << @intCast(24 - @as(u6, mbits)));
                    const row = hebap - 8;
                    const offset: i32 = if (mant >= 0) @as(i32, 1) << (23 - gain) else @as(i32, tables.gaq_remap_b[row][gain - 1]) * 256;
                    mant += @as(i32, @intCast((@as(i64, tables.gaq_remap_a[row][gain - 1]) * mant) >> 15)) + offset;
                } else {
                    mant *= @as(i32, 1) << (24 - size);
                    if (gain == 0) mant += @intCast((@as(i64, tables.gaq_remap_1[hebap - 8]) * mant) >> 15);
                }
                m.* = mant;
            }
        }
        idct6(pre);
    }
}

/// The next `count` bits as a two's complement number.
fn signed(bits: *Bits, count: u5) i32 {
    const raw = bits.read(count);
    const shift: u5 = @intCast(32 - @as(u6, count));
    return @as(i32, @bitCast(raw << shift)) >> shift;
}

/// A DCT of six in 24-bit fixed point: the bin's values in the six
/// blocks from what AHT sent (E3.4.5).
fn idct6(m: *[6]i32) void {
    const c0: i64 = 10273905; // sqrt(2) cos(pi/6) 2^23
    const c1: i64 = 11863283; // sqrt(2) 2^23
    const c2: i64 = 3070444; // sqrt(2) cos(5 pi/12) 2^23
    const odd1 = m[1] - m[3] - m[5];
    var even2: i32 = @intCast((m[2] * c0) >> 23);
    var t: i32 = @intCast((m[4] * c1) >> 23);
    var odd0: i32 = @intCast(((m[1] + m[5]) * c2) >> 23);
    var even0 = m[0] + (t >> 1);
    const even1 = m[0] - t;
    t = even0;
    even0 = t + even2;
    even2 = t - even2;
    t = odd0;
    odd0 = t + m[1] + m[3];
    const odd2 = t + m[5] - m[3];
    m.* = .{ even0 + odd0, even1 + odd1, even2 + odd2, even2 - odd2, even1 - odd1, even0 - odd0 };
}

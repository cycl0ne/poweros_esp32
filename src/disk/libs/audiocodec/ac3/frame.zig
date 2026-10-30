// SPDX-License-Identifier: MIT
//! A syncframe's audio blocks decoded into transform coefficients: AC-3
//! (A/52 5.4.3, 7.1 to 7.7) and the parts E-AC-3 shares with it, its own
//! in `eac3.zig`.
//!
//! **A block** says, channel by channel, what changed since the block
//! before: block switching, dither, dynamic range, coupling, rematrixing,
//! the exponents and the bit allocation's parameters. The exponents and
//! the parameters give each mantissa its bits (`allocation.zig`), and the
//! mantissas follow: three of a small quantizer packed in one word, a
//! bin of no bits filled with noise where the channel asks for dither.
//! Coupled channels share one channel's mantissas above the coupling
//! frequency, each scaled by its own coordinates; a stereo pair may be
//! sent as sum and difference in up to four bands (rematrixing). The
//! coefficients are then scaled by the dynamic range word.
//!
//! **As FFmpeg does**, so a stream decodes to its samples: the dither is
//! its generator, seeded as it seeds it, drawn in the same order; dynamic
//! range is applied as sent, heavy compression and dialogue level are
//! not; a coupled channel without dither has the coupling channel's
//! noise taken out again; delta bit allocation counts its bands from the
//! channel's first.
//!
//! Channel 0 is the coupling channel, 1 to 5 the full-bandwidth ones in
//! the stream's order (L C R Ls Rs for 3/2), the LFE after them.

const std = @import("std");
const tables = @import("tables.zig");
const header = @import("header.zig");
const allocation = @import("allocation.zig");
const eac3 = @import("eac3.zig");
const Bits = @import("../aac/bits.zig").Bits;

pub const Error = error{ Corrupt, Unsupported };

pub const CPL = 0;
pub const max_channels = 7;

/// Exponent strategies: reuse the block before's, or new ones a step of
/// one, two or four bins each.
pub const REUSE: u8 = 0;
pub const D15: u8 = 1;
pub const D25: u8 = 2;
pub const D45: u8 = 3;

/// 2^-e for each exponent.
const powers = blk: {
    var table: [25]f32 = undefined;
    for (0..25) |e| table[e] = 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << e));
    break :blk table;
};

/// FFmpeg's lagged Fibonacci generator: x[n] = x[n-24] + x[n-55], its
/// state seeded from MD5 sums of the seed.
pub const Dither = struct {
    state: [64]u32 = @splat(0),
    index: u32 = 0,

    pub fn seed(d: *Dither) void {
        var sum: [16]u8 = @splat(0);
        d.state = @splat(0);
        var i: usize = 8;
        while (i < 64) : (i += 4) {
            std.mem.writeInt(u32, sum[0..4], 0, .little);
            sum[4] = @intCast(i);
            std.crypto.hash.Md5.hash(&sum, &sum, .{});
            for (0..4) |n| d.state[i + n] = std.mem.readInt(u32, sum[n * 4 ..][0..4], .little);
        }
        d.index = 0;
    }

    pub fn next(d: *Dither) u32 {
        const value = d.state[(d.index -% 24) & 63] +% d.state[(d.index -% 55) & 63];
        d.state[d.index & 63] = value;
        d.index +%= 1;
        return value;
    }
};

pub const Decoder = struct {
    h: header.Header,
    /// The full-bandwidth channels, all of them with the LFE, and the
    /// LFE's number - past the others where there is none.
    fbw: usize,
    channels: usize,
    lfe_ch: usize,

    /// What the frame's blocks may say: E-AC-3 leaves some out.
    snr_offset_strategy: u32,
    block_switch_syntax: bool,
    dither_flag_syntax: bool,
    bit_allocation_syntax: bool,
    fast_gain_syntax: bool,
    dba_syntax: bool,
    skip_syntax: bool,
    first_cpl_leak: bool,

    block_switch: [max_channels]bool,
    dither: [max_channels]bool,
    /// The dynamic range gain of the program, two in dual mono.
    dynamic_range: [2]f32,

    /// Coupling: in which blocks, which channels, over which bands -
    /// sub-bands of 12 bins joined - and each channel's coordinates.
    cpl_in_use: [6]bool,
    cpl_strategy_exists: [6]bool,
    channel_in_cpl: [max_channels]bool,
    first_cpl_coords: [max_channels]bool,
    phase_flags_in_use: bool,
    phase_flags: [18]bool,
    cpl_bands: usize,
    cpl_band_sizes: [18]u8,
    cpl_band_struct: [18]u8,
    cpl_coords: [max_channels][18]i32,

    /// E-AC-3's spectral extension (`eac3.zig`).
    spx: eac3.Spx,

    rematrix_bands: usize,
    rematrix: [4]bool,

    exp_strategy: [6][max_channels]u8,
    start: [max_channels]usize,
    end: [max_channels]usize,
    exp_groups: [max_channels]usize,
    exps: [max_channels][256]i8,

    params: allocation.Params,
    snr_offset: [max_channels]i32,
    fast_gain: [max_channels]i32,
    delta: [max_channels]allocation.Delta,
    psd: [max_channels][256]i16,
    band_psd: [max_channels][50]i16,
    mask: [max_channels][50]i16,
    bap: [max_channels][256]u8,

    /// E-AC-3's AHT: which channels, and all six blocks' mantissas of
    /// each bin, sent in the first.
    uses_aht: [max_channels]bool,
    pre_mantissa: [max_channels][256][6]i32,

    /// The block's coefficients, scaled; the generator of the noise.
    coeffs: [max_channels][256]f32,
    noise: Dither,
};

/// A frame begun: its header taken in, and E-AC-3's frame data read
/// (`bits` at it).
pub fn begin(d: *Decoder, h: header.Header, bits: *Bits) Error!void {
    d.h = h;
    d.fbw = tables.mode_channels[h.mode];
    d.channels = d.fbw + @intFromBool(h.lfe);
    d.lfe_ch = d.fbw + 1;
    d.params.sr_code = h.sr_code;
    d.params.sr_shift = h.sr_shift;
    if (h.lfe) {
        d.start[d.lfe_ch] = 0;
        d.end[d.lfe_ch] = 7;
        d.exp_groups[d.lfe_ch] = 2;
        d.channel_in_cpl[d.lfe_ch] = false;
    }
    if (h.eac3) return eac3.frame(d, bits);
    d.snr_offset_strategy = 2;
    d.block_switch_syntax = true;
    d.dither_flag_syntax = true;
    d.bit_allocation_syntax = true;
    d.fast_gain_syntax = false;
    d.first_cpl_leak = false;
    d.dba_syntax = true;
    d.skip_syntax = true;
    d.uses_aht = @splat(false);
}

/// The next audio block: its coefficients, scaled, in `coeffs`, and
/// which channels switched to short blocks in `block_switch`.
pub fn block(d: *Decoder, bits: *Bits, blk: usize) Error!void {
    const fbw = d.fbw;
    const mode = d.h.mode;

    if (d.block_switch_syntax) {
        for (1..fbw + 1) |ch| d.block_switch[ch] = bits.bit();
    }
    if (d.dither_flag_syntax) {
        for (1..fbw + 1) |ch| d.dither[ch] = bits.bit();
    }
    // Dual mono's first word is the first channel's, kept second.
    var program: usize = if (mode == 0) 2 else 1;
    while (program > 0) {
        program -= 1;
        if (bits.bit()) {
            d.dynamic_range[program] = rangeGain(bits.read(8));
        } else if (blk == 0) d.dynamic_range[program] = 1.0;
    }

    if (d.h.eac3 and (blk == 0 or bits.bit())) {
        d.spx.in_use = bits.bit();
        if (d.spx.in_use) try eac3.spxStrategy(d, bits, blk);
    }
    if (!d.h.eac3 or !d.spx.in_use) {
        d.spx.in_use = false;
        for (1..fbw + 1) |ch| {
            d.spx.channel[ch] = false;
            d.spx.first_coords[ch] = true;
        }
    }
    if (d.spx.in_use) eac3.spxCoordinates(d, bits);

    if (if (d.h.eac3) d.cpl_strategy_exists[blk] else bits.bit()) {
        try couplingStrategy(d, bits, blk);
    } else if (!d.h.eac3) {
        if (blk == 0) return error.Corrupt;
        d.cpl_in_use[blk] = d.cpl_in_use[blk - 1];
    }
    const cpl_in_use = d.cpl_in_use[blk];
    if (cpl_in_use) try couplingCoordinates(d, bits, blk);

    if (mode == 2) {
        if ((d.h.eac3 and blk == 0) or bits.bit()) {
            d.rematrix_bands = 4;
            if (cpl_in_use and d.start[CPL] <= 61) {
                d.rematrix_bands -= 1 + @as(usize, @intFromBool(d.start[CPL] == 37));
            } else if (d.spx.in_use and d.spx.src_start <= 61) {
                d.rematrix_bands -= 1;
            }
            for (0..d.rematrix_bands) |band| d.rematrix[band] = bits.bit();
        } else if (blk == 0) d.rematrix_bands = 0;
    }

    const first: usize = if (cpl_in_use) CPL else 1;
    const strategy = &d.exp_strategy[blk];
    if (!d.h.eac3) {
        for (first..d.channels + 1) |ch| strategy[ch] = @intCast(bits.read(if (ch == d.lfe_ch) 1 else 2));
    }
    for (1..fbw + 1) |ch| {
        d.start[ch] = 0;
        if (strategy[ch] == REUSE) continue;
        if (d.channel_in_cpl[ch]) {
            d.end[ch] = d.start[CPL];
        } else if (d.spx.channel[ch]) {
            d.end[ch] = d.spx.src_start;
        } else {
            const code = bits.read(6);
            if (code > 60) return error.Corrupt;
            d.end[ch] = code * 3 + 73;
        }
        const group = @as(usize, 3) << @intCast(strategy[ch] - 1);
        d.exp_groups[ch] = (d.end[ch] + group - 4) / group;
    }
    if (cpl_in_use and strategy[CPL] != REUSE) {
        d.exp_groups[CPL] = (d.end[CPL] - d.start[CPL]) / (@as(usize, 3) << @intCast(strategy[CPL] - 1));
    }
    for (first..d.channels + 1) |ch| {
        if (strategy[ch] == REUSE) continue;
        const absolute: u8 = @intCast(bits.read(4) << @intFromBool(ch == CPL));
        d.exps[ch][0] = @intCast(absolute);
        const from = d.start[ch] + @intFromBool(ch != CPL);
        try exponents(bits, strategy[ch], d.exp_groups[ch], absolute, d.exps[ch][from..]);
        if (ch != CPL and ch != d.lfe_ch) bits.skip(2); // gainrng
    }

    if (d.bit_allocation_syntax) {
        if (bits.bit()) {
            const shift: u5 = @intCast(d.params.sr_shift);
            d.params.slow_decay = @as(i32, tables.slow_decay[bits.read(2)]) >> shift;
            d.params.fast_decay = @as(i32, tables.fast_decay[bits.read(2)]) >> shift;
            d.params.slow_gain = tables.slow_gain[bits.read(2)];
            d.params.db_per_bit = tables.db_per_bit[bits.read(2)];
            d.params.floor = tables.floors[bits.read(3)];
        } else if (blk == 0) return error.Corrupt;
    }
    if (!d.h.eac3 or blk == 0) {
        if (d.snr_offset_strategy != 0 and bits.bit()) {
            const coarse = (@as(i32, @intCast(bits.read(6))) - 15) * 16;
            var snr: i32 = 0;
            for (first..d.channels + 1) |ch| {
                if (ch == first or d.snr_offset_strategy == 2) snr = (coarse + @as(i32, @intCast(bits.read(4)))) * 4;
                d.snr_offset[ch] = snr;
                if (!d.h.eac3) d.fast_gain[ch] = tables.fast_gain[bits.read(3)];
            }
        } else if (!d.h.eac3 and blk == 0) return error.Corrupt;
    }
    if (d.fast_gain_syntax and bits.bit()) {
        for (first..d.channels + 1) |ch| d.fast_gain[ch] = tables.fast_gain[bits.read(3)];
    } else if (d.h.eac3 and blk == 0) {
        for (first..d.channels + 1) |ch| d.fast_gain[ch] = tables.fast_gain[4];
    }
    // An E-AC-3 frame converted from AC-3: the AC-3 frame's offset.
    if (d.h.kind == header.INDEPENDENT and bits.bit()) bits.skip(10);
    if (cpl_in_use) {
        if (d.first_cpl_leak or bits.bit()) {
            d.params.cpl_fast_leak = @intCast(bits.read(3));
            d.params.cpl_slow_leak = @intCast(bits.read(3));
        } else if (!d.h.eac3 and blk == 0) return error.Corrupt;
        d.first_cpl_leak = false;
    }
    if (d.dba_syntax and bits.bit()) {
        for (first..fbw + 1) |ch| {
            d.delta[ch].mode = bits.read(2);
            if (d.delta[ch].mode == allocation.RESERVED) return error.Corrupt;
        }
        for (first..fbw + 1) |ch| {
            const delta = &d.delta[ch];
            if (delta.mode != allocation.NEW) continue;
            delta.segments = bits.read(3) + 1;
            for (0..delta.segments) |seg| {
                delta.offsets[seg] = @intCast(bits.read(5));
                delta.lengths[seg] = @intCast(bits.read(4));
                delta.values[seg] = @intCast(bits.read(3));
            }
        }
    } else if (blk == 0) {
        for (0..d.channels + 1) |ch| d.delta[ch].mode = allocation.NONE;
    }

    for (first..d.channels + 1) |ch| {
        allocation.psd(&d.exps[ch], d.start[ch], d.end[ch], &d.psd[ch], &d.band_psd[ch]);
        if (!allocation.mask(&d.params, &d.band_psd[ch], d.start[ch], d.end[ch], d.fast_gain[ch], ch == d.lfe_ch, &d.delta[ch], &d.mask[ch])) return error.Corrupt;
        const table = if (d.uses_aht[ch]) &tables.hebap else &tables.bap;
        allocation.bap(&d.mask[ch], &d.psd[ch], d.start[ch], d.end[ch], d.snr_offset[ch], d.params.floor, table, &d.bap[ch]);
    }

    if (d.skip_syntax and bits.bit()) bits.skip(bits.read(9) * 8);
    if (bits.overrun()) return error.Corrupt;

    try coefficients(d, bits, blk);
    if (bits.overrun()) return error.Corrupt;
    if (mode == 2) rematrix(d);

    for (1..d.channels + 1) |ch| {
        const which: usize = if (mode == 0 and ch <= 2) 2 - ch else 0;
        const gain = d.dynamic_range[which] * (1.0 / 4194304.0);
        for (&d.coeffs[ch]) |*c| c.* *= gain;
    }
    if (d.spx.in_use) eac3.applySpx(d);
}

/// A dynamic range word as a gain: 2^X (1 + Y/32) of its signed three
/// top bits X and its five low ones Y (7.7.1.2).
fn rangeGain(code: u32) f32 {
    const top: i32 = @as(i32, @intCast(code >> 5)) - @as(i32, @intCast((code >> 7) << 3));
    return std.math.ldexp(@as(f32, @floatFromInt((code & 0x1F) | 0x20)), top - 5);
}

/// Grouped exponents, a 7-bit word for three steps of -2 to +2, from
/// `absolute`, each step `strategy`'s bins wide (7.1.3).
fn exponents(bits: *Bits, strategy: u8, groups: usize, absolute: u8, out: []i8) Error!void {
    const size: usize = if (strategy == D45) 4 else strategy;
    var exp: i32 = absolute;
    var at: usize = 0;
    for (0..groups) |_| {
        const word = bits.read(7);
        if (word >= 125) return error.Corrupt;
        const steps = [3]u32{ word / 25, word % 25 / 5, word % 5 };
        for (steps) |step| {
            exp += @as(i32, @intCast(step)) - 2;
            if (exp < 0 or exp > 24) return error.Corrupt;
            @memset(out[at..][0..size], @intCast(exp));
            at += size;
        }
    }
}

/// Which channels are coupled and over which bins.
fn couplingStrategy(d: *Decoder, bits: *Bits, blk: usize) Error!void {
    const fbw = d.fbw;
    if (!d.h.eac3) d.cpl_in_use[blk] = bits.bit();
    if (!d.cpl_in_use[blk]) {
        for (1..fbw + 1) |ch| {
            d.channel_in_cpl[ch] = false;
            d.first_cpl_coords[ch] = true;
        }
        d.first_cpl_leak = d.h.eac3;
        d.phase_flags_in_use = false;
        return;
    }
    if (d.h.mode < 2) return error.Corrupt;
    // Enhanced coupling, as in FFmpeg, is not decoded.
    if (d.h.eac3 and bits.bit()) return error.Unsupported;
    if (d.h.eac3 and d.h.mode == 2) {
        d.channel_in_cpl[1] = true;
        d.channel_in_cpl[2] = true;
    } else {
        for (1..fbw + 1) |ch| d.channel_in_cpl[ch] = bits.bit();
    }
    if (d.h.mode == 2) d.phase_flags_in_use = bits.bit();
    const begin_band = bits.read(4);
    const end_band: u32 = if (d.spx.in_use) @intCast((d.spx.src_start - 37) / 12) else bits.read(4) + 3;
    if (begin_band >= end_band) return error.Corrupt;
    d.start[CPL] = begin_band * 12 + 37;
    d.end[CPL] = end_band * 12 + 37;
    bandStructure(bits, blk, d.h.eac3, begin_band, end_band, &tables.default_cpl_bands, &d.cpl_bands, &d.cpl_band_sizes, &d.cpl_band_struct);
}

/// The bands of coupling or of spectral extension: sub-bands of 12 bins
/// from `first` to `last`, each joined to the one before or not - as the
/// stream says, or E-AC-3's default from block 0 on.
pub fn bandStructure(bits: *Bits, blk: usize, is_eac3: bool, first: u32, last: u32, default: []const u8, count: *usize, sizes: []u8, structure: []u8) void {
    const subbands: usize = last - first;
    if (blk == 0) @memcpy(structure[0..default.len], default);
    const joined = structure[first + 1 ..];
    if (!is_eac3 or bits.bit()) {
        for (0..subbands - 1) |sub| joined[sub] = @intFromBool(bits.bit());
    }
    var bands = subbands;
    var band: usize = 0;
    sizes[0] = 12;
    for (1..subbands) |sub| {
        if (joined[sub - 1] != 0) {
            bands -= 1;
            sizes[band] += 12;
        } else {
            band += 1;
            sizes[band] = 12;
        }
    }
    count.* = bands;
}

/// Each coupled channel's coordinates in each band, when sent: a 4-bit
/// exponent and mantissa under a master exponent (7.4.3).
fn couplingCoordinates(d: *Decoder, bits: *Bits, blk: usize) Error!void {
    var sent = false;
    for (1..d.fbw + 1) |ch| {
        if (!d.channel_in_cpl[ch]) {
            d.first_cpl_coords[ch] = true;
            continue;
        }
        if ((d.h.eac3 and d.first_cpl_coords[ch]) or bits.bit()) {
            d.first_cpl_coords[ch] = false;
            sent = true;
            const master = 3 * bits.read(2);
            for (0..d.cpl_bands) |band| {
                const exp = bits.read(4);
                const mant: i32 = @intCast(bits.read(4));
                const coord: i32 = if (exp == 15) mant << 22 else (mant + 16) << 21;
                d.cpl_coords[ch][band] = coord >> @intCast(exp + master);
            }
        } else if (blk == 0) return error.Corrupt;
    }
    if (d.h.mode == 2 and sent) {
        for (0..d.cpl_bands) |band| d.phase_flags[band] = d.phase_flags_in_use and bits.bit();
    }
}

/// Mantissas of bap 1, 2 and 4 come three, three and two to a word,
/// shared across the channels of a block: the ones still to hand out.
const Groups = struct {
    b1: [2]i32 = .{ 0, 0 },
    b2: [2]i32 = .{ 0, 0 },
    b4: i32 = 0,
    n1: u32 = 0,
    n2: u32 = 0,
    n4: u32 = 0,
};

/// The block's mantissas, channel by channel - the coupling channel's
/// after the first coupled one's - made coefficients, the coupled
/// channels' worked out from it.
fn coefficients(d: *Decoder, bits: *Bits, blk: usize) Error!void {
    var groups: Groups = .{};
    var got_cpl = false;
    for (1..d.channels + 1) |ch| {
        try channelCoefficients(d, bits, blk, ch, &groups);
        var end: usize = d.end[ch];
        if (d.channel_in_cpl[ch]) {
            if (!got_cpl) {
                try channelCoefficients(d, bits, blk, CPL, &groups);
                uncouple(d);
                got_cpl = true;
            }
            end = d.end[CPL];
        }
        @memset(d.coeffs[ch][end..], 0);
    }
    // A coupled channel without dither: no noise from the coupling
    // channel's bins of no bits.
    for (1..d.fbw + 1) |ch| {
        if (d.dither[ch] or !d.channel_in_cpl[ch]) continue;
        for (d.start[CPL]..d.end[CPL]) |bin| {
            if (d.bap[CPL][bin] == 0) d.coeffs[ch][bin] = 0;
        }
    }
}

fn channelCoefficients(d: *Decoder, bits: *Bits, blk: usize, ch: usize, groups: *Groups) Error!void {
    const out = &d.coeffs[ch];
    const exps = &d.exps[ch];
    if (d.uses_aht[ch]) {
        // All six blocks' mantissas come with the first.
        if (blk == 0) eac3.ahtMantissas(d, bits, ch);
        for (d.start[ch]..d.end[ch]) |bin| {
            out[bin] = @as(f32, @floatFromInt(d.pre_mantissa[ch][bin][blk])) * powers[@intCast(exps[bin])];
        }
        return;
    }
    const baps = &d.bap[ch];
    const dither = ch == CPL or d.dither[ch];
    for (d.start[ch]..d.end[ch]) |bin| {
        const mantissa: i32 = switch (baps[bin]) {
            // Noise of about -0.707 to 0.707.
            0 => if (dither) @as(i32, @intCast(((d.noise.next() >> 8) * 181) >> 8)) - 5931008 else 0,
            1 => blk: {
                if (groups.n1 != 0) {
                    groups.n1 -= 1;
                    break :blk groups.b1[groups.n1];
                }
                const word = tables.bap1[bits.read(5)];
                groups.b1 = .{ word[2], word[1] };
                groups.n1 = 2;
                break :blk word[0];
            },
            2 => blk: {
                if (groups.n2 != 0) {
                    groups.n2 -= 1;
                    break :blk groups.b2[groups.n2];
                }
                const word = tables.bap2[bits.read(7)];
                groups.b2 = .{ word[2], word[1] };
                groups.n2 = 2;
                break :blk word[0];
            },
            3 => tables.bap3[bits.read(3)],
            4 => blk: {
                if (groups.n4 != 0) {
                    groups.n4 = 0;
                    break :blk groups.b4;
                }
                const word = tables.bap4[bits.read(7)];
                groups.b4 = word[1];
                groups.n4 = 1;
                break :blk word[0];
            },
            5 => tables.bap5[bits.read(4)],
            else => |bap| blk: {
                // A two's complement fraction, its point after the sign.
                const count: u5 = @intCast(tables.mantissa_bits[@min(bap, 15)]);
                const raw = bits.read(count);
                break :blk @as(i32, @bitCast(raw << @intCast(32 - @as(u6, count)))) >> 8;
            },
        };
        out[bin] = @as(f32, @floatFromInt(mantissa)) * powers[@intCast(exps[bin])];
    }
}

/// The coupled channels' coefficients: the coupling channel's in each
/// band times the channel's coordinate, the right one's turned over
/// where the phase flag says.
fn uncouple(d: *Decoder) void {
    var bin = d.start[CPL];
    for (0..d.cpl_bands) |band| {
        const band_start = bin;
        const band_end = bin + d.cpl_band_sizes[band];
        for (1..d.fbw + 1) |ch| {
            if (!d.channel_in_cpl[ch]) continue;
            const coord = @as(f32, @floatFromInt(d.cpl_coords[ch][band])) * (1.0 / 8388608.0);
            for (band_start..band_end) |i| d.coeffs[ch][i] = d.coeffs[CPL][i] * coord;
            if (ch == 2 and d.phase_flags[band]) {
                for (band_start..band_end) |i| d.coeffs[2][i] = -d.coeffs[2][i];
            }
        }
        bin = band_end;
    }
}

/// Sum and difference made left and right again (7.5.4).
fn rematrix(d: *Decoder) void {
    const end = @min(d.end[1], d.end[2]);
    for (0..d.rematrix_bands) |band| {
        if (!d.rematrix[band]) continue;
        const band_end = @min(end, tables.rematrix_bands[band + 1]);
        for (tables.rematrix_bands[band]..band_end) |i| {
            const left = d.coeffs[1][i];
            d.coeffs[1][i] += d.coeffs[2][i];
            d.coeffs[2][i] = left - d.coeffs[2][i];
        }
    }
}

test "the generator gives FFmpeg's numbers" {
    var noise: Dither = .{};
    noise.seed();
    // av_lfg_get after av_lfg_init(0): the first four, and the 1001st.
    for ([_]u32{ 0xe6c5ddb1, 0x8db66502, 0xc1af2a4c, 0x4141c2ee }) |value| try std.testing.expectEqual(value, noise.next());
    for (4..1000) |_| _ = noise.next();
    try std.testing.expectEqual(@as(u32, 0x388f55e9), noise.next());
}

test "a dynamic range word is 2^X (1 + Y/32)" {
    try std.testing.expectEqual(@as(f32, 1.0), rangeGain(0));
    try std.testing.expectEqual(@as(f32, 2.0), rangeGain(0x20));
    try std.testing.expectEqual(@as(f32, 0.0625 * 63.0 / 32.0), rangeGain(0x9F));
}

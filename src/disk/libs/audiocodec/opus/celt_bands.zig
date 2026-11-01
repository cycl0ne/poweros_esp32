// SPDX-License-Identifier: MIT
//! A CELT frame's band shapes (RFC 6716 4.3.4): each band's bits split
//! further where it is large - two halves and the angle between their
//! energies (theta), recursively, and in stereo mid and side the same way
//! - down to pieces whose pulses are decoded (celt_pvq.zig). A band with
//! no pulses is filled by folding a lower band's shape into it, or noise.
//! Then the shapes are scaled by the band energies into the spectrum the
//! MDCT takes.
//!
//! **Time and frequency**: a transient frame holds short blocks, their
//! coefficients interleaved; a band can trade time resolution for
//! frequency resolution (`tf_change`) with Haar steps across them, and
//! the coefficients are reordered by block before the split and back
//! after.
//!
//! **Anti-collapse**: in a transient frame a short block left with no
//! pulse at all is filled with noise at a level the energies before allow.

const tables = @import("celt_tables.zig");
const Range = @import("range.zig").Range;
const alloc = @import("celt_alloc.zig");
const pvq = @import("celt_pvq.zig");

const bitres = alloc.bitres;

pub fn lcgRand(seed: u32) u32 {
    return 1664525 *% seed +% 1013904223;
}

/// (a * b) in Q15, both taken as 16 bits, rounded: bit-exact everywhere.
inline fn fracMul16(a: i32, b: i32) i32 {
    const x: i32 = @as(i16, @truncate(a));
    const y: i32 = @as(i16, @truncate(b));
    return (16384 + x * y) >> 15;
}

/// cos(x pi/2) for x in Q14, in Q15: the same on every platform, as the
/// bit allocation depends on it.
fn bitexactCos(x: i32) i32 {
    const tmp = (4096 + x * x) >> 13;
    const x2: i32 = tmp;
    const r = (32767 - x2) + fracMul16(x2, -7651 + fracMul16(x2, 8277 + fracMul16(-626, x2)));
    return 1 + r;
}

/// log2(sin/cos) in Q11, bit-exactly.
fn bitexactLog2Tan(isin_in: i32, icos_in: i32) i32 {
    const lc: i32 = @intCast(32 - @clz(@as(u32, @intCast(icos_in))));
    const ls: i32 = @intCast(32 - @clz(@as(u32, @intCast(isin_in))));
    const icos = icos_in << @intCast(15 - lc);
    const isin = isin_in << @intCast(15 - ls);
    return (ls - lc) * (1 << 11) + fracMul16(isin, fracMul16(isin, -2597) + 7932) - fracMul16(icos, fracMul16(icos, -2597) + 7932);
}

fn isqrt32(value: u32) u32 {
    var val = value;
    var g: u32 = 0;
    var bshift: i32 = @as(i32, @intCast(32 - @clz(val))) - 1;
    bshift >>= 1;
    var b: u32 = @as(u32, 1) << @intCast(bshift);
    while (true) {
        const t = ((g << 1) + b) << @intCast(bshift);
        if (t <= val) {
            g += b;
            val -= t;
        }
        b >>= 1;
        bshift -= 1;
        if (bshift < 0) break;
    }
    return g;
}

const Ctx = struct {
    dec: *Range,
    band: usize,
    intensity: u32,
    spread: u32,
    tf_change: i32,
    remaining_bits: i32,
    seed: u32,
    disable_inv: bool,
    avoid_split_noise: bool,
};

const Split = struct {
    inv: bool,
    imid: i32,
    iside: i32,
    delta: i32,
    itheta: i32,
    qalloc: i32,
};

fn computeQn(n: i32, b: i32, offset: i32, pulse_cap: i32, stereo: bool) i32 {
    const exp2_table8 = [8]i32{ 16384, 17866, 19483, 21247, 23170, 25267, 27554, 30048 };
    var n2 = 2 * n - 1;
    if (stereo and n == 2) n2 -= 1;
    var qb = @divTrunc(b + n2 * offset, n2);
    qb = @min(b - pulse_cap - (4 << bitres), qb);
    qb = @min(8 << bitres, qb);
    if (qb < (1 << bitres >> 1)) return 1;
    const qn = exp2_table8[@intCast(qb & 7)] >> @intCast(14 - (qb >> bitres));
    return (qn + 1) >> 1 << 1;
}

/// The angle that splits `n` coefficients' bits in two: decoded, and what
/// follows from it.
fn computeTheta(ctx: *Ctx, n: i32, b: *i32, bb: u32, b0: u32, lm: i32, stereo: bool, fill: *u32) Split {
    const dec = ctx.dec;
    const pulse_cap = tables.log_n[ctx.band] + lm * (1 << bitres);
    const offset = (pulse_cap >> 1) - (if (stereo and n == 2) @as(i32, 16) else 4);
    var qn = computeQn(n, b.*, offset, pulse_cap, stereo);
    if (stereo and ctx.band >= ctx.intensity) qn = 1;
    var itheta: i32 = 0;
    var inv = false;
    const tell = dec.tellFrac();
    if (qn != 1) {
        const uqn: u32 = @intCast(qn);
        if (stereo and n > 2) {
            // A step: three times as likely up to half, then flat.
            const p0: u32 = 3;
            const x0 = uqn / 2;
            const ft = p0 * (x0 + 1) + x0;
            const fs = dec.decode(ft);
            const x = if (fs < (x0 + 1) * p0) fs / p0 else x0 + 1 + (fs - (x0 + 1) * p0);
            const fl = if (x <= x0) p0 * x else (x - 1 - x0) + (x0 + 1) * p0;
            const fh = if (x <= x0) p0 * (x + 1) else (x - x0) + (x0 + 1) * p0;
            dec.update(fl, fh, ft);
            itheta = @intCast(x);
        } else if (b0 > 1 or stereo) {
            itheta = @intCast(dec.uint(uqn + 1));
        } else {
            // A triangle.
            const half = uqn >> 1;
            const ft = (half + 1) * (half + 1);
            const fm = dec.decode(ft);
            var fs: u32 = undefined;
            var fl: u32 = undefined;
            var t: u32 = undefined;
            if (fm < (half * (half + 1) >> 1)) {
                t = (isqrt32(8 * fm + 1) - 1) >> 1;
                fs = t + 1;
                fl = t * (t + 1) >> 1;
            } else {
                t = (2 * (uqn + 1) - isqrt32(8 * (ft - fm - 1) + 1)) >> 1;
                fs = uqn + 1 - t;
                fl = ft - ((uqn + 1 - t) * (uqn + 2 - t) >> 1);
            }
            dec.update(fl, fl + fs, ft);
            itheta = @intCast(t);
        }
        itheta = @intCast(@as(u32, @intCast(itheta)) * 16384 / uqn);
    } else if (stereo) {
        if (b.* > 2 << bitres and ctx.remaining_bits > 2 << bitres) inv = dec.bitLogp(2);
        if (ctx.disable_inv) inv = false;
        itheta = 0;
    }
    const qalloc: i32 = @intCast(dec.tellFrac() - tell);
    b.* -= qalloc;
    var split: Split = .{ .inv = inv, .imid = 0, .iside = 0, .delta = 0, .itheta = itheta, .qalloc = qalloc };
    const mask = (@as(u32, 1) << @intCast(bb)) - 1;
    if (itheta == 0) {
        split.imid = 32767;
        split.iside = 0;
        fill.* &= mask;
        split.delta = -16384;
    } else if (itheta == 16384) {
        split.imid = 0;
        split.iside = 32767;
        fill.* &= mask << @intCast(bb);
        split.delta = 16384;
    } else {
        split.imid = bitexactCos(itheta);
        split.iside = bitexactCos(16384 - itheta);
        split.delta = fracMul16((n - 1) << 7, bitexactLog2Tan(split.iside, split.imid));
    }
    return split;
}

/// A band of one coefficient: its sign, for each channel.
fn bandN1(ctx: *Ctx, x: [*]f32, y: ?[*]f32, lowband_out: ?[*]f32) u32 {
    var channel = x;
    var c: u32 = 0;
    while (c < 1 + @as(u32, @intFromBool(y != null))) : (c += 1) {
        var sign: u32 = 0;
        if (ctx.remaining_bits >= 1 << bitres) {
            sign = ctx.dec.bits(1);
            ctx.remaining_bits -= 1 << bitres;
        }
        channel[0] = if (sign != 0) -1.0 else 1.0;
        if (y) |other| channel = other;
    }
    if (lowband_out) |out| out[0] = x[0];
    return 1;
}

/// A mono piece of `n` coefficients and `b` eighths: split in two while
/// it has bits for more than the most pulses it can hold, else its pulses
/// decoded - or, with none, folded or noise.
fn partition(ctx: *Ctx, x: [*]f32, n_in: i32, b_in: i32, bb_in: u32, lowband: ?[*]f32, lm_in: i32, gain: f32, fill_in: u32) u32 {
    var n = n_in;
    var b = b_in;
    var bb = bb_in;
    var lm = lm_in;
    var fill = fill_in;
    const b0 = bb;
    const i = ctx.band;
    var split_it = false;
    if (lm != -1 and n > 2) {
        const at: usize = @intCast(tables.cache_index[@as(usize, @intCast(lm + 1)) * tables.bands + i]);
        const cache = tables.cache_bits[at..];
        split_it = b > @as(i32, cache[cache[0]]) + 12;
    }
    if (split_it) {
        n >>= 1;
        const y = x + @as(usize, @intCast(n));
        lm -= 1;
        if (bb == 1) fill = (fill & 1) | (fill << 1);
        bb = (bb + 1) >> 1;
        const split = computeTheta(ctx, n, &b, bb, b0, lm, false, &fill);
        const mid = (1.0 / 32768.0) * @as(f32, @floatFromInt(split.imid));
        const side = (1.0 / 32768.0) * @as(f32, @floatFromInt(split.iside));
        var delta = split.delta;
        // More bits to the quieter short blocks than they would get.
        if (b0 > 1 and (split.itheta & 0x3fff) != 0) {
            if (split.itheta > 8192) {
                delta -= delta >> @intCast(4 - lm);
            } else {
                delta = @min(0, delta + (n << bitres >> @intCast(5 - lm)));
            }
        }
        var mbits: i32 = @max(0, @min(b, @divTrunc(b - delta, 2)));
        var sbits = b - mbits;
        ctx.remaining_bits -= split.qalloc;
        const next_lowband2: ?[*]f32 = if (lowband) |low| low + @as(usize, @intCast(n)) else null;
        var rebalance = ctx.remaining_bits;
        var cm: u32 = undefined;
        if (mbits >= sbits) {
            cm = partition(ctx, x, n, mbits, bb, lowband, lm, gain * mid, fill);
            rebalance = mbits - (rebalance - ctx.remaining_bits);
            if (rebalance > 3 << bitres and split.itheta != 0) sbits += rebalance - (3 << bitres);
            cm |= partition(ctx, y, n, sbits, bb, next_lowband2, lm, gain * side, fill >> @intCast(bb)) << @intCast(b0 >> 1);
        } else {
            cm = partition(ctx, y, n, sbits, bb, next_lowband2, lm, gain * side, fill >> @intCast(bb)) << @intCast(b0 >> 1);
            rebalance = sbits - (rebalance - ctx.remaining_bits);
            if (rebalance > 3 << bitres and split.itheta != 16384) mbits += rebalance - (3 << bitres);
            cm |= partition(ctx, x, n, mbits, bb, lowband, lm, gain * mid, fill);
        }
        return cm;
    }

    // No split: the pulses the bits pay for, never more than are left.
    var q = alloc.bitsToPulses(i, lm, b);
    var curr_bits = alloc.pulsesToBits(i, lm, q);
    ctx.remaining_bits -= curr_bits;
    while (ctx.remaining_bits < 0 and q > 0) {
        ctx.remaining_bits += curr_bits;
        q -= 1;
        curr_bits = alloc.pulsesToBits(i, lm, q);
        ctx.remaining_bits -= curr_bits;
    }
    const un: u32 = @intCast(n);
    if (q != 0) return pvq.unquant(x[0..un], un, alloc.getPulses(q), ctx.spread, bb, ctx.dec, gain);
    const cm_mask = (@as(u32, 1) << @intCast(bb)) - 1;
    fill &= cm_mask;
    if (fill == 0) {
        @memset(x[0..un], 0);
        return 0;
    }
    var cm: u32 = undefined;
    if (lowband) |low| {
        // The lower band's shape, with a little noise.
        for (0..un) |j| {
            ctx.seed = lcgRand(ctx.seed);
            const tmp: f32 = if (ctx.seed & 0x8000 != 0) 1.0 / 256.0 else -1.0 / 256.0;
            x[j] = low[j] + tmp;
        }
        cm = fill;
    } else {
        for (0..un) |j| {
            ctx.seed = lcgRand(ctx.seed);
            x[j] = @floatFromInt(@as(i32, @bitCast(ctx.seed)) >> 20);
        }
        cm = cm_mask;
    }
    pvq.renormalise(x[0..un], gain);
    return cm;
}

fn haar1(x: [*]f32, n0_in: usize, stride: usize) void {
    const n0 = n0_in >> 1;
    const c: f32 = 0.70710678;
    for (0..stride) |i| {
        for (0..n0) |j| {
            const tmp1 = c * x[stride * 2 * j + i];
            const tmp2 = c * x[stride * (2 * j + 1) + i];
            x[stride * 2 * j + i] = tmp1 + tmp2;
            x[stride * (2 * j + 1) + i] = tmp1 - tmp2;
        }
    }
}

/// The natural Hadamard order made the "ordery" one: bit-reversed Gray,
/// the DC last - for 2, 4, 8 and 16 blocks.
const ordery_table = [_]u8{
    1,  0,
    3,  0,
    2,  1,
    7,  0,
    4,  3,
    6,  1,
    5,  2,
    15, 0,
    8,  7,
    12, 3,
    11, 4,
    14, 1,
    9,  6,
    13, 2,
    10, 5,
};

fn deinterleave(x: [*]f32, n0: usize, stride: usize, hadamard: bool) void {
    var tmp: [176]f32 = undefined;
    const n = n0 * stride;
    if (hadamard) {
        const ordery = ordery_table[stride - 2 ..];
        for (0..stride) |i| {
            for (0..n0) |j| tmp[ordery[i] * n0 + j] = x[j * stride + i];
        }
    } else {
        for (0..stride) |i| {
            for (0..n0) |j| tmp[i * n0 + j] = x[j * stride + i];
        }
    }
    @memcpy(x[0..n], tmp[0..n]);
}

fn interleave(x: [*]f32, n0: usize, stride: usize, hadamard: bool) void {
    var tmp: [176]f32 = undefined;
    const n = n0 * stride;
    if (hadamard) {
        const ordery = ordery_table[stride - 2 ..];
        for (0..stride) |i| {
            for (0..n0) |j| tmp[j * stride + i] = x[ordery[i] * n0 + j];
        }
    } else {
        for (0..stride) |i| {
            for (0..n0) |j| tmp[j * stride + i] = x[i * n0 + j];
        }
    }
    @memcpy(x[0..n], tmp[0..n]);
}

/// A mono band: its time-frequency resolution changed, its blocks put in
/// time order, decoded, and all of it undone; a copy kept to fold from.
fn band(ctx: *Ctx, x: [*]f32, n: i32, b: i32, bb_in: u32, lowband_in: ?[*]f32, lm: i32, lowband_out: ?[*]f32, gain: f32, lowband_scratch: ?[*]f32, fill_in: u32) u32 {
    const n0: usize = @intCast(n);
    var bb = bb_in;
    var b0 = bb;
    var fill = fill_in;
    var lowband = lowband_in;
    const long_blocks = b0 == 1;
    var n_b: usize = n0 / bb;
    var time_divide: u32 = 0;
    var recombine: u32 = 0;
    var tf_change = ctx.tf_change;
    if (n == 1) return bandN1(ctx, x, null, lowband_out);
    if (tf_change > 0) recombine = @intCast(tf_change);
    if (lowband_scratch) |scratch| {
        if (lowband) |low| {
            if (recombine != 0 or ((n_b & 1) == 0 and tf_change < 0) or b0 > 1) {
                @memcpy(scratch[0..n0], low[0..n0]);
                lowband = scratch;
            }
        }
    }
    const bit_interleave_table = [16]u8{ 0, 1, 1, 1, 2, 3, 3, 3, 2, 3, 3, 3, 2, 3, 3, 3 };
    for (0..recombine) |k| {
        if (lowband) |low| haar1(low, n0 >> @intCast(k), @as(usize, 1) << @intCast(k));
        fill = bit_interleave_table[fill & 0xF] | @as(u32, bit_interleave_table[fill >> 4]) << 2;
    }
    bb >>= @intCast(recombine);
    n_b <<= @intCast(recombine);
    while ((n_b & 1) == 0 and tf_change < 0) {
        if (lowband) |low| haar1(low, n_b, bb);
        fill |= fill << @intCast(bb);
        bb <<= 1;
        n_b >>= 1;
        time_divide += 1;
        tf_change += 1;
    }
    b0 = bb;
    const n_b0 = n_b;
    if (b0 > 1) {
        if (lowband) |low| deinterleave(low, n_b >> @intCast(recombine), b0 << @intCast(recombine), long_blocks);
    }
    var cm = partition(ctx, x, n, b, bb, lowband, lm, gain, fill);

    if (b0 > 1) interleave(x, n_b >> @intCast(recombine), b0 << @intCast(recombine), long_blocks);
    n_b = n_b0;
    bb = b0;
    for (0..time_divide) |_| {
        bb >>= 1;
        n_b <<= 1;
        cm |= cm >> @intCast(bb);
        haar1(x, n_b, bb);
    }
    const bit_deinterleave_table = [16]u8{ 0x00, 0x03, 0x0C, 0x0F, 0x30, 0x33, 0x3C, 0x3F, 0xC0, 0xC3, 0xCC, 0xCF, 0xF0, 0xF3, 0xFC, 0xFF };
    for (0..recombine) |k| {
        cm = bit_deinterleave_table[cm];
        haar1(x, n0 >> @intCast(k), @as(usize, 1) << @intCast(k));
    }
    bb <<= @intCast(recombine);
    if (lowband_out) |out| {
        const scale = @sqrt(@as(f32, @floatFromInt(n0)));
        for (0..n0) |j| out[j] = scale * x[j];
    }
    cm &= (@as(u32, 1) << @intCast(bb)) - 1;
    return cm;
}

/// Mid and side back into left and right.
fn stereoMerge(x: [*]f32, y: [*]f32, mid: f32, n: usize) void {
    var xp: f32 = 0;
    var side: f32 = 0;
    for (0..n) |j| {
        xp += y[j] * x[j];
        side += y[j] * y[j];
    }
    xp = mid * xp;
    const el = mid * mid + side - 2 * xp;
    const er = mid * mid + side + 2 * xp;
    if (er < 6e-4 or el < 6e-4) {
        @memcpy(y[0..n], x[0..n]);
        return;
    }
    const lgain = 1.0 / @sqrt(el);
    const rgain = 1.0 / @sqrt(er);
    for (0..n) |j| {
        const l = mid * x[j];
        const r = y[j];
        x[j] = lgain * (l - r);
        y[j] = rgain * (l + r);
    }
}

/// A stereo band: the angle between mid and side, both decoded, merged.
fn bandStereo(ctx: *Ctx, x: [*]f32, y: [*]f32, n: i32, b_in: i32, bb: u32, lowband: ?[*]f32, lm: i32, lowband_out: ?[*]f32, lowband_scratch: ?[*]f32, fill_in: u32) u32 {
    var b = b_in;
    var fill = fill_in;
    if (n == 1) return bandN1(ctx, x, y, lowband_out);
    const orig_fill = fill;
    const split = computeTheta(ctx, n, &b, bb, bb, lm, true, &fill);
    const mid = (1.0 / 32768.0) * @as(f32, @floatFromInt(split.imid));
    const side = (1.0 / 32768.0) * @as(f32, @floatFromInt(split.iside));
    var cm: u32 = undefined;
    if (n == 2) {
        // The side is orthogonal to the mid: one bit, its sign.
        var mbits = b;
        var sbits: i32 = 0;
        if (split.itheta != 0 and split.itheta != 16384) sbits = 1 << bitres;
        mbits -= sbits;
        const swap = split.itheta > 8192;
        ctx.remaining_bits -= split.qalloc + sbits;
        const x2 = if (swap) y else x;
        const y2 = if (swap) x else y;
        var sign: u32 = 0;
        if (sbits != 0) sign = ctx.dec.bits(1);
        const s: f32 = if (sign != 0) -1.0 else 1.0;
        cm = band(ctx, x2, n, mbits, bb, lowband, lm, lowband_out, 1.0, lowband_scratch, orig_fill);
        y2[0] = -s * x2[1];
        y2[1] = s * x2[0];
        x[0] *= mid;
        x[1] *= mid;
        y[0] *= side;
        y[1] *= side;
        var tmp = x[0];
        x[0] = tmp - y[0];
        y[0] = tmp + y[0];
        tmp = x[1];
        x[1] = tmp - y[1];
        y[1] = tmp + y[1];
    } else {
        var mbits: i32 = @max(0, @min(b, @divTrunc(b - split.delta, 2)));
        var sbits = b - mbits;
        ctx.remaining_bits -= split.qalloc;
        var rebalance = ctx.remaining_bits;
        if (mbits >= sbits) {
            cm = band(ctx, x, n, mbits, bb, lowband, lm, lowband_out, 1.0, lowband_scratch, fill);
            rebalance = mbits - (rebalance - ctx.remaining_bits);
            if (rebalance > 3 << bitres and split.itheta != 0) sbits += rebalance - (3 << bitres);
            cm |= band(ctx, y, n, sbits, bb, null, lm, null, side, null, fill >> @intCast(bb));
        } else {
            cm = band(ctx, y, n, sbits, bb, null, lm, null, side, null, fill >> @intCast(bb));
            rebalance = sbits - (rebalance - ctx.remaining_bits);
            if (rebalance > 3 << bitres and split.itheta != 16384) mbits += rebalance - (3 << bitres);
            cm |= band(ctx, x, n, mbits, bb, lowband, lm, lowband_out, 1.0, lowband_scratch, fill);
        }
    }
    const un: usize = @intCast(n);
    if (n != 2) stereoMerge(x, y, mid, un);
    if (split.inv) {
        for (0..un) |j| y[j] = -y[j];
    }
    return cm;
}

/// What the bands need from the frame.
pub const Frame = struct {
    start: u32,
    end: u32,
    lm: u32,
    short_blocks: bool,
    spread: u32,
    dual_stereo: bool,
    intensity: u32,
    tf_res: *const [tables.bands]i32,
    total_bits: i32,
    balance: i32,
    coded_bands: u32,
    pulses: *const [tables.bands]i32,
    disable_inv: bool,
};

/// Room for the folding copies of both channels: up to the last band.
pub const norm_size = 2 * 8 * 78;

/// The shapes of bands start to end into `x` (and `y` for stereo), the
/// collapse masks noted; the seed of the noise carried on. `norm_buffer`
/// holds the folding copies.
pub fn decodeAll(f: *const Frame, x_all: [*]f32, y_all: ?[*]f32, collapse_masks: *[tables.bands * 2]u8, norm_buffer: *[norm_size]f32, dec: *Range, seed: *u32) void {
    const e = &tables.e_bands;
    const m: i32 = @as(i32, 1) << @intCast(f.lm);
    const lm: i32 = @intCast(f.lm);
    const bb: u32 = if (f.short_blocks) @intCast(m) else 1;
    const channels: usize = if (y_all != null) 2 else 1;
    const norm_offset: usize = @intCast(m * e[f.start]);
    // The folding copies: no band above the last needs one.
    const norm_len: usize = @as(usize, @intCast(m * e[tables.bands - 1])) - norm_offset;
    const norm: [*]f32 = norm_buffer;
    const norm2: [*]f32 = norm + norm_len;
    // The last band's room serves as scratch until it is decoded.
    var lowband_scratch: ?[*]f32 = x_all + @as(usize, @intCast(m * e[tables.bands - 1]));
    var dual_stereo = f.dual_stereo;
    var balance = f.balance;
    var lowband_offset: usize = 0;
    var update_lowband = true;
    var ctx: Ctx = .{
        .dec = dec,
        .band = 0,
        .intensity = f.intensity,
        .spread = f.spread,
        .tf_change = 0,
        .remaining_bits = 0,
        .seed = seed.*,
        .disable_inv = f.disable_inv,
        .avoid_split_noise = bb > 1,
    };
    var i: usize = f.start;
    while (i < f.end) : (i += 1) {
        ctx.band = i;
        const last = i == f.end - 1;
        const x = x_all + @as(usize, @intCast(m * e[i]));
        const y: ?[*]f32 = if (y_all) |all| all + @as(usize, @intCast(m * e[i])) else null;
        const n: i32 = m * e[i + 1] - m * e[i];
        const tell: i32 = @intCast(dec.tellFrac());
        if (i != f.start) balance -= tell;
        const remaining_bits = f.total_bits - tell - 1;
        ctx.remaining_bits = remaining_bits;
        var b: i32 = 0;
        if (i + 1 <= f.coded_bands) {
            const curr_balance = @divTrunc(balance, @min(3, @as(i32, @intCast(f.coded_bands - i))));
            b = @max(0, @min(16383, @min(remaining_bits + 1, f.pulses[i] + curr_balance)));
        }
        if ((m * e[i] - n >= m * e[f.start] or i == f.start + 1) and (update_lowband or lowband_offset == 0)) lowband_offset = i;
        if (i == f.start + 1) {
            // The first band's copy long enough to fold the second from.
            const n1: usize = @intCast(m * (e[f.start + 1] - e[f.start]));
            const n2: usize = @intCast(m * (e[f.start + 2] - e[f.start + 1]));
            if (n2 > n1) {
                copyForward(norm + n1, norm + 2 * n1 - n2, n2 - n1);
                if (dual_stereo) copyForward(norm2 + n1, norm2 + 2 * n1 - n2, n2 - n1);
            }
        }
        ctx.tf_change = f.tf_res[i];
        if (last) lowband_scratch = null;
        var x_cm: u32 = undefined;
        var y_cm: u32 = undefined;
        var effective_lowband: ?usize = null;
        if (lowband_offset != 0 and (f.spread != pvq.spread_aggressive or bb > 1 or ctx.tf_change < 0)) {
            // Never the same content twice within a band.
            const eff: usize = @intCast(@max(0, m * e[lowband_offset] - @as(i32, @intCast(norm_offset)) - n));
            effective_lowband = eff;
            var fold_start = lowband_offset;
            while (true) {
                fold_start -= 1;
                if (m * e[fold_start] <= @as(i32, @intCast(eff + norm_offset))) break;
            }
            var fold_end = lowband_offset - 1;
            while (true) {
                fold_end += 1;
                if (!(fold_end < i and m * e[fold_end] < @as(i32, @intCast(eff + norm_offset)) + n)) break;
            }
            x_cm = 0;
            y_cm = 0;
            var fold_i = fold_start;
            while (true) {
                x_cm |= collapse_masks[fold_i * channels];
                y_cm |= collapse_masks[fold_i * channels + channels - 1];
                fold_i += 1;
                if (fold_i >= fold_end) break;
            }
        } else {
            x_cm = (@as(u32, 1) << @intCast(bb)) - 1;
            y_cm = x_cm;
        }
        if (dual_stereo and i == f.intensity) {
            // Dual stereo ends where intensity begins.
            dual_stereo = false;
            const upto: usize = @as(usize, @intCast(m * e[i])) - norm_offset;
            for (0..upto) |j| norm[j] = 0.5 * (norm[j] + norm2[j]);
        }
        const out_at: usize = @as(usize, @intCast(m * e[i])) - norm_offset;
        if (dual_stereo) {
            x_cm = band(&ctx, x, n, @divTrunc(b, 2), bb, if (effective_lowband) |eff| norm + eff else null, lm, if (last) null else norm + out_at, 1.0, lowband_scratch, x_cm);
            y_cm = band(&ctx, y.?, n, @divTrunc(b, 2), bb, if (effective_lowband) |eff| norm2 + eff else null, lm, if (last) null else norm2 + out_at, 1.0, lowband_scratch, y_cm);
        } else {
            if (y) |yy| {
                x_cm = bandStereo(&ctx, x, yy, n, b, bb, if (effective_lowband) |eff| norm + eff else null, lm, if (last) null else norm + out_at, lowband_scratch, x_cm | y_cm);
            } else {
                x_cm = band(&ctx, x, n, b, bb, if (effective_lowband) |eff| norm + eff else null, lm, if (last) null else norm + out_at, 1.0, lowband_scratch, x_cm | y_cm);
            }
            y_cm = x_cm;
        }
        collapse_masks[i * channels] = @truncate(x_cm);
        collapse_masks[i * channels + channels - 1] = @truncate(y_cm);
        balance += f.pulses[i] + tell;
        update_lowband = b > (n << bitres);
        ctx.avoid_split_noise = false;
    }
    seed.* = ctx.seed;
}

fn copyForward(to: [*]f32, from: [*]const f32, count: usize) void {
    for (0..count) |k| to[k] = from[k];
}

/// The shapes scaled by the energies: the spectrum of a channel, zero
/// outside the bands decoded.
pub fn denormalise(x: [*]const f32, freq: [*]f32, band_log_e: [*]const f32, start_in: u32, end_in: u32, m: u32, downsample: u32, silence: bool) void {
    const e = &tables.e_bands;
    const n = m * tables.short_mdct;
    var start = start_in;
    var end = end_in;
    var bound: u32 = m * @as(u32, @intCast(e[end]));
    if (downsample != 1) bound = @min(bound, n / downsample);
    if (silence) {
        bound = 0;
        start = 0;
        end = 0;
    }
    const first = m * @as(u32, @intCast(e[start]));
    @memset(freq[0..first], 0);
    var at: usize = first;
    for (start..end) |i| {
        const band_end = m * @as(u32, @intCast(e[i + 1]));
        const lg = band_log_e[i] + tables.e_means[i];
        const g = @exp2(@min(32.0, lg));
        while (at < band_end) : (at += 1) freq[at] = x[at] * g;
    }
    @memset(freq[bound..n], 0);
}

/// Noise into the short blocks of a transient frame's bands that got no
/// pulse, at a level the energies of the two frames before allow.
pub fn antiCollapse(x_all: [*]f32, collapse_masks: *const [tables.bands * 2]u8, lm: u32, channels: u32, size: usize, start: u32, end: u32, log_e: [*]const f32, prev1_log_e: [*]const f32, prev2_log_e: [*]const f32, pulses: *const [tables.bands]i32, seed_in: u32) void {
    const e = &tables.e_bands;
    var seed = seed_in;
    for (start..end) |i| {
        const n0: u32 = @intCast(e[i + 1] - e[i]);
        const depth = (@as(u32, @intCast(1 + pulses[i])) / n0) >> @intCast(lm);
        const thresh = 0.5 * @exp2(-0.125 * @as(f32, @floatFromInt(depth)));
        const sqrt_1 = 1.0 / @sqrt(@as(f32, @floatFromInt(n0 << @intCast(lm))));
        for (0..channels) |c| {
            var prev1 = prev1_log_e[c * tables.bands + i];
            var prev2 = prev2_log_e[c * tables.bands + i];
            if (channels == 1) {
                prev1 = @max(prev1, prev1_log_e[tables.bands + i]);
                prev2 = @max(prev2, prev2_log_e[tables.bands + i]);
            }
            const ediff = @max(0, log_e[c * tables.bands + i] - @min(prev1, prev2));
            var r = 2.0 * @exp2(-ediff);
            if (lm == 3) r *= 1.41421356;
            r = @min(thresh, r);
            r = r * sqrt_1;
            const x = x_all + c * size + @as(usize, @intCast(e[i])) * (@as(usize, 1) << @intCast(lm));
            var renormalize = false;
            for (0..@as(usize, 1) << @intCast(lm)) |k| {
                if (collapse_masks[i * channels + c] & (@as(u32, 1) << @intCast(k)) == 0) {
                    for (0..n0) |j| {
                        seed = lcgRand(seed);
                        x[(j << @intCast(lm)) + k] = if (seed & 0x8000 != 0) r else -r;
                    }
                    renormalize = true;
                }
            }
            if (renormalize) pvq.renormalise(x[0 .. n0 << @intCast(lm)], 1.0);
        }
    }
}

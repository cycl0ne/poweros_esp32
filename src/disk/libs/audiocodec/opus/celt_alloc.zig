// SPDX-License-Identifier: MIT
//! How a CELT frame's bits are shared among its bands (RFC 6716 4.3.3):
//! a curve between two of the allocation vectors, found by halving, with
//! the frame's trim tilting it and its boosts on top; the bands at the
//! top it cannot pay for skipped - the encoder says where to stop - then
//! each band's bits split between fine energy and its pulses. Every
//! decoder must reach the same numbers, so all of it is integers.
//!
//! Bits are counted in eighths (BITRES).

const tables = @import("celt_tables.zig");
const Range = @import("range.zig").Range;

pub const bitres = 3;
const alloc_steps = 6;
pub const max_fine_bits = 8;
const fine_offset = 21;

/// The pulses of pseudo-count `i`: 0 to 7, then more and more apart.
pub fn getPulses(i: u32) u32 {
    return if (i < 8) i else (8 + (i & 7)) << @intCast((i >> 3) - 1);
}

fn cacheRow(band: usize, lm: i32) []const u8 {
    const at: usize = @intCast(tables.cache_index[@as(usize, @intCast(lm + 1)) * tables.bands + band]);
    return tables.cache_bits[at..];
}

/// The pseudo-count of pulses that best fits `bits` eighths in band
/// `band` at `lm`.
pub fn bitsToPulses(band: usize, lm: i32, bits_in: i32) u32 {
    const cache = cacheRow(band, lm);
    var lo: u32 = 0;
    var hi: u32 = cache[0];
    const bits = bits_in - 1;
    for (0..6) |_| {
        const mid = (lo + hi + 1) >> 1;
        if (@as(i32, cache[mid]) >= bits) hi = mid else lo = mid;
    }
    const below: i32 = if (lo == 0) -1 else cache[lo];
    return if (bits - below <= @as(i32, cache[hi]) - bits) lo else hi;
}

/// The eighths `pulses` (a pseudo-count) cost in band `band` at `lm`.
pub fn pulsesToBits(band: usize, lm: i32, pulses: u32) i32 {
    const cache = cacheRow(band, lm);
    return if (pulses == 0) 0 else @as(i32, cache[pulses]) + 1;
}

/// The most eighths each band can use.
pub fn initCaps(cap: *[tables.bands]i32, lm: u32, channels: u32) void {
    for (0..tables.bands) |i| {
        const n: i32 = (tables.e_bands[i + 1] - tables.e_bands[i]) << @intCast(lm);
        const row = tables.bands * (2 * lm + channels - 1);
        cap[i] = (@as(i32, tables.cache_caps[row + i]) + 64) * @as(i32, @intCast(channels)) * n >> 2;
    }
}

pub const Allocation = struct {
    pulses: [tables.bands]i32,
    fine_bits: [tables.bands]i32,
    fine_priority: [tables.bands]i32,
    intensity: u32,
    dual_stereo: bool,
    balance: i32,
    coded_bands: u32,
};

/// The bits of bands start to end shared out of `total_in` eighths.
pub fn compute(start: u32, end: u32, offsets: *const [tables.bands]i32, cap: *const [tables.bands]i32, alloc_trim: i32, total_in: i32, channels: u32, lm: u32, dec: *Range, out: *Allocation) void {
    const c: i32 = @intCast(channels);
    var total: i32 = @max(total_in, 0);
    const len = tables.bands;
    var skip_start = start;
    const skip_rsv: i32 = if (total >= 1 << bitres) 1 << bitres else 0;
    total -= skip_rsv;
    var intensity_rsv: i32 = 0;
    var dual_stereo_rsv: i32 = 0;
    if (channels == 2) {
        intensity_rsv = tables.log2_frac[end - start];
        if (intensity_rsv > total) {
            intensity_rsv = 0;
        } else {
            total -= intensity_rsv;
            dual_stereo_rsv = if (total >= 1 << bitres) 1 << bitres else 0;
            total -= dual_stereo_rsv;
        }
    }
    var bits1: [len]i32 = undefined;
    var bits2: [len]i32 = undefined;
    var thresh: [len]i32 = undefined;
    var trim_offset: [len]i32 = undefined;
    const lms: u5 = @intCast(lm);
    for (start..end) |j| {
        const width: i32 = tables.e_bands[j + 1] - tables.e_bands[j];
        thresh[j] = @max(c << bitres, (3 * width << lms << bitres) >> 4);
        trim_offset[j] = c * width * (alloc_trim - 5 - @as(i32, @intCast(lm))) * @as(i32, @intCast(end - j - 1)) * (@as(i32, 1) << (lms + bitres)) >> 6;
        if (width << lms == 1) trim_offset[j] -= c << bitres;
    }
    var lo: i32 = 1;
    var hi: i32 = 11 - 1;
    while (true) {
        var done = false;
        var psum: i32 = 0;
        const mid = (lo + hi) >> 1;
        var j = end;
        while (j > start) {
            j -= 1;
            const width: i32 = tables.e_bands[j + 1] - tables.e_bands[j];
            var bitsj: i32 = c * width * @as(i32, tables.band_allocation[@as(usize, @intCast(mid)) * len + j]) << lms >> 2;
            if (bitsj > 0) bitsj = @max(0, bitsj + trim_offset[j]);
            bitsj += offsets[j];
            if (bitsj >= thresh[j] or done) {
                done = true;
                psum += @min(bitsj, cap[j]);
            } else if (bitsj >= c << bitres) {
                psum += c << bitres;
            }
        }
        if (psum > total) hi = mid - 1 else lo = mid + 1;
        if (lo > hi) break;
    }
    hi = lo;
    lo -= 1;
    for (start..end) |j| {
        const width: i32 = tables.e_bands[j + 1] - tables.e_bands[j];
        var bits1j: i32 = c * width * @as(i32, tables.band_allocation[@as(usize, @intCast(lo)) * len + j]) << lms >> 2;
        var bits2j: i32 = if (hi >= 11) cap[j] else c * width * @as(i32, tables.band_allocation[@as(usize, @intCast(hi)) * len + j]) << lms >> 2;
        if (bits1j > 0) bits1j = @max(0, bits1j + trim_offset[j]);
        if (bits2j > 0) bits2j = @max(0, bits2j + trim_offset[j]);
        if (lo > 0) bits1j += offsets[j];
        bits2j += offsets[j];
        if (offsets[j] > 0) skip_start = @intCast(j);
        bits2j = @max(0, bits2j - bits1j);
        bits1[j] = bits1j;
        bits2[j] = bits2j;
    }
    interpolate(start, end, skip_start, &bits1, &bits2, &thresh, cap, total, skip_rsv, intensity_rsv, dual_stereo_rsv, channels, lm, dec, out);
}

fn interpolate(start: u32, end: u32, skip_start: u32, bits1: *const [tables.bands]i32, bits2: *const [tables.bands]i32, thresh: *const [tables.bands]i32, cap: *const [tables.bands]i32, total_in: i32, skip_rsv: i32, intensity_rsv_in: i32, dual_stereo_rsv_in: i32, channels: u32, lm: u32, dec: *Range, out: *Allocation) void {
    const c: i32 = @intCast(channels);
    const e = &tables.e_bands;
    var total = total_in;
    var intensity_rsv = intensity_rsv_in;
    var dual_stereo_rsv = dual_stereo_rsv_in;
    const alloc_floor: i32 = c << bitres;
    const stereo: u5 = @intFromBool(channels > 1);
    const log_m: i32 = @as(i32, @intCast(lm)) << bitres;
    const bits = &out.pulses;
    const ebits = &out.fine_bits;
    const fine_priority = &out.fine_priority;

    var lo: i32 = 0;
    var hi: i32 = 1 << alloc_steps;
    for (0..alloc_steps) |_| {
        const mid = (lo + hi) >> 1;
        var psum: i32 = 0;
        var done = false;
        var j = end;
        while (j > start) {
            j -= 1;
            const tmp = bits1[j] + (mid * bits2[j] >> alloc_steps);
            if (tmp >= thresh[j] or done) {
                done = true;
                psum += @min(tmp, cap[j]);
            } else if (tmp >= alloc_floor) {
                psum += alloc_floor;
            }
        }
        if (psum > total) hi = mid else lo = mid;
    }
    var psum: i32 = 0;
    var done = false;
    {
        var j = end;
        while (j > start) {
            j -= 1;
            var tmp = bits1[j] + (lo * bits2[j] >> alloc_steps);
            if (tmp < thresh[j] and !done) {
                tmp = if (tmp >= alloc_floor) alloc_floor else 0;
            } else {
                done = true;
            }
            tmp = @min(tmp, cap[j]);
            bits[j] = tmp;
            psum += tmp;
        }
    }

    // The bands skipped, from the top down.
    var coded_bands = end;
    while (true) : (coded_bands -= 1) {
        const j = coded_bands - 1;
        if (j <= skip_start) {
            total += skip_rsv;
            break;
        }
        var left = total - psum;
        const span: i32 = e[coded_bands] - e[start];
        const percoeff = @divTrunc(left, span);
        left -= span * percoeff;
        const rem: i32 = @max(left - (e[j] - e[start]), 0);
        const band_width: i32 = e[coded_bands] - e[j];
        var band_bits = bits[j] + percoeff * band_width + rem;
        if (band_bits >= @max(thresh[j], alloc_floor + (1 << bitres))) {
            if (dec.bitLogp(1)) break;
            psum += 1 << bitres;
            band_bits -= 1 << bitres;
        }
        psum -= bits[j] + intensity_rsv;
        if (intensity_rsv > 0) intensity_rsv = tables.log2_frac[j - start];
        psum += intensity_rsv;
        if (band_bits >= alloc_floor) {
            psum += alloc_floor;
            bits[j] = alloc_floor;
        } else {
            bits[j] = 0;
        }
    }

    // The intensity and dual stereo parameters.
    var intensity: u32 = 0;
    if (intensity_rsv > 0) intensity = start + dec.uint(coded_bands + 1 - start);
    if (intensity <= start) {
        total += dual_stereo_rsv;
        dual_stereo_rsv = 0;
    }
    var dual_stereo = false;
    if (dual_stereo_rsv > 0) dual_stereo = dec.bitLogp(1);

    // The bits left shared out.
    var left = total - psum;
    const span: i32 = e[coded_bands] - e[start];
    const percoeff = @divTrunc(left, span);
    left -= span * percoeff;
    for (start..coded_bands) |j| bits[j] += percoeff * (e[j + 1] - e[j]);
    for (start..coded_bands) |j| {
        const tmp = @min(left, e[j + 1] - e[j]);
        bits[j] += tmp;
        left -= tmp;
    }

    // Each band's bits between fine energy and pulses.
    var balance: i32 = 0;
    var j: usize = start;
    while (j < coded_bands) : (j += 1) {
        const n0: i32 = e[j + 1] - e[j];
        const n = n0 << @intCast(lm);
        const bit = bits[j] + balance;
        var excess: i32 = undefined;
        if (n > 1) {
            excess = @max(bit - cap[j], 0);
            bits[j] = bit - excess;
            const den: i32 = c * n + @as(i32, @intFromBool(channels == 2 and n > 2 and !dual_stereo and j < intensity));
            const nclogn = den * (tables.log_n[j] + log_m);
            var offset = (nclogn >> 1) - den * fine_offset;
            if (n == 2) offset += den << bitres >> 2;
            if (bits[j] + offset < den * 2 << bitres) {
                offset += nclogn >> 2;
            } else if (bits[j] + offset < den * 3 << bitres) {
                offset += nclogn >> 3;
            }
            ebits[j] = @max(0, bits[j] + offset + (den << (bitres - 1)));
            ebits[j] = @divTrunc(ebits[j], den) >> bitres;
            if (c * ebits[j] > (bits[j] >> bitres)) ebits[j] = bits[j] >> stereo >> bitres;
            ebits[j] = @min(ebits[j], max_fine_bits);
            fine_priority[j] = @intFromBool(ebits[j] * (den << bitres) >= bits[j] + offset);
            bits[j] -= c * ebits[j] << bitres;
        } else {
            excess = @max(0, bit - (c << bitres));
            bits[j] = bit - excess;
            ebits[j] = 0;
            fine_priority[j] = 1;
        }
        if (excess > 0) {
            const extra_fine = @min(excess >> (stereo + bitres), max_fine_bits - ebits[j]);
            ebits[j] += extra_fine;
            const extra_bits = extra_fine * c << bitres;
            fine_priority[j] = @intFromBool(extra_bits >= excess - balance);
            excess -= extra_bits;
        }
        balance = excess;
    }
    out.balance = balance;
    while (j < end) : (j += 1) {
        ebits[j] = bits[j] >> stereo >> bitres;
        bits[j] = 0;
        fine_priority[j] = @intFromBool(ebits[j] < 1);
    }
    out.intensity = intensity;
    out.dual_stereo = dual_stereo;
    out.coded_bands = coded_bands;
}

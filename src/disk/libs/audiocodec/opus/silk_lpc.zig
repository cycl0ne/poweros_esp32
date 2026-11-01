// SPDX-License-Identifier: MIT
//! SILK's short-term prediction filter (RFC 6716 4.2.7.5): the normalised
//! line spectral frequencies decoded from their two-stage codebook and
//! kept apart, turned into the LPC coefficients by the polynomials their
//! cosines make, and made stable by bandwidth expansion when the
//! prediction gain is too high.

const fix = @import("silk_fix.zig");
const tables = @import("silk_tables.zig");

pub const max_order = 16;

/// Which second-stage distribution each coefficient's residual is read
/// with (`ec_ix`) and the predictor from the one above (`pred_q8`), for
/// first-stage vector `cb1_index`.
pub fn nlsfUnpack(ec_ix: *[max_order]i16, pred_q8: *[max_order]u8, cb: *const tables.NlsfCodebook, cb1_index: u32) void {
    const sel = cb.ec_sel[cb1_index * cb.order / 2 ..];
    var i: usize = 0;
    while (i < cb.order) : (i += 2) {
        const entry = sel[i / 2];
        ec_ix[i] = @intCast(((entry >> 1) & 7) * 9);
        pred_q8[i] = cb.pred_q8[i + (entry & 1) * (cb.order - 1)];
        ec_ix[i + 1] = @intCast(((entry >> 5) & 7) * 9);
        pred_q8[i + 1] = cb.pred_q8[i + ((entry >> 4) & 1) * (cb.order - 1) + 1];
    }
}

/// The NLSFs in Q15 of the codebook path `indices` (the first-stage
/// vector, then each coefficient's residual).
pub fn nlsfDecode(nlsf_q15: []i16, indices: []const i8, cb: *const tables.NlsfCodebook) void {
    var ec_ix: [max_order]i16 = undefined;
    var pred_q8: [max_order]u8 = undefined;
    const cb1: u32 = @intCast(indices[0]);
    nlsfUnpack(&ec_ix, &pred_q8, cb, cb1);

    // The residuals, each predicted from the one above.
    var res_q10: [max_order]i16 = undefined;
    var out_q10: i32 = 0;
    var i: usize = cb.order;
    while (i > 0) {
        i -= 1;
        const pred = fix.smulbb(out_q10, pred_q8[i]) >> 8;
        out_q10 = @as(i32, indices[i + 1]) << 10;
        if (out_q10 > 0) {
            out_q10 -= 102;
        } else if (out_q10 < 0) {
            out_q10 += 102;
        }
        out_q10 = fix.smlawb(pred, out_q10, cb.quant_step_q16);
        res_q10[i] = @truncate(out_q10);
    }

    const element = cb.cb1_q8[cb1 * cb.order ..];
    const weight = cb.cb1_wght_q9[cb1 * cb.order ..];
    for (0..cb.order) |k| {
        const v = @divTrunc(@as(i32, res_q10[k]) << 14, weight[k]) + (@as(i32, element[k]) << 7);
        nlsf_q15[k] = @intCast(@max(0, @min(32767, v)));
    }
    nlsfStabilize(nlsf_q15[0..cb.order], cb.delta_min_q15);
}

/// The NLSFs moved apart until each is at least its minimum distance from
/// the one below (and the first from 0, the last from 1).
pub fn nlsfStabilize(nlsf: []i16, delta_min: []const i16) void {
    const l = nlsf.len;
    var loops: u32 = 0;
    while (loops < 20) : (loops += 1) {
        var min_diff: i32 = @as(i32, nlsf[0]) - delta_min[0];
        var at: usize = 0;
        for (1..l) |i| {
            const diff = @as(i32, nlsf[i]) - (@as(i32, nlsf[i - 1]) + delta_min[i]);
            if (diff < min_diff) {
                min_diff = diff;
                at = i;
            }
        }
        const last = (@as(i32, 1) << 15) - (@as(i32, nlsf[l - 1]) + delta_min[l]);
        if (last < min_diff) {
            min_diff = last;
            at = l;
        }
        if (min_diff >= 0) return;

        if (at == 0) {
            nlsf[0] = delta_min[0];
        } else if (at == l) {
            nlsf[l - 1] = @intCast((@as(i32, 1) << 15) - delta_min[l]);
        } else {
            var min_center: i32 = 0;
            for (0..at) |k| min_center += delta_min[k];
            min_center += delta_min[at] >> 1;
            var max_center: i32 = 1 << 15;
            var k = l;
            while (k > at) : (k -= 1) max_center -= delta_min[k];
            max_center -= delta_min[at] >> 1;
            const center: i16 = @truncate(fix.limit(fix.rshiftRound(@as(i32, nlsf[at - 1]) + nlsf[at], 1), min_center, max_center));
            nlsf[at - 1] = center -% (delta_min[at] >> 1);
            nlsf[at] = nlsf[at - 1] +% delta_min[at];
        }
    }

    // Still too close: sort them and push them apart from both ends.
    for (1..l) |i| {
        const value = nlsf[i];
        var j = i;
        while (j > 0 and value < nlsf[j - 1]) : (j -= 1) nlsf[j] = nlsf[j - 1];
        nlsf[j] = value;
    }
    nlsf[0] = @max(nlsf[0], delta_min[0]);
    for (1..l) |i| nlsf[i] = @max(nlsf[i], fix.sat16(@as(i32, nlsf[i - 1]) + delta_min[i]));
    nlsf[l - 1] = @truncate(@min(@as(i32, nlsf[l - 1]), (@as(i32, 1) << 15) - delta_min[l]));
    var i = l - 1;
    while (i > 0) {
        i -= 1;
        nlsf[i] = @truncate(@min(@as(i32, nlsf[i]), @as(i32, nlsf[i + 1]) - delta_min[i + 1]));
    }
}

const qa = 16;

/// One of the two polynomials: the product of (1 - 2cos(w) z^-1 + z^-2)
/// over every other NLSF.
fn findPoly(out: []i32, c_lsf: []const i32, dd: usize) void {
    out[0] = 1 << qa;
    out[1] = -c_lsf[0];
    for (1..dd) |k| {
        const ftmp: i64 = c_lsf[2 * k];
        out[k + 1] = fix.lshift(out[k - 1], 1) -% @as(i32, @truncate(fix.rshiftRound64(ftmp * out[k], qa)));
        var n = k;
        while (n > 1) : (n -= 1) {
            out[n] +%= out[n - 2] -% @as(i32, @truncate(fix.rshiftRound64(ftmp * out[n - 1], qa)));
        }
        out[1] -%= @intCast(ftmp);
    }
}

/// The LPC coefficients in Q12 of `d` NLSFs in Q15.
pub fn nlsf2a(a_q12: []i16, nlsf: []const i16, d: usize) void {
    const ordering16 = [16]u8{ 0, 15, 8, 7, 4, 11, 12, 3, 2, 13, 10, 5, 6, 9, 14, 1 };
    const ordering10 = [10]u8{ 0, 9, 6, 3, 4, 5, 8, 1, 2, 7 };
    const ordering: []const u8 = if (d == 16) &ordering16 else &ordering10;
    var cos_lsf: [max_order]i32 = undefined;
    for (0..d) |k| {
        const f_int: usize = @intCast(nlsf[k] >> 8);
        const f_frac: i32 = nlsf[k] - @as(i32, @intCast(f_int << 8));
        const cos_val: i32 = tables.lsf_cos_q12[f_int];
        const delta: i32 = tables.lsf_cos_q12[f_int + 1] - cos_val;
        cos_lsf[ordering[k]] = fix.rshiftRound((cos_val << 8) + delta * f_frac, 20 - qa);
    }

    const dd = d / 2;
    var p: [max_order / 2 + 1]i32 = undefined;
    var q: [max_order / 2 + 1]i32 = undefined;
    findPoly(&p, cos_lsf[0..d], dd);
    findPoly(&q, cos_lsf[1..d], dd);

    var a32: [max_order]i32 = undefined;
    for (0..dd) |k| {
        const ptmp = p[k + 1] +% p[k];
        const qtmp = q[k + 1] -% q[k];
        a32[k] = -%qtmp -% ptmp;
        a32[d - k - 1] = qtmp -% ptmp;
    }

    lpcFit(a_q12, a32[0..d], 12, qa + 1);

    var i: u5 = 0;
    while (inversePredGain(a_q12[0..d]) == 0 and i < 16) : (i += 1) {
        bwexpander32(a32[0..d], 65536 - (@as(i32, 2) << i));
        for (0..d) |k| a_q12[k] = @truncate(fix.rshiftRound(a32[k], qa + 1 - 12));
    }
}

/// `a_in` (in Q`qin`) into 16 bits in Q`qout`, expanded until it fits.
fn lpcFit(a_out: []i16, a_in: []i32, comptime qout: u5, comptime qin: u5) void {
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var maxabs: i32 = 0;
        var idx: usize = 0;
        for (a_in, 0..) |v, k| {
            const absval = fix.abs(v);
            if (absval > maxabs) {
                maxabs = absval;
                idx = k;
            }
        }
        maxabs = fix.rshiftRound(maxabs, qin - qout);
        if (maxabs <= 32767) break;
        maxabs = @min(maxabs, 163838);
        const chirp = 65470 - @divTrunc((maxabs - 32767) << 14, (maxabs * @as(i32, @intCast(idx + 1))) >> 2);
        bwexpander32(a_in, chirp);
    }
    if (i == 10) {
        for (a_in, 0..) |*v, k| {
            a_out[k] = fix.sat16(fix.rshiftRound(v.*, qin - qout));
            v.* = @as(i32, a_out[k]) << (qin - qout);
        }
    } else {
        for (a_in, 0..) |v, k| a_out[k] = @truncate(fix.rshiftRound(v, qin - qout));
    }
}

/// Bandwidth expansion of a 16-bit filter: coefficient k times chirp^(k+1).
pub fn bwexpander(ar: []i16, chirp_in: i32) void {
    var chirp = chirp_in;
    const chirp_minus_one = chirp - 65536;
    for (ar[0 .. ar.len - 1]) |*a| {
        a.* = @truncate(fix.rshiftRound(chirp * a.*, 16));
        chirp += fix.rshiftRound(chirp * chirp_minus_one, 16);
    }
    ar[ar.len - 1] = @truncate(fix.rshiftRound(chirp * ar[ar.len - 1], 16));
}

/// The same for a 32-bit filter.
pub fn bwexpander32(ar: []i32, chirp_in: i32) void {
    var chirp = chirp_in;
    const chirp_minus_one = chirp - 65536;
    for (ar[0 .. ar.len - 1]) |*a| {
        a.* = fix.smulww(chirp, a.*);
        chirp += fix.rshiftRound(chirp * chirp_minus_one, 16);
    }
    ar[ar.len - 1] = fix.smulww(chirp, ar[ar.len - 1]);
}

const a_limit: i32 = 16773022; // 0.99975 in Q24
const min_inv_gain_q30: i32 = 107374; // 1 / 1e4

/// The inverse of the filter's prediction gain in Q30, or 0 when it is
/// unstable or the gain is above 40 dB.
pub fn inversePredGain(a_q12: []const i16) i32 {
    var a: [max_order]i32 = undefined;
    var dc_resp: i32 = 0;
    for (a_q12, 0..) |v, k| {
        dc_resp += v;
        a[k] = @as(i32, v) << 12;
    }
    if (dc_resp >= 4096) return 0;

    var inv_gain: i32 = 1 << 30;
    var k = a_q12.len - 1;
    while (k > 0) : (k -= 1) {
        if (a[k] > a_limit or a[k] < -a_limit) return 0;
        const rc_q31 = -(a[k] << 7);
        const rc_mult1 = (@as(i32, 1) << 30) - fix.smmul(rc_q31, rc_q31);
        inv_gain = fix.smmul(inv_gain, rc_mult1) << 2;
        if (inv_gain < min_inv_gain_q30) return 0;
        const mult2q = 32 - fix.clz32(fix.abs(rc_mult1));
        const rc_mult2 = fix.inverse32VarQ(rc_mult1, mult2q + 30);
        for (0..(k + 1) >> 1) |n| {
            const tmp1 = a[n];
            const tmp2 = a[k - n - 1];
            const v1 = fix.rshiftRound64(@as(i64, fix.subSat32(tmp1, mulFracQ31(tmp2, rc_q31))) * rc_mult2, @intCast(mult2q));
            if (v1 > 0x7FFF_FFFF or v1 < -0x8000_0000) return 0;
            a[n] = @intCast(v1);
            const v2 = fix.rshiftRound64(@as(i64, fix.subSat32(tmp2, mulFracQ31(tmp1, rc_q31))) * rc_mult2, @intCast(mult2q));
            if (v2 > 0x7FFF_FFFF or v2 < -0x8000_0000) return 0;
            a[k - n - 1] = @intCast(v2);
        }
    }
    if (a[0] > a_limit or a[0] < -a_limit) return 0;
    const rc_q31 = -(a[0] << 7);
    const rc_mult1 = (@as(i32, 1) << 30) - fix.smmul(rc_q31, rc_q31);
    inv_gain = fix.smmul(inv_gain, rc_mult1) << 2;
    if (inv_gain < min_inv_gain_q30) return 0;
    return inv_gain;
}

inline fn mulFracQ31(a: i32, b: i32) i32 {
    return @truncate(fix.rshiftRound64(@as(i64, a) * b, 31));
}

/// The prediction residual of `in` by the filter `b` (Q12): the first `d`
/// samples have no history and are 0.
pub fn analysisFilter(out: []i16, in: []const i16, b: []const i16, len: usize, d: usize) void {
    for (d..len) |ix| {
        var acc: i32 = 0;
        for (0..d) |j| acc +%= fix.smulbb(in[ix - 1 - j], b[j]);
        acc = (@as(i32, in[ix]) << 12) -% acc;
        out[ix] = fix.sat16(fix.rshiftRound(acc, 12));
    }
    @memset(out[0..d], 0);
}

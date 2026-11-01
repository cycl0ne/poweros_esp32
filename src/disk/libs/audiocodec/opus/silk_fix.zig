// SPDX-License-Identifier: MIT
//! SILK's fixed-point arithmetic: the 32x16 and 32x32 multiplies that keep
//! the top 32 bits, rounding shifts, saturation and the approximations of
//! division, square root and the logarithm the decoder is specified in.
//!
//! The values decoded from a damaged frame may be anything, so the sums
//! wrap as the reference decoder's do rather than trap.

/// (a * b16) >> 16, b taken as its low 16 bits.
pub inline fn smulwb(a: i32, b: i32) i32 {
    return @truncate((@as(i64, a) * @as(i16, @truncate(b))) >> 16);
}

/// a + smulwb(b, c).
pub inline fn smlawb(a: i32, b: i32, c: i32) i32 {
    return @truncate(@as(i64, a) + ((@as(i64, b) * @as(i16, @truncate(c))) >> 16));
}

/// (a * b) >> 16 of two 32-bit numbers.
pub inline fn smulww(a: i32, b: i32) i32 {
    return @truncate((@as(i64, a) * b) >> 16);
}

/// a + smulww(b, c).
pub inline fn smlaww(a: i32, b: i32, c: i32) i32 {
    return @truncate(@as(i64, a) + ((@as(i64, b) * c) >> 16));
}

/// (a * b) >> 32.
pub inline fn smmul(a: i32, b: i32) i32 {
    return @truncate((@as(i64, a) * b) >> 32);
}

/// The low 16 bits of each, multiplied.
pub inline fn smulbb(a: i32, b: i32) i32 {
    return @as(i32, @as(i16, @truncate(a))) * @as(i16, @truncate(b));
}

/// a + smulbb(b, c), wrapping.
pub inline fn smlabb(a: i32, b: i32, c: i32) i32 {
    return a +% smulbb(b, c);
}

/// The top 16 bits of each, multiplied.
pub inline fn smultt(a: i32, b: i32) i32 {
    return (a >> 16) *% (b >> 16);
}

/// a >> shift, rounded.
pub inline fn rshiftRound(a: i32, shift: u5) i32 {
    if (shift == 1) return (a >> 1) + (a & 1);
    return ((a >> (shift - 1)) + 1) >> 1;
}

pub inline fn rshiftRound64(a: i64, shift: u6) i64 {
    if (shift == 1) return (a >> 1) + (a & 1);
    return ((a >> (shift - 1)) + 1) >> 1;
}

/// a << shift, the bits shifted out lost.
pub inline fn lshift(a: i32, shift: u5) i32 {
    return @bitCast(@as(u32, @bitCast(a)) << shift);
}

pub inline fn sat16(a: i32) i16 {
    return @intCast(@max(-32768, @min(32767, a)));
}

pub inline fn addSat32(a: i32, b: i32) i32 {
    return a +| b;
}

pub inline fn subSat32(a: i32, b: i32) i32 {
    return a -| b;
}

/// a << shift, saturated.
pub inline fn lshiftSat32(a: i32, shift: u5) i32 {
    const lo = @as(i32, -2147483648) >> shift;
    const hi = @as(i32, 2147483647) >> shift;
    return lshift(@max(lo, @min(hi, a)), shift);
}

/// a limited to the range the two bounds make, in either order.
pub inline fn limit(a: i32, l1: i32, l2: i32) i32 {
    if (l1 > l2) return if (a > l1) l1 else if (a < l2) l2 else a;
    return if (a > l2) l2 else if (a < l1) l1 else a;
}

pub inline fn abs(a: i32) i32 {
    return if (a > 0) a else -%a;
}

pub inline fn clz32(a: i32) i32 {
    return @clz(@as(u32, @bitCast(a)));
}

/// The leading zeros of `a` and the 7 bits below its leading one.
pub fn clzFrac(a: i32) struct { lz: i32, frac_q7: i32 } {
    const lz = clz32(a);
    const x: u32 = @bitCast(a);
    const rot = 24 - lz;
    const r: u32 = if (rot == 0) x else if (rot < 0) x << @intCast(-rot) | x >> @intCast(32 + rot) else x << @intCast(32 - rot) | x >> @intCast(rot);
    return .{ .lz = lz, .frac_q7 = @intCast(r & 0x7F) };
}

/// The square root, about.
pub fn sqrtApprox(x: i32) i32 {
    if (x <= 0) return 0;
    const f = clzFrac(x);
    var y: i32 = if (f.lz & 1 != 0) 32768 else 46214;
    y >>= @intCast(f.lz >> 1);
    return smlawb(y, y, smulbb(213, f.frac_q7));
}

/// About (a << qres) / b.
pub fn div32VarQ(a: i32, b: i32, qres: i32) i32 {
    const a_headrm = clz32(abs(a)) - 1;
    var a_nrm = lshift(a, @intCast(a_headrm));
    const b_headrm = clz32(abs(b)) - 1;
    const b_nrm = lshift(b, @intCast(b_headrm));
    const b_inv: i32 = @divTrunc(@as(i32, 0x7FFF_FFFF >> 2), b_nrm >> 16);
    var result = smulwb(a_nrm, b_inv);
    a_nrm = a_nrm -% lshift(smmul(b_nrm, result), 3);
    result = smlawb(result, a_nrm, b_inv);
    const shift = 29 + a_headrm - b_headrm - qres;
    if (shift < 0) return lshiftSat32(result, @intCast(-shift));
    if (shift < 32) return result >> @intCast(shift);
    return 0;
}

/// About (1 << qres) / b.
pub fn inverse32VarQ(b: i32, qres: i32) i32 {
    const b_headrm = clz32(abs(b)) - 1;
    const b_nrm = lshift(b, @intCast(b_headrm));
    const b_inv: i32 = @divTrunc(@as(i32, 0x7FFF_FFFF >> 2), b_nrm >> 16);
    var result = lshift(b_inv, 16);
    const err_q32 = lshift((@as(i32, 1) << 29) -% smulwb(b_nrm, b_inv), 3);
    result = smlaww(result, err_q32, b_inv);
    const shift = 61 - b_headrm - qres;
    if (shift <= 0) return lshiftSat32(result, @intCast(-shift));
    if (shift < 32) return result >> @intCast(shift);
    return 0;
}

/// The linear congruential generator the excitation's signs and the
/// concealment's noise come from.
pub inline fn rand(seed: i32) i32 {
    return 907633515 +% seed *% 196314165;
}

/// log2 in Q7, about.
pub fn lin2log(in_lin: i32) i32 {
    const f = clzFrac(in_lin);
    return smlawb(f.frac_q7, f.frac_q7 * (128 - f.frac_q7), 179) + ((31 - f.lz) << 7);
}

/// 2^x of a Q7 number, about.
pub fn log2lin(in_log_q7: i32) i32 {
    if (in_log_q7 < 0) return 0;
    if (in_log_q7 >= 3967) return 0x7FFF_FFFF;
    var out = @as(i32, 1) << @intCast(in_log_q7 >> 7);
    const frac_q7 = in_log_q7 & 0x7F;
    const parabola = smlawb(frac_q7, smulbb(frac_q7, 128 - frac_q7), -174);
    if (in_log_q7 < 2048) {
        out = out + ((out * parabola) >> 7);
    } else {
        out = out + (out >> 7) * parabola;
    }
    return out;
}

/// The energy of `x` and the right shift that keeps it in 32 bits with
/// two to spare.
pub fn sumSqrShift(x: []const i16) struct { energy: i32, shift: u5 } {
    const len: i32 = @intCast(x.len);
    var shift: u5 = @intCast(31 - clz32(len));
    var nrg: u32 = @intCast(len);
    for (0..2) |pass| {
        if (pass == 1) {
            const s = @as(i32, shift) + 3 - clz32(@bitCast(nrg));
            shift = @intCast(@max(0, s));
            nrg = 0;
        }
        var i: usize = 0;
        while (i + 1 < x.len) : (i += 2) {
            var t: u32 = @bitCast(smulbb(x[i], x[i]));
            t +%= @bitCast(smulbb(x[i + 1], x[i + 1]));
            nrg +%= t >> shift;
        }
        if (i < x.len) nrg +%= @as(u32, @bitCast(smulbb(x[i], x[i]))) >> shift;
    }
    return .{ .energy = @bitCast(nrg), .shift = shift };
}

// SPDX-License-Identifier: MIT
//! A warp's division and shears (7.11.3.6 and 7.11.3.7): whether a warp
//! is usable, and the shears its prediction steps by.

const common = @import("common.zig");
const tables = @import("tables.zig");

pub const PREC_BITS = common.WARPEDMODEL_PREC_BITS;
const REDUCE_BITS = 6;
const DIV_LUT_BITS = 8;
const DIV_LUT_PREC_BITS = 14;

pub const Divisor = struct { shift: i32, factor: i32 };

/// resolve_divisor: multiplying by `factor` and shifting right by
/// `shift` divides by `d` (not 0).
pub fn resolveDivisor(d: i64) Divisor {
    const a: u64 = @abs(d);
    const n: u6 = @intCast(63 - @clz(a));
    const e: u64 = a - (@as(u64, 1) << n);
    const f: u64 = if (n > DIV_LUT_BITS)
        (e + (@as(u64, 1) << (n - DIV_LUT_BITS - 1))) >> (n - DIV_LUT_BITS)
    else
        e << (DIV_LUT_BITS - n);
    const lut: i32 = tables.div_lut[@intCast(f)];
    return .{ .shift = @as(i32, n) + DIV_LUT_PREC_BITS, .factor = if (d < 0) -lut else lut };
}

pub const Shear = struct { alpha: i32, beta: i32, gamma: i32, delta: i32, valid: bool };

fn reduce(v: i64) i32 {
    return @intCast(common.round2Signed(v, REDUCE_BITS) << REDUCE_BITS);
}

/// setup_shear.
pub fn setupShear(p: *const [6]i32) Shear {
    const one: i64 = 1 << PREC_BITS;
    const alpha0 = clip(p[2] - one);
    const beta0 = clip(p[3]);
    const div = resolveDivisor(p[2]);
    const v: i64 = @as(i64, p[4]) << PREC_BITS;
    const gamma0 = clip(common.round2Signed(v * div.factor, @intCast(div.shift)));
    const w: i64 = @as(i64, p[3]) * p[4];
    const delta0 = clip(@as(i64, p[5]) - common.round2Signed(w * div.factor, @intCast(div.shift)) - one);
    var s: Shear = .{
        .alpha = reduce(alpha0),
        .beta = reduce(beta0),
        .gamma = reduce(gamma0),
        .delta = reduce(delta0),
        .valid = true,
    };
    if (4 * @as(i64, @abs(s.alpha)) + 7 * @as(i64, @abs(s.beta)) >= one) s.valid = false;
    if (4 * @as(i64, @abs(s.gamma)) + 4 * @as(i64, @abs(s.delta)) >= one) s.valid = false;
    return s;
}

fn clip(v: i64) i64 {
    return @max(-32768, @min(32767, v));
}

// SPDX-License-Identifier: MIT
//! Edwards25519, the curve Ed25519 signs on (RFC 8032): -x^2 + y^2 =
//! 1 + d x^2 y^2 over 2^255 - 19, its points, its scalars modulo the
//! group order L, and the encoding of a point in 32 bytes.
//!
//! A point is kept in extended coordinates (X : Y : Z : T), x = X/Z,
//! y = Y/Z, xy = T/Z. The RFC's addition is complete on this curve, so
//! one sequence serves every pair of points, and a multiplication is a
//! Montgomery ladder over every bit as on the other curves.
//!
//! A point is encoded as y, least significant byte first, with the low
//! bit of x in the top bit; decoding finds x again from the curve's
//! equation by a square root (RFC 8032, 5.1.3).

const field = @import("field.zig");
const Fe25519 = @import("montgomery.zig").Fe25519;
const Fe = Fe25519.Number;

/// The order of the base point: 2^252 + 27742317777372353535851937790883648493.
pub const order = (1 << 252) + 27742317777372353535851937790883648493;
pub const Scalar = field.Field(8, order);

const p = (1 << 255) - 19;
const d_value = 37095705934669439343138083508754565189542113879843219016388785533085940283555;
const d2 = Fe25519.constant((2 * d_value) % p);
const d = Fe25519.constant(d_value);
/// A square root of -1.
const sqrt_minus_one = Fe25519.constant(19681161376707505956807079304988542015446066515923890162744021073123829784752);

pub const Point = struct {
    x: Fe,
    y: Fe,
    z: Fe,
    t: Fe,
};

pub const identity: Point = .{ .x = Fe25519.zero, .y = Fe25519.one, .z = Fe25519.one, .t = Fe25519.zero };

const base_x = 15112221349535400772501151409588531511454012693041857206046113283949847762202;
const base_y = 46316835694926478169428394003475163141307993866256225615783033603165251855960;
pub const base: Point = .{
    .x = Fe25519.constant(base_x),
    .y = Fe25519.constant(base_y),
    .z = Fe25519.one,
    .t = Fe25519.constant((base_x * base_y) % p),
};

/// p + q, complete.
pub fn add(a: *const Point, b: *const Point) Point {
    const y1_x1 = Fe25519.sub(&a.y, &a.x);
    const y2_x2 = Fe25519.sub(&b.y, &b.x);
    const aa = Fe25519.mul(&y1_x1, &y2_x2);
    const y1x1 = Fe25519.add(&a.y, &a.x);
    const y2x2 = Fe25519.add(&b.y, &b.x);
    const bb = Fe25519.mul(&y1x1, &y2x2);
    var cc = Fe25519.mul(&a.t, &d2);
    cc = Fe25519.mul(&cc, &b.t);
    var dd = Fe25519.mul(&a.z, &b.z);
    dd = Fe25519.add(&dd, &dd);
    const e = Fe25519.sub(&bb, &aa);
    const f = Fe25519.sub(&dd, &cc);
    const g = Fe25519.add(&dd, &cc);
    const h = Fe25519.add(&bb, &aa);
    return .{
        .x = Fe25519.mul(&e, &f),
        .y = Fe25519.mul(&g, &h),
        .t = Fe25519.mul(&e, &h),
        .z = Fe25519.mul(&f, &g),
    };
}

/// 2p.
pub fn double(a: *const Point) Point {
    const aa = Fe25519.square(&a.x);
    const bb = Fe25519.square(&a.y);
    var cc = Fe25519.square(&a.z);
    cc = Fe25519.add(&cc, &cc);
    const h = Fe25519.add(&aa, &bb);
    const xy = Fe25519.add(&a.x, &a.y);
    const xy2 = Fe25519.square(&xy);
    const e = Fe25519.sub(&h, &xy2);
    const g = Fe25519.sub(&aa, &bb);
    const f = Fe25519.add(&cc, &g);
    return .{
        .x = Fe25519.mul(&e, &f),
        .y = Fe25519.mul(&g, &h),
        .t = Fe25519.mul(&e, &h),
        .z = Fe25519.mul(&f, &g),
    };
}

pub fn negate(a: *const Point) Point {
    return .{ .x = Fe25519.negate(&a.x), .y = a.y, .z = a.z, .t = Fe25519.negate(&a.t) };
}

fn swapPoints(mask: u32, a: *Point, b: *Point) void {
    Fe25519.swap(mask, &a.x, &b.x);
    Fe25519.swap(mask, &a.y, &b.y);
    Fe25519.swap(mask, &a.z, &b.z);
    Fe25519.swap(mask, &a.t, &b.t);
}

/// k * a, k being 32 bytes, least significant first; every bit costs the
/// same.
pub fn multiply(a: *const Point, k: *const [32]u8) Point {
    var r0 = identity;
    var r1 = a.*;
    var bit: usize = 256;
    while (bit > 0) {
        bit -= 1;
        const set: u32 = (k[bit / 8] >> @intCast(bit % 8)) & 1;
        const mask = 0 -% set;
        swapPoints(mask, &r0, &r1);
        r1 = add(&r0, &r1);
        r0 = double(&r0);
        swapPoints(mask, &r0, &r1);
    }
    return r0;
}

/// Whether two points are the same: X1 Z2 = X2 Z1 and Y1 Z2 = Y2 Z1.
pub fn equal(a: *const Point, b: *const Point) bool {
    const x1 = Fe25519.mul(&a.x, &b.z);
    const x2 = Fe25519.mul(&b.x, &a.z);
    const y1 = Fe25519.mul(&a.y, &b.z);
    const y2 = Fe25519.mul(&b.y, &a.z);
    return Fe25519.equalMask(&x1, &x2) & Fe25519.equalMask(&y1, &y2) != 0;
}

/// A point into its 32 bytes.
pub fn encode(a: *const Point, out: *[32]u8) void {
    const inverse = Fe25519.invert(&a.z);
    const x = Fe25519.mul(&a.x, &inverse);
    const y = Fe25519.mul(&a.y, &inverse);
    Fe25519.toBytesLittle(&y, out);
    var x_bytes: [32]u8 = undefined;
    Fe25519.toBytesLittle(&x, &x_bytes);
    out[31] |= (x_bytes[0] & 1) << 7;
}

/// A point from its 32 bytes; null for a y not below the modulus, or one
/// no point has.
pub fn decode(encoded: *const [32]u8) ?Point {
    var y_bytes = encoded.*;
    const sign = y_bytes[31] >> 7;
    y_bytes[31] &= 127;
    const y = Fe25519.fromBytesLittle(&y_bytes) orelse return null;

    // x^2 = (y^2 - 1) / (d y^2 + 1) = u / v
    const yy = Fe25519.square(&y);
    const u = Fe25519.sub(&yy, &Fe25519.one);
    var v = Fe25519.mul(&d, &yy);
    v = Fe25519.add(&v, &Fe25519.one);

    // x = u v^3 (u v^7)^((p - 5) / 8)
    const v2 = Fe25519.square(&v);
    const v3 = Fe25519.mul(&v2, &v);
    const v7 = Fe25519.mul(&Fe25519.square(&v3), &v);
    const uv7 = Fe25519.mul(&u, &v7);
    const power = Fe25519.powPublic(&uv7, (p - 5) / 8);
    var x = Fe25519.mul(&u, &v3);
    x = Fe25519.mul(&x, &power);

    const vxx = Fe25519.mul(&v, &Fe25519.square(&x));
    if (Fe25519.equalMask(&vxx, &u) == 0) {
        const minus_u = Fe25519.negate(&u);
        if (Fe25519.equalMask(&vxx, &minus_u) == 0) return null;
        x = Fe25519.mul(&x, &sqrt_minus_one);
    }
    var x_bytes: [32]u8 = undefined;
    Fe25519.toBytesLittle(&x, &x_bytes);
    const x_zero = Fe25519.isZeroMask(&x) != 0;
    if (x_zero and sign == 1) return null;
    if ((x_bytes[0] & 1) != sign) x = Fe25519.negate(&x);
    return .{ .x = x, .y = y, .z = Fe25519.one, .t = Fe25519.mul(&x, &y) };
}

/// 64 bytes, least significant first, modulo L, in Montgomery form.
pub fn reduceWide(bytes: *const [64]u8) Scalar.Number {
    var low: Scalar.Number = Scalar.zero;
    var high: Scalar.Number = Scalar.zero;
    for (0..32) |index| {
        low[index / 4] |= @as(u32, bytes[index]) << @intCast(8 * (index % 4));
        high[index / 4] |= @as(u32, bytes[32 + index]) << @intCast(8 * (index % 4));
    }
    const low_m = Scalar.toMontgomery(&low);
    const high_m = Scalar.toMontgomery(&high);
    // high * 2^256, 2^256 being R: its Montgomery form is R^2 mod L.
    const shifted = Scalar.mul(&high_m, &comptime Scalar.constant(1 << 256));
    return Scalar.add(&low_m, &shifted);
}

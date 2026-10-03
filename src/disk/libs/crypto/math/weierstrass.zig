// SPDX-License-Identifier: MIT
//! The NIST curves P-256 and P-384: y^2 = x^3 - 3x + b over a prime
//! field, their points, and multiplying a point by a number.
//!
//! A point is kept projective, (X : Y : Z) for (X/Z, Y/Z), the point at
//! infinity being (0 : 1 : 0). Adding and doubling use the complete
//! formulas for a = -3 (Renes, Costello and Batina, 2015, algorithms 4
//! and 6): one sequence of field operations for every pair of points -
//! equal, opposite, infinity - so a multiplication by a secret number
//! takes the same steps whatever its bits.
//!
//! Multiplication is a Montgomery ladder over every bit of the number:
//! two points R0 and R1 = R0 + P, exchanged by a mask before and after
//! each step, so the work is one addition and one doubling a bit, always.

const field = @import("field.zig");

/// A curve y^2 = x^3 - 3x + b over the field `Fp`, with the generator
/// (gx, gy) of the order `order`.
pub fn Curve(
    comptime Fp: type,
    comptime order: comptime_int,
    comptime b_value: comptime_int,
    comptime gx: comptime_int,
    comptime gy: comptime_int,
) type {
    return struct {
        const Self = @This();
        pub const Field = Fp;
        /// The scalars: numbers modulo the generator's order.
        pub const Scalar = field.Field(Fp.word_count, order);
        pub const Fe = Fp.Number;

        /// The bytes of a coordinate and of a scalar.
        pub const bytes = Fp.byte_count;
        /// An uncompressed point: 04, X, Y.
        pub const point_bytes = 1 + 2 * bytes;

        const b = Fp.constant(b_value);

        pub const Point = struct {
            x: Fe,
            y: Fe,
            z: Fe,
        };

        pub const infinity: Point = .{ .x = Fp.zero, .y = Fp.one, .z = Fp.zero };
        pub const generator: Point = .{ .x = Fp.constant(gx), .y = Fp.constant(gy), .z = Fp.one };

        fn twice(value: *const Fe) Fe {
            return Fp.add(value, value);
        }

        /// p + q, complete: any two points.
        pub fn add(p: *const Point, q: *const Point) Point {
            var t0 = Fp.mul(&p.x, &q.x);
            var t1 = Fp.mul(&p.y, &q.y);
            var t2 = Fp.mul(&p.z, &q.z);
            var t3 = Fp.add(&p.x, &p.y);
            var t4 = Fp.add(&q.x, &q.y);
            t3 = Fp.mul(&t3, &t4);
            t4 = Fp.add(&t0, &t1);
            t3 = Fp.sub(&t3, &t4);
            t4 = Fp.add(&p.y, &p.z);
            var x3 = Fp.add(&q.y, &q.z);
            t4 = Fp.mul(&t4, &x3);
            x3 = Fp.add(&t1, &t2);
            t4 = Fp.sub(&t4, &x3);
            x3 = Fp.add(&p.x, &p.z);
            var y3 = Fp.add(&q.x, &q.z);
            x3 = Fp.mul(&x3, &y3);
            y3 = Fp.add(&t0, &t2);
            y3 = Fp.sub(&x3, &y3);
            var z3 = Fp.mul(&b, &t2);
            x3 = Fp.sub(&y3, &z3);
            z3 = twice(&x3);
            x3 = Fp.add(&x3, &z3);
            z3 = Fp.sub(&t1, &x3);
            x3 = Fp.add(&t1, &x3);
            y3 = Fp.mul(&b, &y3);
            t1 = twice(&t2);
            t2 = Fp.add(&t1, &t2);
            y3 = Fp.sub(&y3, &t2);
            y3 = Fp.sub(&y3, &t0);
            t1 = twice(&y3);
            y3 = Fp.add(&t1, &y3);
            t1 = twice(&t0);
            t0 = Fp.add(&t1, &t0);
            t0 = Fp.sub(&t0, &t2);
            t1 = Fp.mul(&t4, &y3);
            t2 = Fp.mul(&t0, &y3);
            y3 = Fp.mul(&x3, &z3);
            y3 = Fp.add(&y3, &t2);
            x3 = Fp.mul(&t3, &x3);
            x3 = Fp.sub(&x3, &t1);
            z3 = Fp.mul(&t4, &z3);
            t1 = Fp.mul(&t3, &t0);
            z3 = Fp.add(&z3, &t1);
            return .{ .x = x3, .y = y3, .z = z3 };
        }

        /// 2p, complete.
        pub fn double(p: *const Point) Point {
            var t0 = Fp.square(&p.x);
            const t1 = Fp.square(&p.y);
            var t2 = Fp.square(&p.z);
            var t3 = Fp.mul(&p.x, &p.y);
            t3 = twice(&t3);
            var z3 = Fp.mul(&p.x, &p.z);
            z3 = Fp.add(&z3, &z3);
            var y3 = Fp.mul(&b, &t2);
            y3 = Fp.sub(&y3, &z3);
            var x3 = twice(&y3);
            y3 = Fp.add(&x3, &y3);
            x3 = Fp.sub(&t1, &y3);
            y3 = Fp.add(&t1, &y3);
            y3 = Fp.mul(&x3, &y3);
            x3 = Fp.mul(&x3, &t3);
            t3 = twice(&t2);
            t2 = Fp.add(&t2, &t3);
            z3 = Fp.mul(&b, &z3);
            z3 = Fp.sub(&z3, &t2);
            z3 = Fp.sub(&z3, &t0);
            t3 = twice(&z3);
            z3 = Fp.add(&z3, &t3);
            t3 = twice(&t0);
            t0 = Fp.add(&t3, &t0);
            t0 = Fp.sub(&t0, &t2);
            t0 = Fp.mul(&t0, &z3);
            y3 = Fp.add(&y3, &t0);
            t0 = Fp.mul(&p.y, &p.z);
            t0 = twice(&t0);
            z3 = Fp.mul(&t0, &z3);
            x3 = Fp.sub(&x3, &z3);
            z3 = Fp.mul(&t0, &t1);
            z3 = twice(&z3);
            z3 = twice(&z3);
            return .{ .x = x3, .y = y3, .z = z3 };
        }

        fn swapPoints(mask: u32, a: *Point, c: *Point) void {
            Fp.swap(mask, &a.x, &c.x);
            Fp.swap(mask, &a.y, &c.y);
            Fp.swap(mask, &a.z, &c.z);
        }

        /// k * p, k being `bytes` bytes, most significant first; every bit
        /// costs the same.
        pub fn multiply(p: *const Point, k: *const [bytes]u8) Point {
            var r0 = infinity;
            var r1 = p.*;
            var bit: usize = 8 * bytes;
            while (bit > 0) {
                bit -= 1;
                const set: u32 = (k[bytes - 1 - bit / 8] >> @intCast(bit % 8)) & 1;
                const mask = 0 -% set;
                swapPoints(mask, &r0, &r1);
                r1 = add(&r0, &r1);
                r0 = double(&r0);
                swapPoints(mask, &r0, &r1);
            }
            return r0;
        }

        /// k1 * p + k2 * q for public numbers only: one pass over the bits
        /// of both, doubling once a bit and adding p, q or p + q where their
        /// bits say (Shamir's trick) - about half the work of two
        /// multiplications. It branches on the bits, so no secret may go
        /// through it; verifying a signature is what it is for.
        pub fn multiplyTwoPublic(p: *const Point, k1: *const [bytes]u8, q: *const Point, k2: *const [bytes]u8) Point {
            const both = add(p, q);
            var r = infinity;
            var bit: usize = 8 * bytes;
            while (bit > 0) {
                bit -= 1;
                r = double(&r);
                const first = (k1[bytes - 1 - bit / 8] >> @intCast(bit % 8)) & 1 != 0;
                const second = (k2[bytes - 1 - bit / 8] >> @intCast(bit % 8)) & 1 != 0;
                if (first and second) {
                    r = add(&r, &both);
                } else if (first) {
                    r = add(&r, p);
                } else if (second) {
                    r = add(&r, q);
                }
            }
            return r;
        }

        /// Whether a point is the point at infinity.
        pub fn isInfinity(p: *const Point) bool {
            return Fp.isZeroMask(&p.z) != 0;
        }

        /// A point from its uncompressed form, checked to be on the
        /// curve; null for anything else.
        pub fn decode(encoded: []const u8) ?Point {
            if (encoded.len != point_bytes or encoded[0] != 4) return null;
            const x = Fp.fromBytesBig(encoded[1..][0..bytes]) orelse return null;
            const y = Fp.fromBytesBig(encoded[1 + bytes ..][0..bytes]) orelse return null;
            // y^2 = x^3 - 3x + b
            const left = Fp.square(&y);
            var right = Fp.square(&x);
            right = Fp.mul(&right, &x);
            const three_x = Fp.add(&x, &twice(&x));
            right = Fp.sub(&right, &three_x);
            right = Fp.add(&right, &b);
            if (Fp.equalMask(&left, &right) == 0) return null;
            return .{ .x = x, .y = y, .z = Fp.one };
        }

        /// The affine coordinates of a point that is not infinity.
        pub fn affine(p: *const Point, x: *Fe, y: *Fe) void {
            const inverse = Fp.invert(&p.z);
            x.* = Fp.mul(&p.x, &inverse);
            y.* = Fp.mul(&p.y, &inverse);
        }

        /// A point that is not infinity in its uncompressed form.
        pub fn encode(p: *const Point, out: *[point_bytes]u8) void {
            var x: Fe = undefined;
            var y: Fe = undefined;
            affine(p, &x, &y);
            out[0] = 4;
            Fp.toBytesBig(&x, out[1..][0..bytes]);
            Fp.toBytesBig(&y, out[1 + bytes ..][0..bytes]);
        }
    };
}

/// P-256 (secp256r1), FIPS 186-5 and SEC 2.
pub const P256 = Curve(
    field.Field(8, (1 << 256) - (1 << 224) + (1 << 192) + (1 << 96) - 1),
    0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551,
    0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B,
    0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
    0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5,
);

/// P-384 (secp384r1).
pub const P384 = Curve(
    field.Field(12, (1 << 384) - (1 << 128) - (1 << 96) + (1 << 32) - 1),
    0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973,
    0xB3312FA7E23EE7E4988E056BE3F82D19181D9C6EFE8141120314088F5013875AC656398D8A2ED19D2A85C8EDD3EC2AEF,
    0xAA87CA22BE8B05378EB1C71EF320AD746E1D3B628BA79B9859F741E082542A385502F25DBF55296C3A545E3872760AB7,
    0x3617DE4A96262C6F5D9E98BF9292DC29F8F41DBD289A147CE9DA3113B5F0B8C00A60B1CE1D7E819D7A431D7C90EA0E5F,
);

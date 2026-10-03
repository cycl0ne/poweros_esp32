// SPDX-License-Identifier: MIT
//! X25519 (RFC 7748): Diffie-Hellman on Curve25519, by the x-coordinate
//! alone.
//!
//! The scalar is clamped - its three low bits and its top bit cleared,
//! the bit below the top set - and run over the u-coordinate with the
//! RFC's Montgomery ladder: 255 steps, two points exchanged by a mask
//! before each and once at the end, so every scalar costs the same. The
//! field is 2^255 - 19 (`field.zig`).

const field = @import("field.zig");

pub const Fe25519 = field.Field(8, (1 << 255) - 19);
const Fe = Fe25519.Number;

/// (A - 2) / 4 for Curve25519's A = 486662.
const a24 = Fe25519.constant(121665);

/// The u-coordinate of the base point.
pub const base_point: [32]u8 = .{9} ++ [_]u8{0} ** 31;

/// `scalar` times the point whose u-coordinate is `u`, into `out`; all
/// three 32 bytes, least significant first.
pub fn x25519(out: *[32]u8, scalar: *const [32]u8, u: *const [32]u8) void {
    var k = scalar.*;
    k[0] &= 248;
    k[31] &= 127;
    k[31] |= 64;

    // u's top bit is ignored, and a value of the modulus or more taken
    // modulo it: less the modulus once is enough below 2^255.
    var u_bytes = u.*;
    u_bytes[31] &= 127;
    var plain: Fe = Fe25519.zero;
    for (0..32) |index| plain[index / 4] |= @as(u32, u_bytes[index]) << @intCast(8 * (index % 4));
    const x1 = Fe25519.toMontgomery(&plain);

    var x2 = Fe25519.one;
    var z2 = Fe25519.zero;
    var x3 = x1;
    var z3 = Fe25519.one;
    var swapped: u32 = 0;
    var bit: usize = 255;
    while (bit > 0) {
        bit -= 1;
        const set: u32 = (k[bit / 8] >> @intCast(bit % 8)) & 1;
        swapped ^= set;
        const mask = 0 -% swapped;
        Fe25519.swap(mask, &x2, &x3);
        Fe25519.swap(mask, &z2, &z3);
        swapped = set;

        const a = Fe25519.add(&x2, &z2);
        const aa = Fe25519.square(&a);
        const b = Fe25519.sub(&x2, &z2);
        const bb = Fe25519.square(&b);
        const e = Fe25519.sub(&aa, &bb);
        const c = Fe25519.add(&x3, &z3);
        const d = Fe25519.sub(&x3, &z3);
        const da = Fe25519.mul(&d, &a);
        const cb = Fe25519.mul(&c, &b);
        const sum = Fe25519.add(&da, &cb);
        x3 = Fe25519.square(&sum);
        const difference = Fe25519.sub(&da, &cb);
        z3 = Fe25519.square(&difference);
        z3 = Fe25519.mul(&x1, &z3);
        x2 = Fe25519.mul(&aa, &bb);
        const scaled = Fe25519.mul(&a24, &e);
        const inner = Fe25519.add(&aa, &scaled);
        z2 = Fe25519.mul(&e, &inner);
    }
    const mask = 0 -% swapped;
    Fe25519.swap(mask, &x2, &x3);
    Fe25519.swap(mask, &z2, &z3);

    const inverse = Fe25519.invert(&z2);
    const result = Fe25519.mul(&x2, &inverse);
    Fe25519.toBytesLittle(&result, out);
    for (&k) |*byte| @as(*volatile u8, byte).* = 0;
}

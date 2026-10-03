// SPDX-License-Identifier: MIT
//! Host tests of the curve arithmetic under the key agreement and
//! signature calls (`math/`), against Zig's std.crypto on random inputs
//! and against the RFCs' own vectors.

const std = @import("std");
const testing = std.testing;
const weierstrass = @import("../math/weierstrass.zig");
const montgomery = @import("../math/montgomery.zig");
const edwards = @import("../math/edwards.zig");

test {
    _ = @import("../math/field.zig");
}

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

test "X25519: RFC 7748's vectors" {
    var out: [32]u8 = undefined;
    montgomery.x25519(
        &out,
        &hex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
        &hex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"),
    );
    try testing.expectEqualSlices(u8, &hex("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"), &out);
    montgomery.x25519(
        &out,
        &hex("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"),
        &hex("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"),
    );
    try testing.expectEqualSlices(u8, &hex("95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"), &out);
}

test "X25519: random keys agree with std" {
    var random = std.Random.DefaultPrng.init(25519);
    for (0..20) |_| {
        var a: [32]u8 = undefined;
        var b: [32]u8 = undefined;
        random.random().bytes(&a);
        random.random().bytes(&b);
        var a_public: [32]u8 = undefined;
        montgomery.x25519(&a_public, &a, &montgomery.base_point);
        try testing.expectEqualSlices(u8, &(try std.crypto.dh.X25519.recoverPublicKey(a)), &a_public);
        var ours: [32]u8 = undefined;
        montgomery.x25519(&ours, &b, &a_public);
        const theirs = try std.crypto.dh.X25519.scalarmult(b, a_public);
        try testing.expectEqualSlices(u8, &theirs, &ours);
    }
}

fn checkCurve(comptime C: type, comptime Std: type, seed: u64) !void {
    var random = std.Random.DefaultPrng.init(seed);
    for (0..10) |_| {
        var k: [C.bytes]u8 = undefined;
        random.random().bytes(&k);
        k[0] &= 0x7F; // below the order
        const ours = C.multiply(&C.generator, &k);
        var encoded: [C.point_bytes]u8 = undefined;
        C.encode(&ours, &encoded);
        const theirs = try Std.basePoint.mul(k, .big);
        try testing.expectEqualSlices(u8, &theirs.toUncompressedSec1(), &encoded);
        // Decoded and multiplied again: the same as std's.
        const decoded = C.decode(&encoded) orelse return error.NotOnCurve;
        var j: [C.bytes]u8 = undefined;
        random.random().bytes(&j);
        j[0] &= 0x7F;
        var again: [C.point_bytes]u8 = undefined;
        C.encode(&C.multiply(&decoded, &j), &again);
        try testing.expectEqualSlices(u8, &(try theirs.mul(j, .big)).toUncompressedSec1(), &again);
        // A point off the curve is refused.
        encoded[C.point_bytes - 1] ^= 1;
        try testing.expect(C.decode(&encoded) == null);
    }
    // Infinity: the order times the generator.
    var n: [C.bytes]u8 = undefined;
    const plain = C.Scalar.m;
    for (0..C.bytes) |index| n[C.bytes - 1 - index] = @truncate(plain[index / 4] >> @intCast(8 * (index % 4)));
    try testing.expect(C.isInfinity(&C.multiply(&C.generator, &n)));
}

test "P-256 and P-384: multiples of the generator and of other points agree with std" {
    try checkCurve(weierstrass.P256, std.crypto.ecc.P256, 256);
    try checkCurve(weierstrass.P384, std.crypto.ecc.P384, 384);
}

test "Edwards25519: the base point's encoding, and multiples agree with std" {
    var encoded: [32]u8 = undefined;
    edwards.encode(&edwards.base, &encoded);
    try testing.expectEqualSlices(u8, &std.crypto.ecc.Edwards25519.basePoint.toBytes(), &encoded);
    var random = std.Random.DefaultPrng.init(8032);
    for (0..10) |_| {
        var k: [32]u8 = undefined;
        random.random().bytes(&k);
        k[31] &= 0x0F;
        edwards.encode(&edwards.multiply(&edwards.base, &k), &encoded);
        const theirs = try std.crypto.ecc.Edwards25519.basePoint.mul(k);
        try testing.expectEqualSlices(u8, &theirs.toBytes(), &encoded);
        const decoded = edwards.decode(&encoded) orelse return error.NotOnCurve;
        try testing.expect(edwards.equal(&decoded, &edwards.multiply(&edwards.base, &k)));
    }
    // The wide reduction against std's.
    var wide: [64]u8 = undefined;
    random.random().bytes(&wide);
    var ours: [32]u8 = undefined;
    edwards.Scalar.toBytesLittle(&edwards.reduceWide(&wide), &ours);
    try testing.expectEqualSlices(u8, &std.crypto.ecc.Edwards25519.scalar.reduce64(wide), &ours);
}

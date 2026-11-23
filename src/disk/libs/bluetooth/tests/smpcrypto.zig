// SPDX-License-Identifier: MIT
//! Host tests of the security manager's functions against the Bluetooth
//! Core Specification's sample data (its values written here in SMP's
//! order, the least significant byte first) and AES-CMAC against RFC
//! 4493's examples; the debug key's public point; an address resolved.

const std = @import("std");
const smpcrypto = @import("../hci/smpcrypto.zig");
const Port = @import("_port.zig").Port;

const testing = std.testing;

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

test "AES-CMAC gives RFC 4493's tags" {
    var port = Port{};
    const crypto = port.of();
    // The RFC writes key, message and tag the most significant byte
    // first; the function takes them the other way round.
    const key = smpcrypto.reversed(16, &hex("2b7e151628aed2a6abf7158809cf4f3c"));
    const message = hex("6bc1bee22e409f96e93d7e117393172a" ++ "ae2d8a571e03ac9c9eb76fac45af8e51" ++ "30c81c46a35ce411e5fbc1191a0a52ef" ++ "f69f2445df4f9b17ad2b417be66c3710");
    const cases = [_]struct { length: usize, tag: [16]u8 }{
        .{ .length = 0, .tag = hex("bb1d6929e95937287fa37d129b756746") },
        .{ .length = 16, .tag = hex("070a16b46b4d4144f79bdd9dd04a287c") },
        .{ .length = 40, .tag = hex("dfa66747de9ae63030ca32611497c827") },
        .{ .length = 64, .tag = hex("51f0bebf7e3b9d92fc49741779363cfe") },
    };
    for (cases) |case| {
        var reversed_message: [64]u8 = undefined;
        for (0..case.length) |index| reversed_message[case.length - 1 - index] = message[index];
        const tag = smpcrypto.cmac(crypto, &key, reversed_message[0..case.length]);
        try testing.expectEqualSlices(u8, &smpcrypto.reversed(16, &case.tag), &tag);
    }
}

test "c1 and s1 give the specification's confirm and short-term key" {
    var port = Port{};
    const crypto = port.of();
    const k: [16]u8 = @splat(0);
    const r = hex("e02e70c64e2788630e6fad5621d58357");
    const preq = hex("01010000100707");
    const pres = hex("02030000080005");
    const initiator = hex("a6a5a4a3a2a1");
    const responder = hex("b6b5b4b3b2b1");
    const confirm = smpcrypto.c1(crypto, &k, &r, &preq, &pres, 1, &initiator, 0, &responder);
    try testing.expectEqualSlices(u8, &hex("863bf1bec54da7d2ea888987ef3f1e1e"), &confirm);
    var r1: [16]u8 = @splat(0);
    r1[0..8].* = hex("8877665544332211");
    var r2: [16]u8 = @splat(0);
    r2[0..8].* = hex("00ffeeddccbbaa99");
    const stk = smpcrypto.s1(crypto, &k, &r1, &r2);
    try testing.expectEqualSlices(u8, &hex("62a06d79ae16425b9bf4b0e8f0e11f9a"), &stk);
}

const u = hex("e69d350e480103ccdbfdf4ac1191f4efb9a5f9e9a7832c5e2cbe97f2d203b020");
const v = hex("fdc57ff449dd4f6bfb7c9df1c29acb592ae7d4eefbfc0a909abbf6323d8b1855");
const x = hex("abae2b71ecb2ffff3e7377d15484cbd5");
const y = hex("cfc43dfff78365216e5fa725cce7e8a6");
const a1 = hex("cebf3737125600");
const a2 = hex("c1cf2d7013a700");

test "f4, f5, f6 and g2 give the specification's values" {
    var port = Port{};
    const crypto = port.of();
    try testing.expectEqualSlices(u8, &hex("2d8774a9bea1edf11cbda907f116c9f2"), &smpcrypto.f4(crypto, &u, &v, &x, 0));
    const w = hex("98a6bf73f3348d86f166f8b4136b79999b7d390aa610103405adc857a33402ec");
    const keys = smpcrypto.f5(crypto, &w, &x, &y, &a1, &a2);
    try testing.expectEqualSlices(u8, &hex("206e63ce206a3ffd024a08a176f16529"), &keys.mac_key);
    try testing.expectEqualSlices(u8, &hex("380a7594b522059823cdd76911798669"), &keys.ltk);
    const r = hex("c80f2d0cd242da0854bb53b43b34a312");
    const io_cap = hex("020101");
    const check = smpcrypto.f6(crypto, &keys.mac_key, &x, &y, &r, &io_cap, &a1, &a2);
    try testing.expectEqualSlices(u8, &hex("618f95da090b6cd2c5e8d09c9873c4e3"), &check);
    try testing.expectEqual(@as(u32, 0x2f9ed5ba % 1_000_000), smpcrypto.g2(crypto, &u, &v, &x, &y));
}

test "ah gives the specification's hash, and an address made with it resolves" {
    var port = Port{};
    const crypto = port.of();
    const irk = hex("9b7d390aa610103405adc857a33402ec");
    const prand = hex("948170");
    const hash = smpcrypto.ah(crypto, &irk, &prand);
    try testing.expectEqualSlices(u8, &hex("aafb0d"), &hash);
    const address = [6]u8{ hash[0], hash[1], hash[2], prand[0], prand[1], prand[2] };
    try testing.expect(smpcrypto.resolvable(&address));
    try testing.expect(smpcrypto.resolves(crypto, &irk, &address));
    var other = irk;
    other[0] ^= 1;
    try testing.expect(!smpcrypto.resolves(crypto, &other, &address));
    // A static random address is not resolvable.
    try testing.expect(!smpcrypto.resolvable(&[6]u8{ 1, 2, 3, 4, 5, 0xC6 }));
}

test "the debug private key makes the specification's debug public key" {
    const private_key = hex("3f49f6d4a3c55f3874c9b3e3d2103f504aff607beb40b7995899b8a6cd3c1abd");
    var public_key: [64]u8 = undefined;
    try testing.expect(@import("_port.zig").publicOf(&private_key, &public_key));
    var in_smp_order: [64]u8 = undefined;
    in_smp_order[0..32].* = smpcrypto.reversed(32, public_key[0..32]);
    in_smp_order[32..64].* = smpcrypto.reversed(32, public_key[32..64]);
    try testing.expectEqualSlices(u8, &smpcrypto.DEBUG_PUBLIC_KEY, &in_smp_order);
}

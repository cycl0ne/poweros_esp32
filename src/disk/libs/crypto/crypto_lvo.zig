// SPDX-License-Identifier: MIT
//! crypto.library's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time, the
//! slots and the forwarding in the tests at the end.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const crypto = sdk.crypto;
const vec = exec.vec;
const CryptoBase = @import("crypto_base.zig").CryptoBase;
const crypto_init = @import("crypto_init.zig");

const RandomBytes = @import("random/randombytes.zig").RandomBytes;
const InitHash = @import("hash/inithash.zig").InitHash;
const UpdateHash = @import("hash/updatehash.zig").UpdateHash;
const FinishHash = @import("hash/finishhash.zig").FinishHash;
const InitHmac = @import("hmac/inithmac.zig").InitHmac;
const UpdateHmac = @import("hmac/updatehmac.zig").UpdateHmac;
const FinishHmac = @import("hmac/finishhmac.zig").FinishHmac;
const InitCipher = @import("cipher/initcipher.zig").InitCipher;
const UpdateCipher = @import("cipher/updatecipher.zig").UpdateCipher;
const SealGcm = @import("gcm/sealgcm.zig").SealGcm;
const OpenGcm = @import("gcm/opengcm.zig").OpenGcm;
const ModExp = @import("bignum/modexp.zig").ModExp;
const HkdfExtract = @import("kdf/hkdfextract.zig").HkdfExtract;
const HkdfExpand = @import("kdf/hkdfexpand.zig").HkdfExpand;
const MakeKeyPair = @import("curve/makekeypair.zig").MakeKeyPair;
const SharedSecret = @import("curve/sharedsecret.zig").SharedSecret;
const VerifySignature = @import("signature/verifysignature.zig").VerifySignature;
const Sign = @import("signature/sign.zig").Sign;

/// crypto.library's interface, as the SDK generates it from
/// sdk/fd/crypto_lib.fd.
const interface = sdk.interface.crypto;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("crypto.library: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "crypto.library", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("random/randombytes.zig"),
    @embedFile("hash/inithash.zig"),
    @embedFile("hash/updatehash.zig"),
    @embedFile("hash/finishhash.zig"),
    @embedFile("hmac/inithmac.zig"),
    @embedFile("hmac/updatehmac.zig"),
    @embedFile("hmac/finishhmac.zig"),
    @embedFile("cipher/initcipher.zig"),
    @embedFile("cipher/updatecipher.zig"),
    @embedFile("gcm/sealgcm.zig"),
    @embedFile("gcm/opengcm.zig"),
    @embedFile("bignum/modexp.zig"),
    @embedFile("kdf/hkdfextract.zig"),
    @embedFile("kdf/hkdfexpand.zig"),
    @embedFile("curve/makekeypair.zig"),
    @embedFile("curve/sharedsecret.zig"),
    @embedFile("signature/verifysignature.zig"),
    @embedFile("signature/sign.zig"),
};

fn lvoRandomBytes(cb: *CryptoBase, buffer: *anyopaque, length: u32) callconv(.c) void {
    return RandomBytes(cb, buffer, length);
}
fn lvoInitHash(cb: *CryptoBase, context: *crypto.HashContext, algorithm: u32) callconv(.c) i32 {
    return InitHash(cb, context, algorithm);
}
fn lvoUpdateHash(cb: *CryptoBase, context: *crypto.HashContext, data: ?*const anyopaque, length: u32) callconv(.c) void {
    return UpdateHash(cb, context, data, length);
}
fn lvoFinishHash(cb: *CryptoBase, context: *crypto.HashContext, digest: *anyopaque) callconv(.c) u32 {
    return FinishHash(cb, context, digest);
}
fn lvoInitHmac(cb: *CryptoBase, context: *crypto.HmacContext, algorithm: u32, key: ?*const anyopaque, key_length: u32) callconv(.c) i32 {
    return InitHmac(cb, context, algorithm, key, key_length);
}
fn lvoUpdateHmac(cb: *CryptoBase, context: *crypto.HmacContext, data: ?*const anyopaque, length: u32) callconv(.c) void {
    return UpdateHmac(cb, context, data, length);
}
fn lvoFinishHmac(cb: *CryptoBase, context: *crypto.HmacContext, mac: *anyopaque) callconv(.c) u32 {
    return FinishHmac(cb, context, mac);
}
fn lvoInitCipher(cb: *CryptoBase, context: *crypto.CipherContext, mode: u32, key: *const anyopaque, key_length: u32, iv: ?*const anyopaque) callconv(.c) i32 {
    return InitCipher(cb, context, mode, key, key_length, iv);
}
fn lvoUpdateCipher(cb: *CryptoBase, context: *crypto.CipherContext, input: ?*const anyopaque, output: ?*anyopaque, length: u32) callconv(.c) i32 {
    return UpdateCipher(cb, context, input, output, length);
}
fn lvoSealGcm(cb: *CryptoBase, message: *const crypto.GcmMessage) callconv(.c) i32 {
    return SealGcm(cb, message);
}
fn lvoOpenGcm(cb: *CryptoBase, message: *const crypto.GcmMessage) callconv(.c) i32 {
    return OpenGcm(cb, message);
}
fn lvoModExp(cb: *CryptoBase, result: *anyopaque, base_value: *const crypto.Number, exponent: *const crypto.Number, modulus: *const crypto.Number) callconv(.c) i32 {
    return ModExp(cb, result, base_value, exponent, modulus);
}
fn lvoHkdfExtract(cb: *CryptoBase, algorithm: u32, salt: *const crypto.Bytes, material: *const crypto.Bytes, prk: *anyopaque) callconv(.c) i32 {
    return HkdfExtract(cb, algorithm, salt, material, prk);
}
fn lvoHkdfExpand(cb: *CryptoBase, algorithm: u32, prk: *const crypto.Bytes, info: *const crypto.Bytes, output: *anyopaque, length: u32) callconv(.c) i32 {
    return HkdfExpand(cb, algorithm, prk, info, output, length);
}
fn lvoMakeKeyPair(cb: *CryptoBase, curve: u32, private_key: *anyopaque, public_key: *anyopaque, public_length: *u32) callconv(.c) i32 {
    return MakeKeyPair(cb, curve, private_key, public_key, public_length);
}
fn lvoSharedSecret(cb: *CryptoBase, curve: u32, private_key: *const anyopaque, peer: *const crypto.Bytes, secret: *anyopaque) callconv(.c) i32 {
    return SharedSecret(cb, curve, private_key, peer, secret);
}
fn lvoVerifySignature(cb: *CryptoBase, algorithm: u32, key: *const crypto.PublicKey, digest: *const crypto.Bytes, signature: *const crypto.Bytes) callconv(.c) i32 {
    return VerifySignature(cb, algorithm, key, digest, signature);
}
fn lvoSign(cb: *CryptoBase, algorithm: u32, private_key: *const anyopaque, message: *const crypto.Bytes, signature: *anyopaque) callconv(.c) i32 {
    return Sign(cb, algorithm, private_key, message, signature);
}

/// The jump table, in slot order: the standard vectors, then one
/// `lvo<Name>` per `.fd` line.
pub const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(crypto_init.expungeVector),
    vec(exec.libExtFunc),
    vec(lvoRandomBytes),
    vec(lvoInitHash),
    vec(lvoUpdateHash),
    vec(lvoFinishHash),
    vec(lvoInitHmac),
    vec(lvoUpdateHmac),
    vec(lvoFinishHmac),
    vec(lvoInitCipher),
    vec(lvoUpdateCipher),
    vec(lvoSealGcm),
    vec(lvoOpenGcm),
    vec(lvoModExp),
    vec(lvoHkdfExtract),
    vec(lvoHkdfExpand),
    vec(lvoMakeKeyPair),
    vec(lvoSharedSecret),
    vec(lvoVerifySignature),
    vec(lvoSign),
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "the jump table: the standard four, then this library's own" {
    try testing.expectEqual(@as(usize, 4 + @typeInfo(LVO).@"struct".decls.len), vectors.len);
    inline for (@typeInfo(LVO).@"struct".decls) |d| {
        const index: usize = @intCast(@divExact(-@field(LVO, d.name), exec.slot_size) - 1);
        try testing.expectEqual(vec(@field(@This(), "lvo" ++ d.name)), vectors[index]);
    }
}

test "every wrapper hands its parameters on, in order, to the call it is named after" {
    try exec.libraries.checkForwarding(@embedFile("crypto_lvo.zig"), LVO, &.{});
}

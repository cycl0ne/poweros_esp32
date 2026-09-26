// SPDX-License-Identifier: MIT
//! Host tests of crypto.library as a whole: the library made from its
//! ROM tag on the ROM's exec, opened as a program opens it, and spoken to
//! through its jump table. On the host the engines are their software
//! models (`engine/soft_*.zig`), so what is tested here is everything
//! above the engine - the modes, the padding, the chaining, the numbers'
//! set-up - against the standards' own test vectors, and against Zig's
//! std.crypto on inputs of every length and split.

const std = @import("std");
const sdk = @import("sdk");
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const crypto_init = @import("../crypto_init.zig");
const kexec = @import("host_rom").exec;

const testing = std.testing;

test {
    _ = @import("../crypto_lvo.zig");
}

/// exec and the library; the base the tests open is theirs.
const Rig = struct {
    sys: *ExecBase,
    library: *sdk.exec.Library,
    cb: *CryptoBase,

    fn init() !Rig {
        try kexec.setUp();
        const sys = kexec.SysBase.iface();
        const made = kexec.InitResident(kexec.SysBase, &crypto_init.crypto_library_tag, null) orelse return error.NoLibrary;
        const library: *sdk.exec.Library = @ptrCast(@alignCast(made));
        const opened = sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse return error.NoBase;
        return .{ .sys = sys, .library = library, .cb = @ptrCast(opened) };
    }

    /// The library closed and expunged, and nothing left behind.
    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.cb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

// --- hashes -----------------------------------------------------------------

fn digestOf(cb: *CryptoBase, algorithm: u32, data: []const u8) ![]const u8 {
    const Held = struct {
        var digest: [crypto.DIGEST_MAX]u8 = undefined;
    };
    var context: crypto.HashContext = .{};
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.InitHash(&context, algorithm));
    cb.UpdateHash(&context, data.ptr, @intCast(data.len));
    const length = cb.FinishHash(&context, &Held.digest);
    return Held.digest[0..length];
}

test "the FIPS 180 digests of \"abc\"" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    try testing.expectEqualSlices(u8, &hex("a9993e364706816aba3e25717850c26c9cd0d89d"), try digestOf(cb, crypto.HASH_SHA1, "abc"));
    try testing.expectEqualSlices(u8, &hex("23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7"), try digestOf(cb, crypto.HASH_SHA224, "abc"));
    try testing.expectEqualSlices(u8, &hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), try digestOf(cb, crypto.HASH_SHA256, "abc"));
    try testing.expectEqualSlices(u8, &hex("cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"), try digestOf(cb, crypto.HASH_SHA384, "abc"));
    try testing.expectEqualSlices(u8, &hex("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"), try digestOf(cb, crypto.HASH_SHA512, "abc"));
    try testing.expectEqualSlices(u8, &hex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"), try digestOf(cb, crypto.HASH_SHA256, ""));
}

test "every length and every split gives std.crypto's digest" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    var data: [300]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% 3);
    const Pair = struct { algorithm: u32, reference: type };
    const pairs = [_]Pair{
        .{ .algorithm = crypto.HASH_SHA1, .reference = std.crypto.hash.Sha1 },
        .{ .algorithm = crypto.HASH_SHA224, .reference = std.crypto.hash.sha2.Sha224 },
        .{ .algorithm = crypto.HASH_SHA256, .reference = std.crypto.hash.sha2.Sha256 },
        .{ .algorithm = crypto.HASH_SHA384, .reference = std.crypto.hash.sha2.Sha384 },
        .{ .algorithm = crypto.HASH_SHA512, .reference = std.crypto.hash.sha2.Sha512 },
    };
    inline for (pairs) |pair| {
        var length: usize = 0;
        while (length <= data.len) : (length += 1) {
            var expected: [pair.reference.digest_length]u8 = undefined;
            pair.reference.hash(data[0..length], &expected, .{});
            // In three pieces, cut at different places.
            var context: crypto.HashContext = .{};
            _ = cb.InitHash(&context, pair.algorithm);
            const first = length / 3;
            const second = length - length / 5;
            cb.UpdateHash(&context, data[0..].ptr, @intCast(first));
            cb.UpdateHash(&context, data[first..].ptr, @intCast(second - first));
            cb.UpdateHash(&context, data[second..].ptr, @intCast(length - second));
            var digest: [crypto.DIGEST_MAX]u8 = undefined;
            try testing.expectEqual(@as(u32, expected.len), cb.FinishHash(&context, &digest));
            try testing.expectEqualSlices(u8, &expected, digest[0..expected.len]);
        }
    }
}

test "a hash of an unknown algorithm is refused, and takes nothing" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    var context: crypto.HashContext = .{};
    try testing.expectEqual(crypto.CRYPTOERR_ALGORITHM, rig.cb.InitHash(&context, 99));
    rig.cb.UpdateHash(&context, "abc", 3);
    var digest: [crypto.DIGEST_MAX]u8 = undefined;
    try testing.expectEqual(@as(u32, 0), rig.cb.FinishHash(&context, &digest));
}

test "a context whose size is too small is refused, and not written" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    var hash: crypto.HashContext = .{ .size = 16, .algorithm = 77 };
    try testing.expectEqual(crypto.CRYPTOERR_CONTEXT, cb.InitHash(&hash, crypto.HASH_SHA256));
    try testing.expectEqual(@as(u32, 77), hash.algorithm);
    var hmac: crypto.HmacContext = .{ .size = 0 };
    try testing.expectEqual(crypto.CRYPTOERR_CONTEXT, cb.InitHmac(&hmac, crypto.HASH_SHA256, "k", 1));
    var cipher: crypto.CipherContext = .{ .size = @sizeOf(crypto.CipherContext) - 1, .mode = 9 };
    try testing.expectEqual(crypto.CRYPTOERR_CONTEXT, cb.InitCipher(&cipher, crypto.CIPHER_AES_ECB, &@as([16]u8, @splat(0)), 16, null));
    try testing.expectEqual(@as(u32, 9), cipher.mode);
    // A bigger one, as a later SDK would make it, is taken.
    var bigger: crypto.HashContext = .{ .size = @sizeOf(crypto.HashContext) + 64 };
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.InitHash(&bigger, crypto.HASH_SHA256));
    try testing.expectEqual(@as(u32, @sizeOf(crypto.HashContext) + 64), bigger.size);
}

// --- HMAC ---------------------------------------------------------------------

test "RFC 4231's HMAC-SHA-256, and keys of every length as std.crypto has them" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    var context: crypto.HmacContext = .{};
    var mac: [crypto.DIGEST_MAX]u8 = undefined;
    const message = "what do ya want for nothing?";
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.InitHmac(&context, crypto.HASH_SHA256, "Jefe", 4));
    cb.UpdateHmac(&context, message, message.len);
    try testing.expectEqual(@as(u32, 32), cb.FinishHmac(&context, &mac));
    try testing.expectEqualSlices(u8, &hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"), mac[0..32]);

    var key: [200]u8 = undefined;
    for (&key, 0..) |*byte, index| byte.* = @truncate(index *% 13);
    const HmacSha512 = std.crypto.auth.hmac.sha2.HmacSha512;
    for ([_]usize{ 0, 1, 64, 127, 128, 129, 200 }) |key_length| {
        var expected: [HmacSha512.mac_length]u8 = undefined;
        HmacSha512.create(&expected, message, key[0..key_length]);
        _ = cb.InitHmac(&context, crypto.HASH_SHA512, &key, @intCast(key_length));
        cb.UpdateHmac(&context, message[0..10], 10);
        cb.UpdateHmac(&context, message[10..], message.len - 10);
        try testing.expectEqual(@as(u32, 64), cb.FinishHmac(&context, &mac));
        try testing.expectEqualSlices(u8, &expected, &mac);
    }
}

// --- AES ----------------------------------------------------------------------

test "FIPS 197's AES-128 and AES-256 blocks, both ways" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    const plain = hex("00112233445566778899aabbccddeeff");
    const key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    const Case = struct { length: u32, cipher: [16]u8 };
    for ([_]Case{
        .{ .length = 16, .cipher = hex("69c4e0d86a7b0430d8cdb78070b4c55a") },
        .{ .length = 32, .cipher = hex("8ea2b7ca516745bfeafc49904b496089") },
    }) |case| {
        var context: crypto.CipherContext = .{};
        var block = plain;
        try testing.expectEqual(crypto.CRYPTOERR_OK, cb.InitCipher(&context, crypto.CIPHER_AES_ECB, &key, case.length, null));
        try testing.expectEqual(crypto.CRYPTOERR_OK, cb.UpdateCipher(&context, &block, &block, 16));
        try testing.expectEqualSlices(u8, &case.cipher, &block);
        _ = cb.InitCipher(&context, crypto.CIPHER_AES_ECB | crypto.CIPHERF_DECRYPT, &key, case.length, null);
        _ = cb.UpdateCipher(&context, &block, &block, 16);
        try testing.expectEqualSlices(u8, &plain, &block);
    }
}

test "SP 800-38A's CBC and CTR, in pieces, and back" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    const key = hex("2b7e151628aed2a6abf7158809cf4f3c");
    const plain = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51");
    var context: crypto.CipherContext = .{};

    var data = plain;
    _ = cb.InitCipher(&context, crypto.CIPHER_AES_CBC, &key, 16, &hex("000102030405060708090a0b0c0d0e0f"));
    _ = cb.UpdateCipher(&context, &data, &data, 16);
    _ = cb.UpdateCipher(&context, data[16..].ptr, data[16..].ptr, 16);
    try testing.expectEqualSlices(u8, &hex("7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2"), &data);
    _ = cb.InitCipher(&context, crypto.CIPHER_AES_CBC | crypto.CIPHERF_DECRYPT, &key, 16, &hex("000102030405060708090a0b0c0d0e0f"));
    _ = cb.UpdateCipher(&context, &data, &data, 32);
    try testing.expectEqualSlices(u8, &plain, &data);

    data = plain;
    _ = cb.InitCipher(&context, crypto.CIPHER_AES_CTR, &key, 16, &hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"));
    _ = cb.UpdateCipher(&context, &data, &data, 5);
    _ = cb.UpdateCipher(&context, data[5..].ptr, data[5..].ptr, 20);
    _ = cb.UpdateCipher(&context, data[25..].ptr, data[25..].ptr, 7);
    try testing.expectEqualSlices(u8, &hex("874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff"), &data);

    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.UpdateCipher(&context, null, null, 0));
    _ = cb.InitCipher(&context, crypto.CIPHER_AES_CBC, &key, 16, &hex("000102030405060708090a0b0c0d0e0f"));
    try testing.expectEqual(crypto.CRYPTOERR_LENGTH, cb.UpdateCipher(&context, &data, &data, 15));
    try testing.expectEqual(crypto.CRYPTOERR_KEY, cb.InitCipher(&context, crypto.CIPHER_AES_ECB, &key, 24, null));
    try testing.expectEqual(crypto.CRYPTOERR_LENGTH, cb.InitCipher(&context, crypto.CIPHER_AES_CTR, &key, 16, null));
    try testing.expectEqual(crypto.CRYPTOERR_ALGORITHM, cb.InitCipher(&context, 7, &key, 16, null));
    try testing.expectEqual(crypto.CRYPTOERR_ALGORITHM, cb.UpdateCipher(&context, &data, &data, 16));
}

// --- GCM ----------------------------------------------------------------------

test "the GCM paper's test case 4, sealed and opened, and a forgery refused" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    const key = hex("feffe9928665731c6d6a8f9467308308");
    const nonce = hex("cafebabefacedbaddecaf888");
    const aad = hex("feedfacedeadbeeffeedfacedeadbeefabaddad2");
    const plain = hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39");
    const sealed = hex("42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091");
    var data = plain;
    var tag: [crypto.GCM_TAG]u8 = undefined;
    const message: crypto.GcmMessage = .{
        .key = &key,
        .key_length = 16,
        .nonce = &nonce,
        .nonce_length = 12,
        .aad = &aad,
        .aad_length = aad.len,
        .input = &data,
        .output = &data,
        .length = data.len,
        .tag = &tag,
    };
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.SealGcm(&message));
    try testing.expectEqualSlices(u8, &sealed, &data);
    try testing.expectEqualSlices(u8, &hex("5bc94fbc3221a5db94fae95ae7121a47"), &tag);

    tag[3] ^= 1;
    try testing.expectEqual(crypto.CRYPTOERR_TAG, cb.OpenGcm(&message));
    try testing.expectEqualSlices(u8, &sealed, &data);
    tag[3] ^= 1;
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.OpenGcm(&message));
    try testing.expectEqualSlices(u8, &plain, &data);
}

test "GCM of every length as std.crypto has it, and a nonce that is not 12 bytes" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    const Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
    var key: [32]u8 = undefined;
    for (&key, 0..) |*byte, index| byte.* = @truncate(index * 3);
    const nonce = [12]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    var plain: [70]u8 = undefined;
    for (&plain, 0..) |*byte, index| byte.* = @truncate(index * 5);
    const aad = "header";
    for (0..plain.len + 1) |length| {
        var expected: [70]u8 = undefined;
        var expected_tag: [16]u8 = undefined;
        Gcm.encrypt(expected[0..length], &expected_tag, plain[0..length], aad, nonce, key);
        var out: [70]u8 = undefined;
        var tag: [16]u8 = undefined;
        const message: crypto.GcmMessage = .{ .key = &key, .key_length = 32, .nonce = &nonce, .nonce_length = 12, .aad = aad, .aad_length = aad.len, .input = &plain, .output = &out, .length = @intCast(length), .tag = &tag };
        try testing.expectEqual(crypto.CRYPTOERR_OK, cb.SealGcm(&message));
        try testing.expectEqualSlices(u8, expected[0..length], out[0..length]);
        try testing.expectEqualSlices(u8, &expected_tag, &tag);
    }
    // The GCM paper's test case 6: a 60-byte nonce, hashed into J0.
    const key6 = hex("feffe9928665731c6d6a8f9467308308");
    const nonce6 = hex("9313225df88406e555909c5aff5269aa6a7a9538534f7da1e4c303d2a318a728c3c0c95156809539fcf0e2429a6b525416aedbf5a0de6a57a637b39b");
    const aad6 = hex("feedfacedeadbeeffeedfacedeadbeefabaddad2");
    var data6 = hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39");
    var tag6: [16]u8 = undefined;
    const message6: crypto.GcmMessage = .{ .key = &key6, .key_length = 16, .nonce = &nonce6, .nonce_length = nonce6.len, .aad = &aad6, .aad_length = aad6.len, .input = &data6, .output = &data6, .length = data6.len, .tag = &tag6 };
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.SealGcm(&message6));
    try testing.expectEqualSlices(u8, &hex("8ce24998625615b603a033aca13fb894be9112a5c3a211a8ba262a3cca7e2ca701e4a9a4fba43c90ccdcb281d48c7c6fd62875d2aca417034c34aee5"), &data6);
    try testing.expectEqualSlices(u8, &hex("619cc5aefffe0bfa462af43c1699d050"), &tag6);
}

// --- ModExp -------------------------------------------------------------------

test "ModExp: small numbers, a base above the modulus, an exponent of 0, bad moduli" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    var result: [2]u8 = undefined;
    // 4^13 mod 497 = 445.
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.ModExp(&result, &.{ .bytes = &.{4}, .length = 1 }, &.{ .bytes = &.{13}, .length = 1 }, &.{ .bytes = &.{ 1, 0xF1 }, .length = 2 }));
    try testing.expectEqualSlices(u8, &.{ 1, 0xBD }, &result);
    // (497 + 4)^13: the same.
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.ModExp(&result, &.{ .bytes = &.{ 0, 0, 1, 0xF5 }, .length = 4 }, &.{ .bytes = &.{13}, .length = 1 }, &.{ .bytes = &.{ 1, 0xF1 }, .length = 2 }));
    try testing.expectEqualSlices(u8, &.{ 1, 0xBD }, &result);
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.ModExp(&result, &.{ .bytes = &.{7}, .length = 1 }, &.{ .bytes = &.{0}, .length = 1 }, &.{ .bytes = &.{ 1, 0xF1 }, .length = 2 }));
    try testing.expectEqualSlices(u8, &.{ 0, 1 }, &result);
    try testing.expectEqual(crypto.CRYPTOERR_NUMBER, cb.ModExp(&result, &.{ .bytes = &.{7}, .length = 1 }, &.{ .bytes = &.{3}, .length = 1 }, &.{ .bytes = &.{ 1, 0xF0 }, .length = 2 }));
    try testing.expectEqual(crypto.CRYPTOERR_NUMBER, cb.ModExp(&result, &.{ .bytes = &.{7}, .length = 1 }, &.{ .bytes = &.{3}, .length = 1 }, &.{ .bytes = &.{ 0, 1 }, .length = 2 }));
    try testing.expectEqual(crypto.CRYPTOERR_LENGTH, cb.ModExp(&result, &.{ .bytes = &.{7}, .length = 1 }, &.{ .bytes = &.{ 1, 0, 0, 0, 0 }, .length = 5 }, &.{ .bytes = &.{ 1, 0xF1 }, .length = 2 }));
}

test "ModExp on 2048-bit numbers, as std.crypto.ff works them out" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    const M = std.crypto.ff.Modulus(2048);
    var prng = std.Random.DefaultPrng.init(2048);
    const random = prng.random();
    for (0..3) |_| {
        var modulus: [256]u8 = undefined;
        random.bytes(&modulus);
        modulus[0] |= 0x80;
        modulus[255] |= 1;
        var base_value: [256]u8 = undefined;
        random.bytes(&base_value);
        base_value[0] &= 0x7F;
        var exponent: [256]u8 = undefined;
        random.bytes(&exponent);
        const m = try M.fromBytes(&modulus, .big);
        const x = try M.Fe.fromBytes(m, &base_value, .big);
        const expected_fe = try m.powWithEncodedExponent(x, &exponent, .big);
        var expected: [256]u8 = undefined;
        try expected_fe.toBytes(&expected, .big);
        var result: [256]u8 = undefined;
        try testing.expectEqual(crypto.CRYPTOERR_OK, cb.ModExp(&result, &.{ .bytes = &base_value, .length = 256 }, &.{ .bytes = &exponent, .length = 256 }, &.{ .bytes = &modulus, .length = 256 }));
        try testing.expectEqualSlices(u8, &expected, &result);
        // And with 65537, as a signature is checked.
        const public = [_]u8{ 1, 0, 1 };
        const expected_public = try m.powWithEncodedPublicExponent(x, &public, .big);
        try expected_public.toBytes(&expected, .big);
        try testing.expectEqual(crypto.CRYPTOERR_OK, cb.ModExp(&result, &.{ .bytes = &base_value, .length = 256 }, &.{ .bytes = &public, .length = 3 }, &.{ .bytes = &modulus, .length = 256 }));
        try testing.expectEqualSlices(u8, &expected, &result);
    }
}

// --- random ----------------------------------------------------------------

test "RandomBytes fills what it is given, and no more" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    var buffer: [40]u8 = @splat(0xAA);
    rig.cb.RandomBytes(&buffer, 32);
    var differs = false;
    for (buffer[1..32]) |byte| differs = differs or byte != buffer[0];
    try testing.expect(differs);
    for (buffer[32..]) |byte| try testing.expectEqual(@as(u8, 0xAA), byte);
}

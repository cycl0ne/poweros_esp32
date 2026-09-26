// SPDX-License-Identifier: MIT
//! Crypto: crypto.library checked on the machine, against the standards'
//! own test vectors. Built against the SDK only.
//!
//!   Crypto VERBOSE/S
//!
//! Each check runs a known input through the library and compares the
//! answer with the published one: the SHA digests of FIPS 180, a
//! message of several blocks, two hashes interleaved (the engine taking
//! turns between them), RFC 4231's HMAC, FIPS 197's AES blocks both
//! ways, SP 800-38A's CBC and CTR, the GCM paper's test case 4 and a
//! forged tag, and modular exponentiation on 2048-bit numbers. On the
//! chip every one of them goes through the SHA, AES and RSA engines.
//!
//! It prints one line per check that fails (every check, with VERBOSE)
//! and a count at the end; the return code is 0 when all pass, 10 when
//! any fails, 20 when the library cannot be opened.

const sdk = @import("sdk");
const dos = sdk.dos;
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Crypto";
const VERSION_STRING = "\x00$VER: Crypto 1.0 (26.09.2026)\r\n";

const template = "VERBOSE/S";
const arg_verbose = 0;

/// A hex string into its bytes, at compile time.
fn hex(comptime text: []const u8) [text.len / 2]u8 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: [text.len / 2]u8 = undefined;
        for (&out, 0..) |*byte, index| byte.* = nibble(text[2 * index]) << 4 | nibble(text[2 * index + 1]);
        break :blk out;
    };
}

fn nibble(comptime digit: u8) u8 {
    return switch (digit) {
        '0'...'9' => digit - '0',
        'a'...'f' => digit - 'a' + 10,
        else => @compileError("not a hex digit"),
    };
}

/// What a run keeps: where to print, and what passed.
const Run = struct {
    dl: *DosBase,
    cb: *CryptoBase,
    verbose: bool,
    passed: u32 = 0,
    failed: u32 = 0,

    fn check(run: *Run, name: [*:0]const u8, good: bool) void {
        if (good) run.passed += 1 else run.failed += 1;
        if (run.verbose or !good) _ = Printf(run.dl, "%-40s %s\n", .{ name, if (good) "ok" else "FAILED" });
    }
};

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn digestOf(cb: *CryptoBase, algorithm: u32, data: []const u8, digest: *[crypto.DIGEST_MAX]u8) []const u8 {
    var context: crypto.HashContext = .{};
    if (cb.InitHash(&context, algorithm) != crypto.CRYPTOERR_OK) return digest[0..0];
    cb.UpdateHash(&context, data.ptr, @intCast(data.len));
    return digest[0..cb.FinishHash(&context, digest)];
}

fn hashes(run: *Run) void {
    const Case = struct { name: [*:0]const u8, algorithm: u32, expected: []const u8 };
    const cases = [_]Case{
        .{ .name = "SHA-1 \"abc\"", .algorithm = crypto.HASH_SHA1, .expected = &hex("a9993e364706816aba3e25717850c26c9cd0d89d") },
        .{ .name = "SHA-224 \"abc\"", .algorithm = crypto.HASH_SHA224, .expected = &hex("23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7") },
        .{ .name = "SHA-256 \"abc\"", .algorithm = crypto.HASH_SHA256, .expected = &hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") },
        .{ .name = "SHA-384 \"abc\"", .algorithm = crypto.HASH_SHA384, .expected = &hex("cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7") },
        .{ .name = "SHA-512 \"abc\"", .algorithm = crypto.HASH_SHA512, .expected = &hex("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f") },
    };
    var digest: [crypto.DIGEST_MAX]u8 = undefined;
    for (cases) |case| run.check(case.name, same(digestOf(run.cb, case.algorithm, "abc", &digest), case.expected));

    const long = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    const long_expected = hex("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    run.check("SHA-256, two blocks", same(digestOf(run.cb, crypto.HASH_SHA256, long, &digest), &long_expected));

    // Two hashes in turn, a byte at a time: each has to get its own state
    // back from the engine every time.
    var first: crypto.HashContext = .{};
    var second: crypto.HashContext = .{};
    _ = run.cb.InitHash(&first, crypto.HASH_SHA256);
    _ = run.cb.InitHash(&second, crypto.HASH_SHA512);
    var copies: u32 = 0;
    while (copies < 20) : (copies += 1) {
        for (long) |byte| {
            run.cb.UpdateHash(&first, &byte, 1);
            run.cb.UpdateHash(&second, &byte, 1);
        }
    }
    var many: [20 * long.len]u8 = undefined;
    for (0..20) |copy| @memcpy(many[copy * long.len ..][0..long.len], long);
    var expected: [crypto.DIGEST_MAX]u8 = undefined;
    const want_first = digestOf(run.cb, crypto.HASH_SHA256, &many, &expected);
    var got: [crypto.DIGEST_MAX]u8 = undefined;
    const got_first = run.cb.FinishHash(&first, &got);
    run.check("SHA-256 and SHA-512 interleaved (256)", same(got[0..got_first], want_first));
    const want_second = digestOf(run.cb, crypto.HASH_SHA512, &many, &expected);
    const got_second = run.cb.FinishHash(&second, &got);
    run.check("SHA-256 and SHA-512 interleaved (512)", same(got[0..got_second], want_second));
}

fn hmac(run: *Run) void {
    var context: crypto.HmacContext = .{};
    var mac: [crypto.DIGEST_MAX]u8 = undefined;
    const message = "what do ya want for nothing?";
    _ = run.cb.InitHmac(&context, crypto.HASH_SHA256, "Jefe", 4);
    run.cb.UpdateHmac(&context, message, message.len);
    const length = run.cb.FinishHmac(&context, &mac);
    run.check("HMAC-SHA-256 (RFC 4231 case 2)", same(mac[0..length], &hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")));
    _ = run.cb.InitHmac(&context, crypto.HASH_SHA512, "Jefe", 4);
    run.cb.UpdateHmac(&context, message, message.len);
    const length512 = run.cb.FinishHmac(&context, &mac);
    run.check("HMAC-SHA-512 (RFC 4231 case 2)", same(mac[0..length512], &hex("164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737")));
}

fn aes(run: *Run) void {
    const cb = run.cb;
    const plain = hex("00112233445566778899aabbccddeeff");
    const key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    var context: crypto.CipherContext = .{};
    var block = plain;
    _ = cb.InitCipher(&context, crypto.CIPHER_AES_ECB, &key, 16, null);
    _ = cb.UpdateCipher(&context, &block, &block, 16);
    run.check("AES-128 encrypt (FIPS 197 C.1)", same(&block, &hex("69c4e0d86a7b0430d8cdb78070b4c55a")));
    _ = cb.InitCipher(&context, crypto.CIPHER_AES_ECB | crypto.CIPHERF_DECRYPT, &key, 16, null);
    _ = cb.UpdateCipher(&context, &block, &block, 16);
    run.check("AES-128 decrypt (FIPS 197 C.1)", same(&block, &plain));
    _ = cb.InitCipher(&context, crypto.CIPHER_AES_ECB, &key, 32, null);
    _ = cb.UpdateCipher(&context, &block, &block, 16);
    run.check("AES-256 encrypt (FIPS 197 C.3)", same(&block, &hex("8ea2b7ca516745bfeafc49904b496089")));
    _ = cb.InitCipher(&context, crypto.CIPHER_AES_ECB | crypto.CIPHERF_DECRYPT, &key, 32, null);
    _ = cb.UpdateCipher(&context, &block, &block, 16);
    run.check("AES-256 decrypt (FIPS 197 C.3)", same(&block, &plain));

    const key2 = hex("2b7e151628aed2a6abf7158809cf4f3c");
    const text = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51");
    const iv = hex("000102030405060708090a0b0c0d0e0f");
    var data = text;
    _ = cb.InitCipher(&context, crypto.CIPHER_AES_CBC, &key2, 16, &iv);
    _ = cb.UpdateCipher(&context, &data, &data, 32);
    run.check("AES-128-CBC encrypt (SP 800-38A)", same(&data, &hex("7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2")));
    _ = cb.InitCipher(&context, crypto.CIPHER_AES_CBC | crypto.CIPHERF_DECRYPT, &key2, 16, &iv);
    _ = cb.UpdateCipher(&context, &data, &data, 32);
    run.check("AES-128-CBC decrypt (SP 800-38A)", same(&data, &text));
    _ = cb.InitCipher(&context, crypto.CIPHER_AES_CTR, &key2, 16, &hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"));
    _ = cb.UpdateCipher(&context, &data, &data, 7);
    _ = cb.UpdateCipher(&context, data[7..].ptr, data[7..].ptr, 25);
    run.check("AES-128-CTR, in two pieces (SP 800-38A)", same(&data, &hex("874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff")));
}

fn gcm(run: *Run) void {
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
    const sealed_ok = run.cb.SealGcm(&message) == crypto.CRYPTOERR_OK;
    run.check("AES-128-GCM seal (GCM test case 4)", sealed_ok and same(&data, &sealed) and same(&tag, &hex("5bc94fbc3221a5db94fae95ae7121a47")));
    tag[0] ^= 0x80;
    run.check("AES-128-GCM, a forged tag refused", run.cb.OpenGcm(&message) == crypto.CRYPTOERR_TAG and same(&data, &sealed));
    tag[0] ^= 0x80;
    run.check("AES-128-GCM open (GCM test case 4)", run.cb.OpenGcm(&message) == crypto.CRYPTOERR_OK and same(&data, &plain));
}

fn modexp(run: *Run) void {
    var result: [256]u8 = undefined;
    var small: [2]u8 = undefined;
    const ok = run.cb.ModExp(&small, &.{ .bytes = &.{4}, .length = 1 }, &.{ .bytes = &.{13}, .length = 1 }, &.{ .bytes = &.{ 1, 0xF1 }, .length = 2 });
    run.check("4 ^ 13 mod 497", ok == crypto.CRYPTOERR_OK and same(&small, &.{ 1, 0xBD }));
    const n: crypto.Number = .{ .bytes = &modulus, .length = modulus.len };
    const x: crypto.Number = .{ .bytes = &base_value, .length = base_value.len };
    const d: crypto.Number = .{ .bytes = &exponent, .length = exponent.len };
    const e: crypto.Number = .{ .bytes = &.{ 1, 0, 1 }, .length = 3 };
    const private = run.cb.ModExp(&result, &x, &d, &n);
    run.check("2048 bits, a 2048-bit exponent", private == crypto.CRYPTOERR_OK and same(&result, &x_to_d));
    const public = run.cb.ModExp(&result, &x, &e, &n);
    run.check("2048 bits, exponent 65537", public == crypto.CRYPTOERR_OK and same(&result, &x_to_e));
}

// 2048-bit numbers and their powers, worked out elsewhere (Python's pow).
const modulus = hex(
    "cda2faee37fde78077e727a659c1d5f13f2f4b1c2a1514a1a5bb9b9513484759f810275038ba38921986dc545665baec" ++
        "50055f2d362b25380468305b93ae8aa48665a1af3a8062ef2ab40e89cb47b093c568a88357f25bc55eda1385d6c80e0f" ++
        "9f98f6698655b6f5054a1f1202bb571120d2aba47f4c4f0e236d82a231e23e211a6e2ac4464405df4c6bad86b4eb01a1" ++
        "f0d23a5c014148b2c6ebee1da65f5b0116c00de1438feba5c5cff0f58c27b70ad2eba7494a8a828505deceee19192895" ++
        "0b6a22a6acfd341d5f340e190d50d6110b6c6241833285719c39ea664e3c93c30e47c10ca3294f65861e74ace4869e25" ++
        "a13c733515a10cefbd4622c621d91a6f",
);
const base_value = hex(
    "0236f61818593d49a26f35ac3d8e4185b8b10bf3734dcaaeb4e399aac6ac1c255b8d9244c67160c8aebd0df0b54d6a01" ++
        "15a58bfda6ee610e8584d10a1096cfde1b51648eb1bbc6ff79f7b5c7a15f9ceab712b723610fa8a43b964475671718aa" ++
        "627b3fd49e5c429e3e3a1d2f80cab304c579f54202f7a157e768330c94d424dd804e351f07a57c5059ca7459872eb227" ++
        "61cc2d596cda04bc8acf2a614336f912c82c53f68857f840b535c61e6c0ebca0d11b643cf6429585e535516bde37e238" ++
        "ab9f6ae35691752b6f1f356738f360696a1f30427a169d3c79a7e9d1765120b9c2f19125ec5cffabab5b5b1aec9ed79e" ++
        "59a0930e00ceac5fe6091ed0f23254ff",
);
const exponent = hex(
    "ecb2306ec37d4cef6052b26279adbb6b658b79d2600f063ebd0d11252c2aa0103b08b7ec11066a15d5887dcf9e99d6fa" ++
        "7aceddc7310f8f3ef5bddf24b1db6fff31be147883aa6128b4e1d37ce0bb850c4a8f1f07cd737afcceead361c0b94fcf" ++
        "c3a180c053c2353228410be2c7338ea058665655eb124ed039c6a4aab72ba948cd7aa750f6e749628c9a3bd64dddd382" ++
        "1095cf489b2d3fbbb89cc0ae2343d7052d60d4c62547f5f213b746371424a0ba4e59dc58fe5255d9360d90de84a078ad" ++
        "1822598d9ffd1c3cbd895d81ce0fee0c345ddbe8b34fb083eb323d059f4dc7a1d3db60131195bd61388993fb7adb0f8c" ++
        "eada21900f04592ce4be05d4f87206d3",
);
const x_to_d = hex(
    "1aef2b32c6d244d5bdfe2687ef107bafa869e78cf5a1ca84d187dee63702eb4d9edbbaea2ecb6fac53f8caca7a7f198f" ++
        "ca23d28e02738493f72844508eeafd70987c60373dbb12e2d68c054f43f5ffe26a5d7db7d56f85f0c5810ffea5c74664" ++
        "0c80ecf137fc1e5f711ecfdb12e709875264c4b66ced9c557b505cc387fa3231fe68af18bed60cc5c830c0628bb4b5b2" ++
        "956482612c1a3810e0d159b5fe8094456ca27d6519bbc9e926f89f23f0c762e17420d69e0f8ad692b04fc7940c96433c" ++
        "52fcba98ba6329456527d8cc9ec6443a66f757b0c231c397f8230c8fdbc670e6386a07e3c9805190f94b6ab1f87e8711" ++
        "80fd260eb4b786fd03c936d2001baa58",
);
const x_to_e = hex(
    "3f0d34ff82ac99b68ef338b5a78ec39239a3975f6640d9ad7fad8ca7cb0adf7b288fcedcb16eb6426fbc6554703d6261" ++
        "d8ab8bf9b62c59151a92d91060f4a9ef63d37b0c3b6f82713e4ba4f96199cf5ecf746fdd09faa178a68df65d25ff2c86" ++
        "72b054c39114096b5075904fca85fbad6171d586fa7e127cd7bae92752baf6a6469805e3fc54a48242cf4cffdea6116c" ++
        "cf6a330755645aea02bd532988f1737f2aad565933e19500c60082788e7d2d96df7299018bab180dfed90807892d4fe4" ++
        "df51a282e7f9d16a73ef41f6fd63cafc0832d53df90c966a7d438bde6d9dfa0f0e529562f8775d1c59e655c3b2c96734" ++
        "84f0f79413e81d69a9fa571dde9ed822",
);

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const crypto_lib = sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse {
        _ = Printf(dl, "%s: cannot open %s\n", .{ COMMAND_NAME, crypto.CRYPTONAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(crypto_lib);

    var run: Run = .{ .dl = dl, .cb = @ptrCast(crypto_lib), .verbose = argv[arg_verbose] != 0 };
    hashes(&run);
    hmac(&run);
    aes(&run);
    gcm(&run);
    modexp(&run);
    _ = Printf(dl, "%s: %u passed, %u failed\n", .{ COMMAND_NAME, run.passed, run.failed });
    return if (run.failed == 0) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// The "$VER:" string, which `Version <file>` looks for. Nothing refers to
/// it, so it needs an export and a section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

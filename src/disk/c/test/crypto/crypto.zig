// SPDX-License-Identifier: MIT
//! Crypto: crypto.library checked on the machine, against the standards'
//! own test vectors. Built against the SDK only.
//!
//!   Crypto VERBOSE/S,BENCH/S,RANDOM/S
//!
//! Each check runs a known input through the library and compares the
//! answer with the published one: the SHA digests of FIPS 180, a
//! message of several blocks, two hashes interleaved (the engine taking
//! turns between them), RFC 4231's HMAC, FIPS 197's AES blocks both
//! ways, SP 800-38A's CBC and CTR, the GCM paper's test case 4 and a
//! forged tag, modular exponentiation on 2048-bit numbers, RFC 5869's
//! HKDF, RFC 7748's X25519, RFC 8032's Ed25519, key agreement on P-256
//! and P-384, and an ECDSA and an RSA-PSS signature openssl made. On the
//! chip the hashes, AES and the exponentiations go through the SHA, AES
//! and RSA engines; the curves are software.
//!
//! It prints one line per check that fails (every check, with VERBOSE)
//! and a count at the end; the return code is 0 when all pass, 10 when
//! any fails, 20 when the library cannot be opened.
//!
//! BENCH times each kind of work after the checks - a key pair, a shared
//! secret, a signature checked, AES-GCM and SHA-256 in bulk - in
//! milliseconds an operation or kilobytes a second, on dos's clock.
//! RANDOM puts 20000 bits of RandomBytes through FIPS 140-2's monobit,
//! poker and long-run tests.

const sdk = @import("sdk");
const dos = sdk.dos;
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Crypto";
const VERSION_STRING = "\x00$VER: Crypto 1.1 (03.10.2026)\r\n";

const template = "VERBOSE/S,BENCH/S,RANDOM/S";
const arg_verbose = 0;
const arg_bench = 1;
const arg_random = 2;

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

// --- 1.1: key derivation, agreement and signatures -----------------------------

fn keys(run: *Run) void {
    const cb = run.cb;
    const Bytes = crypto.Bytes;
    const ikm: [22]u8 = @splat(0x0b);
    var prk: [32]u8 = undefined;
    _ = cb.HkdfExtract(crypto.HASH_SHA256, &Bytes.of(&hex("000102030405060708090a0b0c")), &Bytes.of(&ikm), &prk);
    var okm: [42]u8 = undefined;
    _ = cb.HkdfExpand(crypto.HASH_SHA256, &Bytes.of(&prk), &Bytes.of(&hex("f0f1f2f3f4f5f6f7f8f9")), &okm, okm.len);
    run.check("HKDF-SHA256 (RFC 5869, case 1)", same(&prk, &hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")) and
        same(&okm, &hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")));

    var secret: [crypto.CURVE_SECRET_MAX]u8 = undefined;
    const x_ok = cb.SharedSecret(crypto.CURVE_X25519, &hex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"), &Bytes.of(&hex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")), &secret);
    run.check("X25519 (RFC 7748)", x_ok == crypto.CRYPTOERR_OK and same(secret[0..32], &hex("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")));

    for ([_]u32{ crypto.CURVE_X25519, crypto.CURVE_P256, crypto.CURVE_P384 }) |curve| {
        var a_private: [crypto.CURVE_PRIVATE_MAX]u8 = undefined;
        var b_private: [crypto.CURVE_PRIVATE_MAX]u8 = undefined;
        var a_public: [crypto.CURVE_PUBLIC_MAX]u8 = undefined;
        var b_public: [crypto.CURVE_PUBLIC_MAX]u8 = undefined;
        var a_length: u32 = 0;
        var b_length: u32 = 0;
        _ = cb.MakeKeyPair(curve, &a_private, &a_public, &a_length);
        _ = cb.MakeKeyPair(curve, &b_private, &b_public, &b_length);
        var other: [crypto.CURVE_SECRET_MAX]u8 = undefined;
        const one = cb.SharedSecret(curve, &a_private, &Bytes.of(b_public[0..b_length]), &secret);
        const two = cb.SharedSecret(curve, &b_private, &Bytes.of(a_public[0..a_length]), &other);
        const length = crypto.secretLength(curve);
        const name: [*:0]const u8 = switch (curve) {
            crypto.CURVE_X25519 => "X25519, two key pairs agree",
            crypto.CURVE_P256 => "P-256, two key pairs agree",
            else => "P-384, two key pairs agree",
        };
        run.check(name, one == crypto.CRYPTOERR_OK and two == crypto.CRYPTOERR_OK and same(secret[0..length], other[0..length]));
    }
}

fn signatures(run: *Run) void {
    const cb = run.cb;
    const Bytes = crypto.Bytes;
    const seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    const ed_key: crypto.PublicKey = .{ .point = Bytes.of(&hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")) };
    var signature: [crypto.SIGNATURE_ED25519]u8 = undefined;
    _ = cb.Sign(crypto.SIG_ED25519, &seed, &Bytes.of(""), &signature);
    run.check("Ed25519 sign (RFC 8032, test 1)", same(&signature, &hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")));
    run.check("Ed25519 verify", cb.VerifySignature(crypto.SIG_ED25519, &ed_key, &Bytes.of(""), &Bytes.of(&signature)) == crypto.CRYPTOERR_OK);
    signature[10] ^= 1;
    run.check("Ed25519, a changed signature refused", cb.VerifySignature(crypto.SIG_ED25519, &ed_key, &Bytes.of(""), &Bytes.of(&signature)) == crypto.CRYPTOERR_SIGNATURE);

    const ec_key: crypto.PublicKey = .{ .point = Bytes.of(&ecdsa_point) };
    run.check("ECDSA P-256 (openssl's)", cb.VerifySignature(crypto.SIG_ECDSA_P256, &ec_key, &Bytes.of(&signed_digest), &Bytes.of(&ecdsa_signature)) == crypto.CRYPTOERR_OK);
    var other = signed_digest;
    other[0] ^= 1;
    run.check("ECDSA P-256, another digest refused", cb.VerifySignature(crypto.SIG_ECDSA_P256, &ec_key, &Bytes.of(&other), &Bytes.of(&ecdsa_signature)) == crypto.CRYPTOERR_SIGNATURE);

    const rsa_key: crypto.PublicKey = .{ .modulus = Bytes.of(&rsa_modulus), .exponent = Bytes.of(&.{ 1, 0, 1 }) };
    run.check("RSA-PSS SHA-256, 2048 bits (openssl's)", cb.VerifySignature(crypto.SIG_RSA_PSS_SHA256, &rsa_key, &Bytes.of(&signed_digest), &Bytes.of(&pss_signature)) == crypto.CRYPTOERR_OK);
    run.check("RSA-PSS, another digest refused", cb.VerifySignature(crypto.SIG_RSA_PSS_SHA256, &rsa_key, &Bytes.of(&other), &Bytes.of(&pss_signature)) == crypto.CRYPTOERR_SIGNATURE);
}

// "PowerOS signs this", its SHA-256, and what openssl signed it with.
const signed_digest = hex("c78dcb0b4b4cfdb7fe948ceb1a8231a1e11a954c3a64309a4ec367757f8e5a63");
const ecdsa_point = hex(
    "042afcbb27c294ef111d07c96a8317c106ed7bf2660e1f687461fda0e3de5f7e6733c7e04fbb259155f6ec8cb9c1e446" ++
        "f88128d4e4893da099c36ef507ed3391dc",
);
const ecdsa_signature = hex(
    "30460221008ee163fb85c2969dde4ac4ad7f2e40d2f2e96ee5f003d028c613dbfd9d7aa56d022100e4405bfaa20cdcab" ++
        "e7b69a2f9d1b918fe5e81c22dee50cdc715ce3404aa47724",
);
const rsa_modulus = hex(
    "b12d6146163f0d87843905ed07b3bf4469e76ebd22b537f6b9e3c667324ad8dcb91f810d78256f846dcb22b46b2241d2" ++
        "64f335676044435cb8a2b81c5854673b48b606c622ef4c095ff2362adc128cec4750e0b2f09a6ca974f9f11aeee29213" ++
        "52bcf7126fb46c6b9f9bc551637efc327cd1ebc9e7b8b18724afc8d7172793e5e9732822a38437288438c3a6d771fe47" ++
        "f97e01be2fbdf6bf4eb114e36545a5db11470deefcac8ed29dbff9ff5fb496eaa124f9a03de9558894b467b2d6954fc4" ++
        "ada915e07d579bdc494cc77e920ede82f0be04bc10b8154b00cb6bc1e2446d9b37b2f6640d9e8f8edfb5cd7797949b89" ++
        "4995bfb85155bb57599f0f4ebe96037d",
);
const pss_signature = hex(
    "831c2e1fd54a20ad3b853b1b0e81e698d14733dc2bc2e69980d2a37e9ea522c476ecc859b6765e23e29cac43a9554cef" ++
        "519ad955d855e3ec74768d6b3c567f701f748793017133399a046b5b90ea9ad937759d2c858a118dacc727fc0fd5311e" ++
        "36b12d7e595a27377f56a399d8884d51f0798d4eb886f916cf3f7cf679fb749e394bf1e999e296a191570913fdff4043" ++
        "51eabecfe650bef972e8ae719d02e1974bad0d87e7fc7dffd15e85c170713c9a326a852a6876e46a2e6d825eeb1a9173" ++
        "f706fce6419c5cfce91e51813c0c2879028b8a1a72e9c9a17e1ea358e0736a77c05b26177f3f86734f6dc7bdbcd801ce" ++
        "4a22d7afbb608f895ec1e79a35459ee5",
);

// --- RANDOM: the generator's bits --------------------------------------------

/// FIPS 140-2's tests over 20000 bits: monobit (9725 to 10275 ones),
/// poker (2.16 < X < 46.17 over 4-bit nibbles) and long runs (none of 26
/// or more).
fn random(run: *Run) void {
    var bits: [2500]u8 = undefined;
    run.cb.RandomBytes(&bits, bits.len);
    var ones: u32 = 0;
    var nibbles: [16]u32 = @splat(0);
    var longest: u32 = 0;
    var current: u32 = 0;
    var last: u8 = 2;
    for (bits) |byte| {
        ones += @popCount(byte);
        nibbles[byte >> 4] += 1;
        nibbles[byte & 15] += 1;
        for (0..8) |index| {
            const bit: u8 = (byte >> @intCast(7 - index)) & 1;
            current = if (bit == last) current + 1 else 1;
            last = bit;
            longest = @max(longest, current);
        }
    }
    var squares: u64 = 0;
    for (nibbles) |count| squares += @as(u64, count) * count;
    // 16/5000 * squares - 5000 between 2.16 and 46.17, in integers.
    const poker = 16 * squares;
    _ = Printf(run.dl, "RandomBytes: %u ones in 20000 bits, nibble squares %ld, longest run %u\n", .{ ones, squares, longest });
    run.check("RNG monobit (FIPS 140-2)", ones > 9725 and ones < 10275);
    run.check("RNG poker (FIPS 140-2)", poker > 25_010_800 and poker < 25_230_850);
    run.check("RNG long runs (FIPS 140-2)", longest < 26);
}

// --- BENCH: how long the work takes -------------------------------------------

/// Milliseconds on dos's clock, to a fiftieth of a second.
fn millis(dl: *DosBase) u64 {
    var stamp: dos.DateStamp = .{};
    _ = dl.DateStamp(&stamp);
    const minutes: u64 = @as(u64, @intCast(stamp.days)) * 1440 + @as(u64, @intCast(stamp.minute));
    return minutes * 60_000 + @as(u64, @intCast(stamp.tick)) * 20;
}

fn report(run: *Run, name: [*:0]const u8, started: u64, count: u32) void {
    const elapsed = millis(run.dl) - started;
    _ = Printf(run.dl, "%-34s %ld ms each (%u in %ld ms)\n", .{ name, elapsed / count, count, elapsed });
}

fn bench(run: *Run) void {
    const cb = run.cb;
    const Bytes = crypto.Bytes;
    var private_key: [crypto.CURVE_PRIVATE_MAX]u8 = undefined;
    var public_key: [crypto.CURVE_PUBLIC_MAX]u8 = undefined;
    var length: u32 = 0;
    var secret: [crypto.CURVE_SECRET_MAX]u8 = undefined;
    const curves = [_]struct { curve: u32, pair: [*:0]const u8, agree: [*:0]const u8 }{
        .{ .curve = crypto.CURVE_X25519, .pair = "X25519 key pair", .agree = "X25519 shared secret" },
        .{ .curve = crypto.CURVE_P256, .pair = "P-256 key pair", .agree = "P-256 shared secret" },
        .{ .curve = crypto.CURVE_P384, .pair = "P-384 key pair", .agree = "P-384 shared secret" },
    };
    for (curves) |entry| {
        var started = millis(run.dl);
        for (0..5) |_| _ = cb.MakeKeyPair(entry.curve, &private_key, &public_key, &length);
        report(run, entry.pair, started, 5);
        started = millis(run.dl);
        for (0..5) |_| _ = cb.SharedSecret(entry.curve, &private_key, &Bytes.of(public_key[0..length]), &secret);
        report(run, entry.agree, started, 5);
    }
    const ec_key: crypto.PublicKey = .{ .point = Bytes.of(&ecdsa_point) };
    var started = millis(run.dl);
    for (0..5) |_| _ = cb.VerifySignature(crypto.SIG_ECDSA_P256, &ec_key, &Bytes.of(&signed_digest), &Bytes.of(&ecdsa_signature));
    report(run, "ECDSA P-256 verify", started, 5);
    const rsa_key: crypto.PublicKey = .{ .modulus = Bytes.of(&rsa_modulus), .exponent = Bytes.of(&.{ 1, 0, 1 }) };
    started = millis(run.dl);
    for (0..20) |_| _ = cb.VerifySignature(crypto.SIG_RSA_PSS_SHA256, &rsa_key, &Bytes.of(&signed_digest), &Bytes.of(&pss_signature));
    report(run, "RSA-2048 PSS verify", started, 20);
    const seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    var signature: [crypto.SIGNATURE_ED25519]u8 = undefined;
    started = millis(run.dl);
    for (0..5) |_| _ = cb.Sign(crypto.SIG_ED25519, &seed, &Bytes.of("message"), &signature);
    report(run, "Ed25519 sign", started, 5);

    // Bulk: 16 KiB, a TLS record's worth.
    const Buffer = struct {
        var data: [16384]u8 = @splat(0x5A);
    };
    const key: [16]u8 = @splat(1);
    const nonce: [12]u8 = @splat(2);
    var tag: [crypto.GCM_TAG]u8 = undefined;
    const message: crypto.GcmMessage = .{ .key = &key, .key_length = 16, .nonce = &nonce, .nonce_length = 12, .input = &Buffer.data, .output = &Buffer.data, .length = Buffer.data.len, .tag = &tag };
    started = millis(run.dl);
    for (0..16) |_| _ = cb.SealGcm(&message);
    var elapsed = millis(run.dl) - started;
    _ = Printf(run.dl, "%-34s %ld KiB/s (256 KiB in %ld ms)\n", .{ "AES-128-GCM seal", if (elapsed == 0) 0 else 256 * 1000 / elapsed, elapsed });
    var digest: [crypto.DIGEST_MAX]u8 = undefined;
    started = millis(run.dl);
    for (0..16) |_| _ = digestOf(cb, crypto.HASH_SHA256, &Buffer.data, &digest);
    elapsed = millis(run.dl) - started;
    _ = Printf(run.dl, "%-34s %ld KiB/s (256 KiB in %ld ms)\n", .{ "SHA-256", if (elapsed == 0) 0 else 256 * 1000 / elapsed, elapsed });
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
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
    keys(&run);
    signatures(&run);
    _ = Printf(dl, "%s: %u passed, %u failed\n", .{ COMMAND_NAME, run.passed, run.failed });
    if (argv[arg_random] != 0) random(&run);
    if (argv[arg_bench] != 0) bench(&run);
    return if (run.failed == 0) dos.RETURN_OK else dos.RETURN_ERROR;
}

/// The "$VER:" string, which `Version <file>` looks for. Nothing refers to
/// it, so it needs an export and a section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

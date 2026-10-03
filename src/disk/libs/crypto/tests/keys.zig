// SPDX-License-Identifier: MIT
//! Host tests of crypto.library 1.1's calls, through its jump table:
//! HKDF against RFC 5869 and std, key agreement on every curve against
//! std, ECDSA and Ed25519 against std's signers and RFC 8032, and RSA
//! against signatures openssl made.

const std = @import("std");
const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const crypto_init = @import("../crypto_init.zig");
const kexec = @import("host_rom").exec;

const testing = std.testing;

test {
    _ = @import("math.zig");
}

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

    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.cb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        try kexec.expectNoLeaks();
        kexec.deinit();
    }
};

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    @setEvalBranchQuota(100_000);
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

// --- hashes, HKDF ------------------------------------------------------------

test "a copied hash context goes on from where it was copied" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    var context: crypto.HashContext = .{};
    _ = cb.InitHash(&context, crypto.HASH_SHA256);
    cb.UpdateHash(&context, "hello, ", 7);
    var copy = context;
    var part: [32]u8 = undefined;
    _ = cb.FinishHash(&copy, &part);
    cb.UpdateHash(&context, "world", 5);
    var whole: [32]u8 = undefined;
    _ = cb.FinishHash(&context, &whole);
    var expect: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hello, ", &expect, .{});
    try testing.expectEqualSlices(u8, &expect, &part);
    std.crypto.hash.sha2.Sha256.hash("hello, world", &expect, .{});
    try testing.expectEqualSlices(u8, &expect, &whole);
}

test "HKDF: RFC 5869's first case, and std on every length" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    const ikm: [22]u8 = @splat(0x0b);
    const salt = hex("000102030405060708090a0b0c");
    const info = hex("f0f1f2f3f4f5f6f7f8f9");
    var prk: [32]u8 = undefined;
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.HkdfExtract(crypto.HASH_SHA256, &Bytes.of(&salt), &Bytes.of(&ikm), &prk));
    try testing.expectEqualSlices(u8, &hex("077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"), &prk);
    var okm: [42]u8 = undefined;
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.HkdfExpand(crypto.HASH_SHA256, &Bytes.of(&prk), &Bytes.of(&info), &okm, okm.len));
    try testing.expectEqualSlices(u8, &hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"), &okm);

    const Std = std.crypto.kdf.hkdf.Hkdf(std.crypto.auth.hmac.sha2.HmacSha384);
    const prk384 = Std.extract("salt", "keying material");
    var ours384: [48]u8 = undefined;
    _ = cb.HkdfExtract(crypto.HASH_SHA384, &Bytes.of("salt"), &Bytes.of("keying material"), &ours384);
    try testing.expectEqualSlices(u8, &prk384, &ours384);
    var length: u32 = 0;
    while (length < 200) : (length += 7) {
        var theirs: [200]u8 = undefined;
        var mine: [200]u8 = undefined;
        Std.expand(theirs[0..length], "tls13 key", prk384);
        _ = cb.HkdfExpand(crypto.HASH_SHA384, &Bytes.of(&prk384), &Bytes.of("tls13 key"), &mine, length);
        try testing.expectEqualSlices(u8, theirs[0..length], mine[0..length]);
    }
    try testing.expectEqual(crypto.CRYPTOERR_LENGTH, cb.HkdfExpand(crypto.HASH_SHA256, &Bytes.of(&prk), &Bytes.of(""), &okm, 255 * 32 + 1));
    try testing.expectEqual(crypto.CRYPTOERR_ALGORITHM, cb.HkdfExtract(99, &Bytes.of(""), &Bytes.of(""), &prk));
}

// --- key agreement -------------------------------------------------------------

fn agree(cb: *CryptoBase, curve: u32) !void {
    var a_private: [crypto.CURVE_PRIVATE_MAX]u8 = undefined;
    var b_private: [crypto.CURVE_PRIVATE_MAX]u8 = undefined;
    var a_public: [crypto.CURVE_PUBLIC_MAX]u8 = undefined;
    var b_public: [crypto.CURVE_PUBLIC_MAX]u8 = undefined;
    var a_length: u32 = 0;
    var b_length: u32 = 0;
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.MakeKeyPair(curve, &a_private, &a_public, &a_length));
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.MakeKeyPair(curve, &b_private, &b_public, &b_length));
    try testing.expectEqual(crypto.publicLength(curve), a_length);
    var one: [crypto.CURVE_SECRET_MAX]u8 = undefined;
    var other: [crypto.CURVE_SECRET_MAX]u8 = undefined;
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.SharedSecret(curve, &a_private, &Bytes.of(b_public[0..b_length]), &one));
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.SharedSecret(curve, &b_private, &Bytes.of(a_public[0..a_length]), &other));
    const length = crypto.secretLength(curve);
    try testing.expectEqualSlices(u8, one[0..length], other[0..length]);

    // The same as std's.
    switch (curve) {
        crypto.CURVE_X25519 => {
            const theirs = try std.crypto.dh.X25519.scalarmult(a_private[0..32].*, b_public[0..32].*);
            try testing.expectEqualSlices(u8, &theirs, one[0..32]);
        },
        crypto.CURVE_P256 => {
            const point = try std.crypto.ecc.P256.fromSec1(b_public[0..65]);
            const shared = try point.mul(a_private[0..32].*, .big);
            try testing.expectEqualSlices(u8, &shared.affineCoordinates().x.toBytes(.big), one[0..32]);
        },
        crypto.CURVE_P384 => {
            const point = try std.crypto.ecc.P384.fromSec1(b_public[0..97]);
            const shared = try point.mul(a_private[0..48].*, .big);
            try testing.expectEqualSlices(u8, &shared.affineCoordinates().x.toBytes(.big), one[0..48]);
        },
        else => unreachable,
    }

    // A point off the curve, and a key of the wrong length, are refused.
    b_public[b_length - 1] ^= 1;
    try testing.expectEqual(if (curve == crypto.CURVE_X25519) crypto.CRYPTOERR_OK else crypto.CRYPTOERR_KEY, cb.SharedSecret(curve, &a_private, &Bytes.of(b_public[0..b_length]), &one));
    try testing.expectEqual(crypto.CRYPTOERR_KEY, cb.SharedSecret(curve, &a_private, &Bytes.of(b_public[0 .. b_length - 1]), &one));
}

test "key agreement on X25519, P-256 and P-384: both sides, and std, agree" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    for (0..3) |_| {
        try agree(rig.cb, crypto.CURVE_X25519);
        try agree(rig.cb, crypto.CURVE_P256);
        try agree(rig.cb, crypto.CURVE_P384);
    }
    // X25519's point of order one gives all zeroes, which is no secret.
    var private_key: [32]u8 = @splat(7);
    var secret: [32]u8 = undefined;
    const zero: [32]u8 = @splat(0);
    try testing.expectEqual(crypto.CRYPTOERR_KEY, rig.cb.SharedSecret(crypto.CURVE_X25519, &private_key, &Bytes.of(&zero), &secret));
    try testing.expectEqual(crypto.CRYPTOERR_ALGORITHM, rig.cb.SharedSecret(crypto.CURVE_ED25519, &private_key, &Bytes.of(&zero), &secret));
    var length: u32 = 0;
    try testing.expectEqual(crypto.CRYPTOERR_ALGORITHM, rig.cb.MakeKeyPair(0, &private_key, &secret, &length));
}

// --- signatures --------------------------------------------------------------

fn ecdsa(cb: *CryptoBase, comptime Scheme: type, algorithm: u32, comptime Hash: type) !void {
    var random = std.Random.DefaultPrng.init(algorithm);
    for (0..5) |round| {
        var seed: [Scheme.KeyPair.seed_length]u8 = undefined;
        random.random().bytes(&seed);
        const pair = try Scheme.KeyPair.generateDeterministic(seed);
        var message: [40]u8 = undefined;
        random.random().bytes(&message);
        const signed = try pair.sign(&message, null);
        var der_buffer: [Scheme.Signature.der_encoded_length_max]u8 = undefined;
        const der = signed.toDer(&der_buffer);
        var digest: [Hash.digest_length]u8 = undefined;
        Hash.hash(&message, &digest, .{});
        const point = pair.public_key.toUncompressedSec1();
        const key: crypto.PublicKey = .{ .point = Bytes.of(&point) };
        try testing.expectEqual(crypto.CRYPTOERR_OK, cb.VerifySignature(algorithm, &key, &Bytes.of(&digest), &Bytes.of(der)));
        digest[round] ^= 1;
        try testing.expectEqual(crypto.CRYPTOERR_SIGNATURE, cb.VerifySignature(algorithm, &key, &Bytes.of(&digest), &Bytes.of(der)));
        digest[round] ^= 1;
        var broken = der_buffer;
        broken[der.len - 1] ^= 1;
        try testing.expectEqual(crypto.CRYPTOERR_SIGNATURE, cb.VerifySignature(algorithm, &key, &Bytes.of(&digest), &Bytes.of(broken[0..der.len])));
        try testing.expectEqual(crypto.CRYPTOERR_SIGNATURE, cb.VerifySignature(algorithm, &key, &Bytes.of(&digest), &Bytes.of(der[0 .. der.len - 1])));
    }
}

test "ECDSA: std's P-256 and P-384 signatures verify, and changed ones do not" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    try ecdsa(rig.cb, std.crypto.sign.ecdsa.EcdsaP256Sha256, crypto.SIG_ECDSA_P256, std.crypto.hash.sha2.Sha256);
    try ecdsa(rig.cb, std.crypto.sign.ecdsa.EcdsaP384Sha384, crypto.SIG_ECDSA_P384, std.crypto.hash.sha2.Sha384);
    // A key that is not a point.
    const key: crypto.PublicKey = .{ .point = Bytes.of(&([_]u8{4} ++ [_]u8{1} ** 64)) };
    try testing.expectEqual(crypto.CRYPTOERR_KEY, rig.cb.VerifySignature(crypto.SIG_ECDSA_P256, &key, &Bytes.of("x"), &Bytes.of("y")));
}

test "Ed25519: RFC 8032's first vector, and std both ways" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    const seed = hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    const public_key = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    var signature: [64]u8 = undefined;
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.Sign(crypto.SIG_ED25519, &seed, &Bytes.of(""), &signature));
    try testing.expectEqualSlices(u8, &hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"), &signature);
    const key: crypto.PublicKey = .{ .point = Bytes.of(&public_key) };
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.VerifySignature(crypto.SIG_ED25519, &key, &Bytes.of(""), &Bytes.of(&signature)));
    signature[63] ^= 0x10;
    try testing.expectEqual(crypto.CRYPTOERR_SIGNATURE, cb.VerifySignature(crypto.SIG_ED25519, &key, &Bytes.of(""), &Bytes.of(&signature)));

    for (0..5) |_| {
        var our_seed: [32]u8 = undefined;
        var our_public: [32]u8 = undefined;
        var length: u32 = 0;
        try testing.expectEqual(crypto.CRYPTOERR_OK, cb.MakeKeyPair(crypto.CURVE_ED25519, &our_seed, &our_public, &length));
        const theirs = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(our_seed);
        try testing.expectEqualSlices(u8, &theirs.public_key.toBytes(), &our_public);
        const message = "a message of some length, signed by both";
        _ = cb.Sign(crypto.SIG_ED25519, &our_seed, &Bytes.of(message), &signature);
        try testing.expectEqualSlices(u8, &(try theirs.sign(message, null)).toBytes(), &signature);
        const our_key: crypto.PublicKey = .{ .point = Bytes.of(&our_public) };
        try testing.expectEqual(crypto.CRYPTOERR_OK, cb.VerifySignature(crypto.SIG_ED25519, &our_key, &Bytes.of(message), &Bytes.of(&signature)));
    }
    try testing.expectEqual(crypto.CRYPTOERR_ALGORITHM, cb.Sign(crypto.SIG_ECDSA_P256, &seed, &Bytes.of(""), &signature));
}

const rsa_modulus = hex("b12d6146163f0d87843905ed07b3bf4469e76ebd22b537f6b9e3c667324ad8dcb91f810d78256f846dcb22b46b2241d264f335676044435cb8a2b81c5854673b48b606c622ef4c095ff2362adc128cec4750e0b2f09a6ca974f9f11aeee2921352bcf7126fb46c6b9f9bc551637efc327cd1ebc9e7b8b18724afc8d7172793e5e9732822a38437288438c3a6d771fe47f97e01be2fbdf6bf4eb114e36545a5db11470deefcac8ed29dbff9ff5fb496eaa124f9a03de9558894b467b2d6954fc4ada915e07d579bdc494cc77e920ede82f0be04bc10b8154b00cb6bc1e2446d9b37b2f6640d9e8f8edfb5cd7797949b894995bfb85155bb57599f0f4ebe96037d");
const rsa_exponent = [_]u8{ 1, 0, 1 };
const rsa_message = "PowerOS signs this";

test "RSA: openssl's PKCS #1 v1.5 and PSS signatures verify, and changed ones do not" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;
    const cb = rig.cb;
    const key: crypto.PublicKey = .{ .modulus = Bytes.of(&rsa_modulus), .exponent = Bytes.of(&rsa_exponent) };
    var d256: [32]u8 = undefined;
    var d384: [48]u8 = undefined;
    var d512: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(rsa_message, &d256, .{});
    std.crypto.hash.sha2.Sha384.hash(rsa_message, &d384, .{});
    std.crypto.hash.sha2.Sha512.hash(rsa_message, &d512, .{});

    const pkcs1 = hex("afe13b4dd99246b8deee1fc2a234897453c2d5f615714475a8cc41aa42eda0feee4149760895ecbdf7f10c3ec4feb92ebc3454e047cede263ba78a1d4fe7c1a0bdf605be14ef596a7e9bae989f02a4cedc3b72b0bc9ee7c2c1264321ce1cc67ded5c51958143f75ac3b490e092fc4d79d18eba821054a5d5e4317a28b7ac1c4dc5475c166463c200be7be1da97c528f28f9931a01a726560ddac4eb67519089bba2825a9b66c37e85bf6e768087302c202cb9682666fd30d4f494fd1e1abca10799f6b269a8d29f8d1d8fbf5c80095f014320992f8a3774ff744ab85c915be2c24df98d027319eadc7ac00ba8e71864d005bbbb648252a14e7f4fc1ec331891b");
    const pkcs1_512 = hex("02a3ad05ccae47ae84c41fa1e1e2d840ef33f593dd8e06a5039e47d8d836e1de988f6150472b368330546c003b355893ae2ca5b2a6e106c7374578af32e507087a58e6dd3cc48e81c080e03360ed5f761487382696921c03e53e51e56b914672155eae2e7ed81b840f02b542227a747a33b54fdfafd3b2a657ef77c7758dc4bbd0385f77819219c6ff0b827cf5342b3f4281a6e7290d65b109591b72a2bb2ed07b4924c86efe5bfbae186308c424e403f082fca6bafde9e3e4e86fa30a41cd96eccb6f0ee499fe59c69ca157c37923c8e0d2e07ce64fa00e2da7b8314b72ba7235f6add3d5d3396692d49e2b7d8a54e9eca0b088a60b61143c9e959da4a49844");
    const pss = hex("831c2e1fd54a20ad3b853b1b0e81e698d14733dc2bc2e69980d2a37e9ea522c476ecc859b6765e23e29cac43a9554cef519ad955d855e3ec74768d6b3c567f701f748793017133399a046b5b90ea9ad937759d2c858a118dacc727fc0fd5311e36b12d7e595a27377f56a399d8884d51f0798d4eb886f916cf3f7cf679fb749e394bf1e999e296a191570913fdff404351eabecfe650bef972e8ae719d02e1974bad0d87e7fc7dffd15e85c170713c9a326a852a6876e46a2e6d825eeb1a9173f706fce6419c5cfce91e51813c0c2879028b8a1a72e9c9a17e1ea358e0736a77c05b26177f3f86734f6dc7bdbcd801ce4a22d7afbb608f895ec1e79a35459ee5");
    const pss384 = hex("2c5cf75ed9e6e0dc697cb6731887e8f3977e38b0aefe37fa4434e1827912e15cbd7265251f64385ce574026d106f15e8c3c4f73dfbc623e1e64a2027b64c776b4143bed664645c1c977e12a1cb5cfdcda516b14f5eea786123786c9fd0e56d291d8a93136c56c2020818407fd8890c196454300d71165c7e23a8c4b2fce66261959389497ce6d82c80a49cdd55d0e88e1bee93678a604a9cefc66ace7854eb781ac947c03982b370bd4a573d8b28f0f3b57fd9d05a7ee14b5643222c33ad5ce9915e1c17a9f932065f5dd59c0a0393cbc46ca828b00c3e8926b1e4cdd4d8637df75caa814eb408a888768d571a3b0eb65261730440e27c5cf4af947ac8febd4c");
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.VerifySignature(crypto.SIG_RSA_PKCS1_SHA256, &key, &Bytes.of(&d256), &Bytes.of(&pkcs1)));
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.VerifySignature(crypto.SIG_RSA_PKCS1_SHA512, &key, &Bytes.of(&d512), &Bytes.of(&pkcs1_512)));
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.VerifySignature(crypto.SIG_RSA_PSS_SHA256, &key, &Bytes.of(&d256), &Bytes.of(&pss)));
    try testing.expectEqual(crypto.CRYPTOERR_OK, cb.VerifySignature(crypto.SIG_RSA_PSS_SHA384, &key, &Bytes.of(&d384), &Bytes.of(&pss384)));

    // One scheme's signature is not the other's.
    try testing.expectEqual(crypto.CRYPTOERR_SIGNATURE, cb.VerifySignature(crypto.SIG_RSA_PSS_SHA256, &key, &Bytes.of(&d256), &Bytes.of(&pkcs1)));
    try testing.expectEqual(crypto.CRYPTOERR_SIGNATURE, cb.VerifySignature(crypto.SIG_RSA_PKCS1_SHA256, &key, &Bytes.of(&d256), &Bytes.of(&pss)));
    // A changed digest, a changed signature, the wrong length.
    var other = d256;
    other[0] ^= 1;
    try testing.expectEqual(crypto.CRYPTOERR_SIGNATURE, cb.VerifySignature(crypto.SIG_RSA_PKCS1_SHA256, &key, &Bytes.of(&other), &Bytes.of(&pkcs1)));
    try testing.expectEqual(crypto.CRYPTOERR_SIGNATURE, cb.VerifySignature(crypto.SIG_RSA_PSS_SHA256, &key, &Bytes.of(&other), &Bytes.of(&pss)));
    var broken = pss;
    broken[100] ^= 1;
    try testing.expectEqual(crypto.CRYPTOERR_SIGNATURE, cb.VerifySignature(crypto.SIG_RSA_PSS_SHA256, &key, &Bytes.of(&d256), &Bytes.of(&broken)));
    try testing.expectEqual(crypto.CRYPTOERR_SIGNATURE, cb.VerifySignature(crypto.SIG_RSA_PKCS1_SHA256, &key, &Bytes.of(&d256), &Bytes.of(pkcs1[1..])));
    try testing.expectEqual(crypto.CRYPTOERR_LENGTH, cb.VerifySignature(crypto.SIG_RSA_PKCS1_SHA256, &key, &Bytes.of(&d384), &Bytes.of(&pkcs1)));
    const even: crypto.PublicKey = .{ .modulus = Bytes.of(&[_]u8{ 1, 2 }), .exponent = Bytes.of(&rsa_exponent) };
    try testing.expectEqual(crypto.CRYPTOERR_KEY, cb.VerifySignature(crypto.SIG_RSA_PKCS1_SHA256, &even, &Bytes.of(&d256), &Bytes.of(&pkcs1)));
    try testing.expectEqual(crypto.CRYPTOERR_ALGORITHM, cb.VerifySignature(99, &key, &Bytes.of(&d256), &Bytes.of(&pkcs1)));
}

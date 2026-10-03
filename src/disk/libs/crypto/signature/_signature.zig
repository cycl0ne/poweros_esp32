// SPDX-License-Identifier: MIT
//! The signature schemes, as VerifySignature, Sign and MakeKeyPair share
//! them: RSA's two encodings over ModExp, ECDSA on the NIST curves, and
//! Ed25519.
//!
//! - **RSA PKCS #1 v1.5** (RFC 8017, 8.2.2): the signature raised to the
//!   public exponent, and the result compared with the encoding the
//!   digest must have - 00 01, at least eight FF, 00, the digest's
//!   DigestInfo - built here byte for byte, so no parser of the
//!   encoding stands in the way.
//! - **RSA-PSS** (RFC 8017, 8.1.2): the same exponentiation, the mask
//!   undone with MGF1, the salt found after the 01, and the hash over
//!   eight zeroes, the digest and the salt compared with the one in the
//!   encoding. Any salt length is taken.
//! - **ECDSA** (FIPS 186-5): the DER signature taken apart strictly, r
//!   and s held to 1 to n - 1, and u1 G + u2 Q's x compared with r
//!   modulo n.
//! - **Ed25519** (RFC 8032, 5.1): a key from its seed by SHA-512, a
//!   signature as R and S, and the check S B = R + k A.
//!
//! Every hash and every exponentiation goes through the library's own
//! jump table. Verification works on public data only and stops at the
//! first thing wrong; signing with Ed25519 takes the same steps whatever
//! the key.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Bytes = crypto.Bytes;
const _base = @import("../crypto_base.zig");
const CryptoBase = _base.CryptoBase;
const _cipher = @import("../cipher/_cipher.zig");
const edwards = @import("../math/edwards.zig");

/// The bytes of `bytes`, as a slice; empty for none.
pub fn slice(bytes: *const Bytes) []const u8 {
    const start = bytes.bytes orelse return &.{};
    return start[0..bytes.length];
}

/// SHA-512 over parts one after the other.
fn sha512(cb: *CryptoBase, parts: []const []const u8, digest: *[64]u8) void {
    hashParts(cb, crypto.HASH_SHA512, parts, digest);
}

fn hashParts(cb: *CryptoBase, algorithm: u32, parts: []const []const u8, digest: [*]u8) void {
    const lib = _base.iface(cb);
    var context: crypto.HashContext = .{};
    _ = lib.InitHash(&context, algorithm);
    for (parts) |part| lib.UpdateHash(&context, part.ptr, @intCast(part.len));
    _ = lib.FinishHash(&context, digest);
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

// --- RSA ---------------------------------------------------------------------

/// The DigestInfo before a digest, for PKCS #1 v1.5.
fn digestInfo(algorithm: u32) []const u8 {
    return switch (algorithm) {
        crypto.HASH_SHA256 => &.{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 },
        crypto.HASH_SHA384 => &.{ 0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30 },
        else => &.{ 0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40 },
    };
}

/// The signature raised to the key's exponent, into `out` (as long as the
/// modulus, its leading zeroes dropped); an error code, or OK.
fn rsaOpen(cb: *CryptoBase, key: *const crypto.PublicKey, signature: *const Bytes, out: *[crypto.NUMBER_MAX]u8, modulus_out: *[]const u8) i32 {
    var modulus = slice(&key.modulus);
    while (modulus.len > 0 and modulus[0] == 0) modulus = modulus[1..];
    const exponent = slice(&key.exponent);
    if (modulus.len == 0 or modulus.len > crypto.NUMBER_MAX or exponent.len == 0) return crypto.CRYPTOERR_KEY;
    if (modulus[modulus.len - 1] & 1 == 0) return crypto.CRYPTOERR_KEY;
    const signed = slice(signature);
    if (signed.len != modulus.len) return crypto.CRYPTOERR_SIGNATURE;
    // The signature below the modulus, as a number.
    for (signed, modulus) |s, n| {
        if (s < n) break;
        if (s > n) return crypto.CRYPTOERR_SIGNATURE;
    } else return crypto.CRYPTOERR_SIGNATURE;

    const base_value: crypto.Number = .{ .bytes = signed.ptr, .length = @intCast(signed.len) };
    const power: crypto.Number = .{ .bytes = exponent.ptr, .length = @intCast(exponent.len) };
    const n: crypto.Number = .{ .bytes = modulus.ptr, .length = @intCast(modulus.len) };
    const result = _base.iface(cb).ModExp(out, &base_value, &power, &n);
    if (result != crypto.CRYPTOERR_OK) return if (result == crypto.CRYPTOERR_NUMBER) crypto.CRYPTOERR_KEY else result;
    modulus_out.* = modulus;
    return crypto.CRYPTOERR_OK;
}

pub fn verifyPkcs1(cb: *CryptoBase, algorithm: u32, key: *const crypto.PublicKey, digest: []const u8, signature: *const Bytes) i32 {
    if (digest.len != crypto.digestLength(algorithm)) return crypto.CRYPTOERR_LENGTH;
    var decoded: [crypto.NUMBER_MAX]u8 = undefined;
    var modulus: []const u8 = undefined;
    const opened = rsaOpen(cb, key, signature, &decoded, &modulus);
    if (opened != crypto.CRYPTOERR_OK) return opened;
    const k = modulus.len;
    const info = digestInfo(algorithm);
    const t_length = info.len + digest.len;
    if (k < t_length + 11) return crypto.CRYPTOERR_SIGNATURE;
    // 00 01 FF ... FF 00 DigestInfo digest
    var bad: u8 = decoded[0] | (decoded[1] ^ 1);
    for (decoded[2 .. k - t_length - 1]) |byte| bad |= byte ^ 0xFF;
    bad |= decoded[k - t_length - 1];
    for (info, 0..) |byte, index| bad |= decoded[k - t_length + index] ^ byte;
    for (digest, 0..) |byte, index| bad |= decoded[k - digest.len + index] ^ byte;
    return if (bad == 0) crypto.CRYPTOERR_OK else crypto.CRYPTOERR_SIGNATURE;
}

pub fn verifyPss(cb: *CryptoBase, algorithm: u32, key: *const crypto.PublicKey, digest: []const u8, signature: *const Bytes) i32 {
    const h_length = crypto.digestLength(algorithm);
    if (digest.len != h_length) return crypto.CRYPTOERR_LENGTH;
    var decoded: [crypto.NUMBER_MAX]u8 = undefined;
    var modulus: []const u8 = undefined;
    const opened = rsaOpen(cb, key, signature, &decoded, &modulus);
    if (opened != crypto.CRYPTOERR_OK) return opened;

    // emBits = modBits - 1; the encoding is the low emLen bytes.
    const mod_bits: u32 = @intCast(8 * modulus.len - @clz(modulus[0]));
    const em_bits = mod_bits - 1;
    const em_length = (em_bits + 7) / 8;
    const k = modulus.len;
    if (k > em_length and decoded[0] != 0) return crypto.CRYPTOERR_SIGNATURE;
    const em = decoded[k - em_length .. k];
    if (em_length < h_length + 2 or em[em_length - 1] != 0xBC) return crypto.CRYPTOERR_SIGNATURE;
    const db_length = em_length - h_length - 1;
    const hash = em[db_length .. db_length + h_length];
    const top_bits: u3 = @intCast(8 * em_length - em_bits);
    const top_mask: u8 = @truncate(@as(u16, 0xFF00) >> top_bits);
    if (em[0] & top_mask != 0) return crypto.CRYPTOERR_SIGNATURE;

    // DB = maskedDB ^ MGF1(H)
    var db: [crypto.NUMBER_MAX]u8 = undefined;
    var made: usize = 0;
    var counter: u32 = 0;
    while (made < db_length) : (counter += 1) {
        const count: [4]u8 = .{ @truncate(counter >> 24), @truncate(counter >> 16), @truncate(counter >> 8), @truncate(counter) };
        var mask: [crypto.DIGEST_MAX]u8 = undefined;
        hashParts(cb, algorithm, &.{ hash, &count }, &mask);
        const take: usize = @min(db_length - made, @as(usize, h_length));
        for (0..take) |index| db[made + index] = em[made + index] ^ mask[index];
        made += take;
    }
    db[0] &= ~top_mask;
    // PS (zeroes), 01, salt
    var at: usize = 0;
    while (at < db_length and db[at] == 0) at += 1;
    if (at == db_length or db[at] != 1) return crypto.CRYPTOERR_SIGNATURE;
    const salt = db[at + 1 .. db_length];
    const zeroes: [8]u8 = @splat(0);
    var check: [crypto.DIGEST_MAX]u8 = undefined;
    hashParts(cb, algorithm, &.{ &zeroes, digest, salt }, &check);
    return if (same(check[0..h_length], hash)) crypto.CRYPTOERR_OK else crypto.CRYPTOERR_SIGNATURE;
}

// --- ECDSA -------------------------------------------------------------------

/// One INTEGER of a DER signature, strictly: positive, minimal, no
/// longer than the curve; into `out` as `size` bytes. The rest after it.
fn derInteger(input: []const u8, out: []u8) ?[]const u8 {
    if (input.len < 2 or input[0] != 0x02) return null;
    const length = input[1];
    if (length == 0 or length >= 0x80 or input.len < 2 + length) return null;
    var value = input[2 .. 2 + length];
    if (value[0] & 0x80 != 0) return null; // negative
    if (value[0] == 0) {
        if (value.len == 1 or value[1] & 0x80 == 0) return null; // not minimal
        value = value[1..];
    }
    if (value.len > out.len) return null;
    @memset(out, 0);
    @memcpy(out[out.len - value.len ..], value);
    return input[2 + length ..];
}

pub fn verifyEcdsa(comptime C: type, key: *const crypto.PublicKey, digest: []const u8, signature: *const Bytes) i32 {
    const q = C.decode(slice(&key.point)) orelse return crypto.CRYPTOERR_KEY;
    const der = slice(signature);
    if (der.len < 2 or der[0] != 0x30 or der[1] >= 0x80 or der.len != 2 + der[1]) return crypto.CRYPTOERR_SIGNATURE;
    var r_bytes: [C.bytes]u8 = undefined;
    var s_bytes: [C.bytes]u8 = undefined;
    var rest = derInteger(der[2..], &r_bytes) orelse return crypto.CRYPTOERR_SIGNATURE;
    rest = derInteger(rest, &s_bytes) orelse return crypto.CRYPTOERR_SIGNATURE;
    if (rest.len != 0) return crypto.CRYPTOERR_SIGNATURE;
    const S = C.Scalar;
    const r = S.fromBytesBig(&r_bytes) orelse return crypto.CRYPTOERR_SIGNATURE;
    const s = S.fromBytesBig(&s_bytes) orelse return crypto.CRYPTOERR_SIGNATURE;
    if (S.isZeroMask(&r) != 0 or S.isZeroMask(&s) != 0) return crypto.CRYPTOERR_SIGNATURE;

    // e: the digest's leftmost bits, as many as the order has.
    var e_bytes: [C.bytes]u8 = @splat(0);
    const take: usize = @min(digest.len, C.bytes);
    @memcpy(e_bytes[C.bytes - take ..], digest[0..take]);
    var e_plain: S.Number = S.zero;
    for (0..C.bytes) |index| e_plain[index / 4] |= @as(u32, e_bytes[C.bytes - 1 - index]) << @intCast(8 * (index % 4));
    const e = S.toMontgomery(&e_plain);

    const w = S.invert(&s);
    const first = S.mul(&e, &w);
    const second = S.mul(&r, &w);
    var first_bytes: [C.bytes]u8 = undefined;
    var second_bytes: [C.bytes]u8 = undefined;
    S.toBytesBig(&first, &first_bytes);
    S.toBytesBig(&second, &second_bytes);
    // u1 G + u2 Q
    const point = C.add(&C.multiply(&C.generator, &first_bytes), &C.multiply(&q, &second_bytes));
    if (C.isInfinity(&point)) return crypto.CRYPTOERR_SIGNATURE;

    var x: C.Fe = undefined;
    var y: C.Fe = undefined;
    C.affine(&point, &x, &y);
    var x_bytes: [C.bytes]u8 = undefined;
    C.Field.toBytesBig(&x, &x_bytes);
    var x_plain: S.Number = S.zero;
    for (0..C.bytes) |index| x_plain[index / 4] |= @as(u32, x_bytes[C.bytes - 1 - index]) << @intCast(8 * (index % 4));
    const v = S.toMontgomery(&x_plain);
    return if (S.equalMask(&v, &r) != 0) crypto.CRYPTOERR_OK else crypto.CRYPTOERR_SIGNATURE;
}

// --- Ed25519 -----------------------------------------------------------------

/// The secret scalar and the prefix a seed stands for, and the public
/// key: SHA-512 of the seed, its first half clamped.
pub fn ed25519Expand(cb: *CryptoBase, seed: *const [32]u8, scalar: *[32]u8, prefix: *[32]u8, public_key: *[32]u8) void {
    var hashed: [64]u8 = undefined;
    sha512(cb, &.{seed}, &hashed);
    scalar.* = hashed[0..32].*;
    scalar[0] &= 248;
    scalar[31] &= 127;
    scalar[31] |= 64;
    prefix.* = hashed[32..64].*;
    _cipher.wipe(&hashed);
    edwards.encode(&edwards.multiply(&edwards.base, scalar), public_key);
}

pub fn ed25519Sign(cb: *CryptoBase, seed: *const [32]u8, message: []const u8, signature: *[64]u8) void {
    var scalar: [32]u8 = undefined;
    var prefix: [32]u8 = undefined;
    var public_key: [32]u8 = undefined;
    ed25519Expand(cb, seed, &scalar, &prefix, &public_key);

    var hashed: [64]u8 = undefined;
    sha512(cb, &.{ &prefix, message }, &hashed);
    const r = edwards.reduceWide(&hashed);
    var r_bytes: [32]u8 = undefined;
    edwards.Scalar.toBytesLittle(&r, &r_bytes);
    edwards.encode(&edwards.multiply(&edwards.base, &r_bytes), signature[0..32]);

    sha512(cb, &.{ signature[0..32], &public_key, message }, &hashed);
    const k = edwards.reduceWide(&hashed);
    // a below 2^255 < R: into Montgomery form, reduced modulo L.
    var a_plain: edwards.Scalar.Number = edwards.Scalar.zero;
    for (0..32) |index| a_plain[index / 4] |= @as(u32, scalar[index]) << @intCast(8 * (index % 4));
    const a = edwards.Scalar.toMontgomery(&a_plain);
    const ka = edwards.Scalar.mul(&k, &a);
    const s = edwards.Scalar.add(&r, &ka);
    edwards.Scalar.toBytesLittle(&s, signature[32..64]);

    _cipher.wipe(&scalar);
    _cipher.wipe(&prefix);
    _cipher.wipe(&r_bytes);
    _cipher.wipe(&hashed);
    _cipher.wipe(@as([*]u8, @ptrCast(&a_plain))[0..@sizeOf(edwards.Scalar.Number)]);
}

pub fn ed25519Verify(cb: *CryptoBase, key: *const crypto.PublicKey, message: []const u8, signature: *const Bytes) i32 {
    const public_key = slice(&key.point);
    if (public_key.len != 32) return crypto.CRYPTOERR_KEY;
    const a = edwards.decode(public_key[0..32]) orelse return crypto.CRYPTOERR_KEY;
    const signed = slice(signature);
    if (signed.len != crypto.SIGNATURE_ED25519) return crypto.CRYPTOERR_SIGNATURE;
    const r = edwards.decode(signed[0..32]) orelse return crypto.CRYPTOERR_SIGNATURE;
    // S below L.
    var s_plain: edwards.Scalar.Number = edwards.Scalar.zero;
    for (0..32) |index| s_plain[index / 4] |= @as(u32, signed[32 + index]) << @intCast(8 * (index % 4));
    if (!edwards.Scalar.below(&s_plain)) return crypto.CRYPTOERR_SIGNATURE;

    var hashed: [64]u8 = undefined;
    sha512(cb, &.{ signed[0..32], public_key, message }, &hashed);
    const k = edwards.reduceWide(&hashed);
    var k_bytes: [32]u8 = undefined;
    edwards.Scalar.toBytesLittle(&k, &k_bytes);

    const left = edwards.multiply(&edwards.base, signed[32..64]);
    const right = edwards.add(&r, &edwards.multiply(&a, &k_bytes));
    return if (edwards.equal(&left, &right)) crypto.CRYPTOERR_OK else crypto.CRYPTOERR_SIGNATURE;
}

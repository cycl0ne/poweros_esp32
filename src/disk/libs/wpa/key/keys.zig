// SPDX-License-Identifier: MIT
//! The keys of WPA2-Personal (IEEE 802.11-2020, 12.7), on crypto.library:
//!
//! - the PMK, from the passphrase and the network's name by PBKDF2 with
//!   HMAC-SHA1, 4096 rounds (`pairwiseMaster`);
//! - the PRF that stretches a key over a label and some data, HMAC-SHA1
//!   in counter mode (`prf`);
//! - the PTK, the PRF over the PMK, both stations' addresses and both
//!   nonces, cut into the key confirmation key (KCK), the key encryption
//!   key (KEK) and the temporal key (TK) (`pairwiseTransient`);
//! - the MIC of an EAPOL-Key frame, HMAC-SHA1 under the KCK, cut to 16
//!   bytes (`mic`, or `micParts` over a frame in pieces);
//! - AES key unwrap (RFC 3394) under the KEK, for the group key the
//!   access point sends (`unwrap`).
//!
//! **PBKDF2's rounds** are 8192 HMACs over 20 bytes. The passphrase's
//! keyed context is made once and copied for every round, so a round is
//! two blocks through the SHA engine and nothing else.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const CryptoBase = sdk.interface.crypto.CryptoBase;

pub const pmk_bytes = 32;
pub const nonce_bytes = 32;
pub const kck_bytes = 16;
pub const kek_bytes = 16;
pub const tk_bytes = 16;
pub const mic_bytes = 16;
const sha1_bytes = 20;

/// PTK for CCMP: 48 bytes.
pub const Ptk = struct {
    kck: [kck_bytes]u8,
    kek: [kek_bytes]u8,
    tk: [tk_bytes]u8,
};

fn hmacOnce(cb: *CryptoBase, keyed: *const crypto.HmacContext, parts: []const []const u8, out: *[sha1_bytes]u8) void {
    var context = keyed.*;
    for (parts) |part| cb.UpdateHmac(&context, part.ptr, @intCast(part.len));
    _ = cb.FinishHmac(&context, out);
}

/// The PMK from a passphrase of 8 to 63 characters and an SSID of up to
/// 32 bytes. False if crypto.library refuses the key.
pub fn pairwiseMaster(cb: *CryptoBase, passphrase: []const u8, ssid: []const u8, out: *[pmk_bytes]u8) bool {
    var keyed: crypto.HmacContext = .{};
    if (cb.InitHmac(&keyed, crypto.HASH_SHA1, passphrase.ptr, @intCast(passphrase.len)) != crypto.CRYPTOERR_OK) return false;
    var at: usize = 0;
    var block: u8 = 1;
    while (at < pmk_bytes) : (block += 1) {
        const count = [4]u8{ 0, 0, 0, block };
        var u: [sha1_bytes]u8 = undefined;
        hmacOnce(cb, &keyed, &.{ ssid, &count }, &u);
        var t = u;
        for (1..4096) |_| {
            hmacOnce(cb, &keyed, &.{&u}, &u);
            for (&t, u) |*acc, byte| acc.* ^= byte;
        }
        const take = @min(pmk_bytes - at, sha1_bytes);
        @memcpy(out[at .. at + take], t[0..take]);
        at += take;
    }
    return true;
}

/// PRF-n (12.7.1.2): `out.len` bytes of HMAC-SHA1(key, label 0 data i),
/// i counting from 0.
pub fn prf(cb: *CryptoBase, key: []const u8, label: []const u8, data: []const u8, out: []u8) bool {
    var keyed: crypto.HmacContext = .{};
    if (cb.InitHmac(&keyed, crypto.HASH_SHA1, key.ptr, @intCast(key.len)) != crypto.CRYPTOERR_OK) return false;
    var at: usize = 0;
    var counter: u8 = 0;
    while (at < out.len) : (counter += 1) {
        var digest: [sha1_bytes]u8 = undefined;
        hmacOnce(cb, &keyed, &.{ label, &[_]u8{0}, data, &[_]u8{counter} }, &digest);
        const take = @min(out.len - at, sha1_bytes);
        @memcpy(out[at .. at + take], digest[0..take]);
        at += take;
    }
    return true;
}

fn lessThan(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| if (x != y) return x < y;
    return false;
}

/// The PTK (12.7.1.3): PRF-384 over "Pairwise key expansion" and the
/// smaller then the larger of the two addresses and of the two nonces.
pub fn pairwiseTransient(cb: *CryptoBase, pmk: *const [pmk_bytes]u8, authenticator: *const [6]u8, supplicant: *const [6]u8, anonce: *const [nonce_bytes]u8, snonce: *const [nonce_bytes]u8, out: *Ptk) bool {
    var data: [6 + 6 + nonce_bytes + nonce_bytes]u8 = undefined;
    const first_address = if (lessThan(authenticator, supplicant)) authenticator else supplicant;
    const second_address = if (first_address == authenticator) supplicant else authenticator;
    const first_nonce = if (lessThan(anonce, snonce)) anonce else snonce;
    const second_nonce = if (first_nonce == anonce) snonce else anonce;
    @memcpy(data[0..6], first_address);
    @memcpy(data[6..12], second_address);
    @memcpy(data[12..44], first_nonce);
    @memcpy(data[44..76], second_nonce);
    var bytes: [kck_bytes + kek_bytes + tk_bytes]u8 = undefined;
    if (!prf(cb, pmk, "Pairwise key expansion", &data, &bytes)) return false;
    out.* = .{ .kck = bytes[0..16].*, .kek = bytes[16..32].*, .tk = bytes[32..48].* };
    return true;
}

/// The MIC of an EAPOL-Key frame given in parts, its MIC field zero:
/// HMAC-SHA1 under the KCK, its first 16 bytes (key descriptor version 2).
/// A received frame is checked in place this way - the bytes before the
/// MIC field, sixteen zeroes, the bytes after it - so nothing has to be
/// copied to blank the field, and no buffer bounds the frame.
pub fn micParts(cb: *CryptoBase, kck: *const [kck_bytes]u8, parts: []const []const u8, out: *[mic_bytes]u8) bool {
    var keyed: crypto.HmacContext = .{};
    if (cb.InitHmac(&keyed, crypto.HASH_SHA1, kck, kck_bytes) != crypto.CRYPTOERR_OK) return false;
    var digest: [sha1_bytes]u8 = undefined;
    hmacOnce(cb, &keyed, parts, &digest);
    out.* = digest[0..mic_bytes].*;
    return true;
}

/// The MIC of an EAPOL-Key frame whose MIC field is zero.
pub fn mic(cb: *CryptoBase, kck: *const [kck_bytes]u8, frame: []const u8, out: *[mic_bytes]u8) bool {
    return micParts(cb, kck, &.{frame}, out);
}

/// RFC 3394's unwrap of `wrapped` (8 bytes longer than the key) into
/// `out`; false if the integrity check fails or the lengths are wrong.
pub fn unwrap(cb: *CryptoBase, kek: *const [kek_bytes]u8, wrapped: []const u8, out: []u8) bool {
    if (wrapped.len < 24 or wrapped.len % 8 != 0 or out.len != wrapped.len - 8) return false;
    const n = out.len / 8;
    var cipher: crypto.CipherContext = .{};
    if (cb.InitCipher(&cipher, crypto.CIPHER_AES_ECB | crypto.CIPHERF_DECRYPT, kek, kek_bytes, null) != crypto.CRYPTOERR_OK) return false;
    var a: [8]u8 = wrapped[0..8].*;
    @memcpy(out, wrapped[8..]);
    var j: usize = 6;
    while (j > 0) {
        j -= 1;
        var i: usize = n;
        while (i > 0) : (i -= 1) {
            const t: u64 = n * j + i;
            var block: [16]u8 = undefined;
            for (0..8) |k| block[k] = a[k] ^ @as(u8, @truncate(t >> @intCast(56 - 8 * k)));
            @memcpy(block[8..16], out[(i - 1) * 8 ..][0..8]);
            if (cb.UpdateCipher(&cipher, &block, &block, 16) != crypto.CRYPTOERR_OK) return false;
            a = block[0..8].*;
            @memcpy(out[(i - 1) * 8 ..][0..8], block[8..16]);
        }
    }
    var check: u8 = 0;
    for (a) |byte| check |= byte ^ 0xA6;
    return check == 0;
}

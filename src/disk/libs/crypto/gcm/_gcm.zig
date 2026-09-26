// SPDX-License-Identifier: MIT
//! AES-GCM (NIST SP 800-38D), as SealGcm and OpenGcm share it.
//!
//! The AES engine gives the hash key H = E(K, 0), the counter blocks'
//! key stream and the tag's mask E(K, J0); J0 is the nonce with a 32-bit
//! counter of 1 when the nonce is 12 bytes, and the GHASH of the nonce
//! otherwise. The data is CTR-encrypted from the block after J0. GHASH,
//! multiplication by H in GF(2^128) over the header, the ciphertext and
//! their lengths, is software: bit by bit with masks, so its time
//! depends on the lengths only, never on H or the data.
//!
//! Opening checks the tag over the ciphertext before anything is
//! decrypted, so a forged message never reaches the output.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const GcmMessage = crypto.GcmMessage;
const AES_BLOCK = crypto.AES_BLOCK;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _cipher = @import("../cipher/_cipher.zig");
const aes = @import("../engine/aes.zig");

/// GHASH under way: the key H and the running value Y, each as two
/// 64-bit halves, most significant first.
const Ghash = struct {
    h_high: u64,
    h_low: u64,
    y_high: u64 = 0,
    y_low: u64 = 0,

    fn init(key: *const [AES_BLOCK]u8) Ghash {
        return .{ .h_high = load64(key[0..8]), .h_low = load64(key[8..16]) };
    }

    /// Y = (Y ^ block) * H.
    fn block(ghash: *Ghash, bytes: *const [AES_BLOCK]u8) void {
        const x_high = ghash.y_high ^ load64(bytes[0..8]);
        const x_low = ghash.y_low ^ load64(bytes[8..16]);
        var z_high: u64 = 0;
        var z_low: u64 = 0;
        var v_high = ghash.h_high;
        var v_low = ghash.h_low;
        for (0..128) |index| {
            const word = if (index < 64) x_high else x_low;
            const bit = (word >> @intCast(63 - index % 64)) & 1;
            const take = 0 -% bit;
            z_high ^= v_high & take;
            z_low ^= v_low & take;
            const carry = 0 -% (v_low & 1);
            v_low = v_low >> 1 | v_high << 63;
            v_high = (v_high >> 1) ^ (carry & 0xE100_0000_0000_0000);
        }
        ghash.y_high = z_high;
        ghash.y_low = z_low;
    }

    /// `length` bytes, the last block padded with zeroes.
    fn update(ghash: *Ghash, data: [*]const u8, length: u32) void {
        var at: u32 = 0;
        while (at < length) : (at += AES_BLOCK) {
            var padded: [AES_BLOCK]u8 = @splat(0);
            const take = @min(length - at, AES_BLOCK);
            for (0..take) |index| padded[index] = data[at + index];
            ghash.block(&padded);
        }
    }

    fn result(ghash: *const Ghash) [AES_BLOCK]u8 {
        var out: [AES_BLOCK]u8 = undefined;
        store64(out[0..8], ghash.y_high);
        store64(out[8..16], ghash.y_low);
        return out;
    }
};

fn load64(bytes: *const [8]u8) u64 {
    var value: u64 = 0;
    for (bytes) |byte| value = value << 8 | byte;
    return value;
}

fn store64(bytes: *[8]u8, value: u64) void {
    for (bytes, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(56 - 8 * index));
}

/// The lengths block: the header's and the data's lengths in bits.
fn lengthsBlock(ghash: *Ghash, first: u32, second: u32) void {
    var block: [AES_BLOCK]u8 = undefined;
    store64(block[0..8], @as(u64, first) * 8);
    store64(block[8..16], @as(u64, second) * 8);
    ghash.block(&block);
}

/// Seals the message (`seal`) or opens it: SealGcm's and OpenGcm's work.
pub fn run(cb: *CryptoBase, message: *const GcmMessage, seal: bool) i32 {
    if (!_cipher.keyLength(message.key_length)) return crypto.CRYPTOERR_KEY;
    if (message.nonce_length == 0) return crypto.CRYPTOERR_LENGTH;
    if (message.aad_length != 0 and message.aad == null) return crypto.CRYPTOERR_LENGTH;
    if (message.length != 0 and (message.input == null or message.output == null)) return crypto.CRYPTOERR_LENGTH;

    var session = aes.begin(cb, message.key, message.key_length, false);
    defer session.end();
    var hash_key: [AES_BLOCK]u8 = @splat(0);
    session.block(&hash_key, &hash_key);
    var ghash = Ghash.init(&hash_key);
    _cipher.wipe(&hash_key);

    var j0: [AES_BLOCK]u8 = @splat(0);
    if (message.nonce_length == 12) {
        for (0..12) |index| j0[index] = message.nonce[index];
        j0[15] = 1;
    } else {
        var nonce_hash = ghash;
        nonce_hash.y_high = 0;
        nonce_hash.y_low = 0;
        nonce_hash.update(message.nonce, message.nonce_length);
        lengthsBlock(&nonce_hash, 0, message.nonce_length);
        j0 = nonce_hash.result();
    }

    if (message.aad) |aad| ghash.update(aad, message.aad_length);
    if (!seal and message.length != 0) ghash.update(message.input.?, message.length);

    var counter = j0;
    if (!seal) {
        // The tag first: a message that fails it is not decrypted.
        var expected = tagOf(&session, &ghash, &j0, message.aad_length, message.length);
        var differ: u8 = 0;
        for (expected, message.tag) |a, b| differ |= a ^ b;
        _cipher.wipe(&expected);
        if (differ != 0) return crypto.CRYPTOERR_TAG;
    }

    if (message.length != 0) {
        const from = message.input.?;
        const to = message.output.?;
        var stream: [AES_BLOCK]u8 = undefined;
        var at: u32 = 0;
        while (at < message.length) : (at += AES_BLOCK) {
            _cipher.increment32(&counter);
            session.block(&counter, &stream);
            const take = @min(message.length - at, AES_BLOCK);
            for (0..take) |index| to[at + index] = from[at + index] ^ stream[index];
        }
        _cipher.wipe(&stream);
    }

    if (seal) {
        if (message.length != 0) ghash.update(message.output.?, message.length);
        message.tag.* = tagOf(&session, &ghash, &j0, message.aad_length, message.length);
    }
    return crypto.CRYPTOERR_OK;
}

/// The tag: the lengths block through GHASH, and the result masked with
/// E(K, J0).
fn tagOf(session: *aes.Session, ghash: *Ghash, j0: *const [AES_BLOCK]u8, aad_length: u32, length: u32) [AES_BLOCK]u8 {
    var final = ghash.*;
    lengthsBlock(&final, aad_length, length);
    var tag = final.result();
    var mask: [AES_BLOCK]u8 = undefined;
    session.block(j0, &mask);
    _cipher.xorBlock(&tag, &mask);
    _cipher.wipe(&mask);
    return tag;
}

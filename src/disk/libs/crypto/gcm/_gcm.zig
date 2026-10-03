// SPDX-License-Identifier: MIT
//! AES-GCM (NIST SP 800-38D), as SealGcm and OpenGcm share it.
//!
//! The AES engine gives the hash key H = E(K, 0), the counter blocks'
//! key stream and the tag's mask E(K, J0); J0 is the nonce with a 32-bit
//! counter of 1 when the nonce is 12 bytes, and the GHASH of the nonce
//! otherwise. The data is CTR-encrypted from the block after J0. GHASH,
//! multiplication by H in GF(2^128) over the header, the ciphertext and
//! their lengths, is software - the S3's AES engine has no GCM of its
//! own - and takes the same steps whatever H and the data are.
//!
//! A block is multiplied without carries by H with ordinary integer
//! multiplications: each 32-bit operand split into four with three empty
//! bits between their bits, so that a carry never reaches a bit that
//! counts (`multiply32`), and Karatsuba on top - 128 by 128 bits in nine
//! such products. GCM numbers its bits from the most significant end, so
//! the 256-bit product of the blocks as they are loaded is the reversed
//! product shifted by one; it is shifted back and reduced modulo
//! x^128 + x^7 + x^2 + x + 1 in that reversed order (`block`).
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

/// x * y without carries, 32 by 32 bits into 64.
fn multiply32(x: u32, y: u32) u64 {
    const x0: u64 = x & 0x1111_1111;
    const x1: u64 = x & 0x2222_2222;
    const x2: u64 = x & 0x4444_4444;
    const x3: u64 = x & 0x8888_8888;
    const y0: u64 = y & 0x1111_1111;
    const y1: u64 = y & 0x2222_2222;
    const y2: u64 = y & 0x4444_4444;
    const y3: u64 = y & 0x8888_8888;
    // Each product's bits fall in one class of four; a column holds eight
    // at the most, so its carries stay inside the three bits above it.
    const z0 = (x0 * y0) ^ (x1 * y3) ^ (x2 * y2) ^ (x3 * y1);
    const z1 = (x0 * y1) ^ (x1 * y0) ^ (x2 * y3) ^ (x3 * y2);
    const z2 = (x0 * y2) ^ (x1 * y1) ^ (x2 * y0) ^ (x3 * y3);
    const z3 = (x0 * y3) ^ (x1 * y2) ^ (x2 * y1) ^ (x3 * y0);
    return (z0 & 0x1111_1111_1111_1111) | (z1 & 0x2222_2222_2222_2222) |
        (z2 & 0x4444_4444_4444_4444) | (z3 & 0x8888_8888_8888_8888);
}

/// x * y without carries, 64 by 64 bits into 128: Karatsuba over halves.
fn multiply64(x: u64, y: u64) u128 {
    const x_low: u32 = @truncate(x);
    const x_high: u32 = @truncate(x >> 32);
    const y_low: u32 = @truncate(y);
    const y_high: u32 = @truncate(y >> 32);
    const low = multiply32(x_low, y_low);
    const high = multiply32(x_high, y_high);
    const middle = multiply32(x_low ^ x_high, y_low ^ y_high) ^ low ^ high;
    return @as(u128, low) ^ (@as(u128, middle) << 32) ^ (@as(u128, high) << 64);
}

/// GHASH under way: the key H and the running value Y, each 128 bits as
/// the block's bytes read most significant first.
const Ghash = struct {
    h: u128,
    y: u128 = 0,

    fn init(key: *const [AES_BLOCK]u8) Ghash {
        return .{ .h = load128(key) };
    }

    /// Y = (Y ^ block) * H.
    fn block(ghash: *Ghash, bytes: *const [AES_BLOCK]u8) void {
        const x = ghash.y ^ load128(bytes);
        const x_low: u64 = @truncate(x);
        const x_high: u64 = @truncate(x >> 64);
        const h_low: u64 = @truncate(ghash.h);
        const h_high: u64 = @truncate(ghash.h >> 64);
        const low = multiply64(x_low, h_low);
        const high = multiply64(x_high, h_high);
        const middle = multiply64(x_low ^ x_high, h_low ^ h_high) ^ low ^ high;
        // The 255-bit product, as high and low 128 bits, shifted up one.
        var product_high = high ^ (middle >> 64);
        var product_low = low ^ (middle << 64);
        product_high = product_high << 1 | product_low >> 127;
        product_low <<= 1;
        // Reversed, the high half is the product's low 128 coefficients and
        // the low half its high ones (u), which come down by x^128 =
        // x^7 + x^2 + x + 1; what that pushes past x^127 comes down again.
        const u = product_low;
        const w = (u << 127) ^ (u << 126) ^ (u << 121);
        ghash.y = product_high ^ u ^ (u >> 1) ^ (u >> 2) ^ (u >> 7) ^ w ^ (w >> 1) ^ (w >> 2) ^ (w >> 7);
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
        store64(out[0..8], @truncate(ghash.y >> 64));
        store64(out[8..16], @truncate(ghash.y));
        return out;
    }
};

fn load128(bytes: *const [AES_BLOCK]u8) u128 {
    return @as(u128, load64(bytes[0..8])) << 64 | load64(bytes[8..16]);
}

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
        nonce_hash.y = 0;
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

// SPDX-License-Identifier: MIT
//! AES-GCM (NIST SP 800-38D), as SealGcm and OpenGcm share it, and GMAC
//! a piece at a time, as InitGmac, UpdateGmac and FinishGmac share it.
//!
//! The AES engine gives the hash key H = E(K, 0), the counter blocks'
//! key stream and the tag's mask E(K, J0); J0 is the nonce with a 32-bit
//! counter of 1 when the nonce is 12 bytes, and the GHASH of the nonce
//! otherwise. The data is CTR-encrypted from the block after J0. GHASH,
//! multiplication by H in GF(2^128) over the header, the ciphertext and
//! their lengths, is software - the S3's AES engine has no GCM of its
//! own - and takes the same steps whatever H and the data are.
//!
//! The JH7110's engine, on the VisionFive 2, does GCM itself, by DMA: a
//! message it suits goes there (`bulk`), and only the header's share of
//! the tag is worked out here.
//!
//! A block is multiplied without carries by H with ordinary integer
//! multiplications, each operand split into parts with empty bits between
//! their bits so that a carry never reaches a bit that counts, and
//! Karatsuba on top: 128 by 128 bits in three products of 64 by 64. A
//! 64-bit chip multiplies those five parts by five (`multiply64Fifths`);
//! a 32-bit chip does Karatsuba again, 32 by 32 bits four parts by four
//! (`multiply32`). GCM numbers its bits from the most significant end, so
//! the 256-bit product of the blocks as they are loaded is the reversed
//! product shifted by one; it is shifted back and reduced modulo
//! x^128 + x^7 + x^2 + x + 1 in that reversed order (`block`).
//!
//! Opening checks the tag over the ciphertext before anything is
//! decrypted, so a forged message never reaches the output.
//!
//! A GMAC under way keeps H, E(K, J0) and GHASH's running value in its
//! context, and the bytes short of a block; whole blocks go through
//! straight from the caller's memory. It is software on every chip.

const std = @import("std");
const sdk = @import("sdk");
const crypto = sdk.crypto;
const GcmMessage = crypto.GcmMessage;
const GmacContext = crypto.GmacContext;
const AES_BLOCK = crypto.AES_BLOCK;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const _cipher = @import("../cipher/_cipher.zig");
const aes = @import("../engine/aes.zig");
const jh7110 = @import("../engine/jh7110.zig");

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

/// x * y without carries, 64 by 64 bits into 128, the way the chip does it
/// best. `after`, a product the caller worked out before, only orders the
/// work (`behind`).
const multiply64 = if (@sizeOf(usize) == 8) multiply64Fifths else multiply64Halves;

/// 64 by 64 bits on a 32-bit chip: Karatsuba over halves with `multiply32`.
fn multiply64Halves(x: u64, y: u64, after: u128) u128 {
    _ = after;
    const x_low: u32 = @truncate(x);
    const x_high: u32 = @truncate(x >> 32);
    const y_low: u32 = @truncate(y);
    const y_high: u32 = @truncate(y >> 32);
    const low = multiply32(x_low, y_low);
    const high = multiply32(x_high, y_high);
    const middle = multiply32(x_low ^ x_high, y_low ^ y_high) ^ low ^ high;
    return @as(u128, low) ^ (@as(u128, middle) << 32) ^ (@as(u128, high) << 64);
}

/// Bits 0, 5, 10 ... 60: the first of the five parts `multiply64Fifths`
/// splits an operand into, the others this shifted up one to four.
const fifth: u64 = 0x1084_2108_4210_8421;

/// 64 by 64 bits on a 64-bit chip, which multiplies 64 by 64 bits into 128
/// in two instructions: each operand split into five with four empty bits
/// between their bits. A column of one part times another holds thirteen
/// at the most, four bits' worth, so a carry never reaches a bit that
/// counts.
///
/// The twenty-five products are summed a class of the result at a time,
/// and each class waits for the one before it (`behind`): left to itself
/// the compiler works all fifty words out first and spills most of them
/// to the stack, which costs more than the multiplying.
inline fn multiply64Fifths(x: u64, y: u64, after: u128) u128 {
    const x_behind = behind(x, after);
    const y_behind = behind(y, after);
    var x_parts: [5]u64 = undefined;
    var y_parts: [5]u64 = undefined;
    inline for (0..5) |part| {
        x_parts[part] = x_behind & (fifth << part);
        y_parts[part] = y_behind & (fifth << part);
    }
    var product: u128 = 0;
    inline for (0..5) |k| {
        if (k != 0) {
            inline for (&x_parts) |*part| part.* = behind(part.*, product);
        }
        var z: u128 = 0;
        inline for (0..5) |i| z ^= @as(u128, x_parts[i]) * y_parts[(k + 5 - i) % 5];
        // The bits of class k: k, k + 5 ... in the low word and, 64 being
        // 4 more than a multiple of 5, k + 1, k + 6 ... in the high one.
        const bits = @as(u128, fifth << ((k + 1) % 5)) << 64 | (fifth << k);
        product |= z & bits;
    }
    return product;
}

/// `value`, which the compiler takes to depend on `after`, so that what is
/// worked out from it waits for `after`. The asm is empty: it costs no
/// instruction.
inline fn behind(value: u64, after: u128) u64 {
    return asm volatile (""
        : [out] "=r" (-> u64),
        : [in] "0" (value),
          [low] "r" (@as(u64, @truncate(after))),
          [high] "r" (@as(u64, @truncate(after >> 64))),
    );
}

/// x * y in GCM's field, each 128 bits as a block's bytes read most
/// significant first.
fn multiply(x: u128, y: u128) u128 {
    const x_low: u64 = @truncate(x);
    const x_high: u64 = @truncate(x >> 64);
    const y_low: u64 = @truncate(y);
    const y_high: u64 = @truncate(y >> 64);
    const low = multiply64(x_low, y_low, 0);
    const high = multiply64(x_high, y_high, low);
    const middle = multiply64(x_low ^ x_high, y_low ^ y_high, high) ^ low ^ high;
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
    return product_high ^ u ^ (u >> 1) ^ (u >> 2) ^ (u >> 7) ^ w ^ (w >> 1) ^ (w >> 2) ^ (w >> 7);
}

/// How a loop over whole blocks calls `multiply`: in place on a 64-bit
/// chip, which saves twelve registers and restores them for each call
/// otherwise, and as the compiler likes on a 32-bit one.
const in_loop: std.builtin.CallModifier = if (@sizeOf(usize) == 8) .always_inline else .auto;

/// `h` to the power `exponent` in GCM's field, by squaring and
/// multiplying: the steps follow the exponent - a message's length, no
/// secret - and not `h`.
fn power(h: u128, exponent: u32) u128 {
    // The field's 1: the block whose first bit is set.
    var result: u128 = 1 << 127;
    var square = h;
    var rest = exponent;
    while (rest != 0) : (rest >>= 1) {
        if (rest & 1 != 0) result = multiply(result, square);
        square = multiply(square, square);
    }
    return result;
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
        ghash.y = multiply(ghash.y ^ load128(bytes), ghash.h);
    }

    /// `length` bytes, the last block padded with zeroes.
    fn update(ghash: *Ghash, data: [*]const u8, length: u32) void {
        const whole = length & ~@as(u32, AES_BLOCK - 1);
        ghash.y = wholeBlocks(ghash.y, ghash.h, data, whole);
        if (whole == length) return;
        var padded: [AES_BLOCK]u8 = @splat(0);
        for (0..length - whole) |index| padded[index] = data[whole + index];
        ghash.block(&padded);
    }

    fn result(ghash: *const Ghash) [AES_BLOCK]u8 {
        var out: [AES_BLOCK]u8 = undefined;
        store64(out[0..8], @truncate(ghash.y >> 64));
        store64(out[8..16], @truncate(ghash.y));
        return out;
    }
};

/// GHASH's running value `y` after `length` bytes of whole blocks, taken
/// where they lie: (y ^ block) * h for each.
fn wholeBlocks(y: u128, h: u128, data: [*]const u8, length: u32) u128 {
    var value = y;
    var at: u32 = 0;
    while (at < length) : (at += AES_BLOCK) {
        value = @call(in_loop, multiply, .{ value ^ load128(data[at..][0..AES_BLOCK]), h });
    }
    return value;
}

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

fn store128(bytes: *[AES_BLOCK]u8, value: u128) void {
    store64(bytes[0..8], @truncate(value >> 64));
    store64(bytes[8..16], @truncate(value));
}

/// The lengths block: the header's and the data's lengths in bits.
fn lengthsBlock(ghash: *Ghash, first: u32, second: u32) void {
    var block: [AES_BLOCK]u8 = undefined;
    store64(block[0..8], @as(u64, first) * 8);
    store64(block[8..16], @as(u64, second) * 8);
    ghash.block(&block);
}

/// J0, the counter block the tag's mask is made from: a 12-byte nonce
/// and a counter of 1, or the GHASH of any other nonce.
fn firstCounter(ghash: *const Ghash, nonce: [*]const u8, nonce_length: u32) [AES_BLOCK]u8 {
    var j0: [AES_BLOCK]u8 = @splat(0);
    if (nonce_length == 12) {
        for (0..12) |index| j0[index] = nonce[index];
        j0[15] = 1;
        return j0;
    }
    var nonce_hash = ghash.*;
    nonce_hash.y = 0;
    nonce_hash.update(nonce, nonce_length);
    lengthsBlock(&nonce_hash, 0, nonce_length);
    return nonce_hash.result();
}

// --- GMAC a piece at a time -----------------------------------------------------

/// `context` set up for a GMAC with `key` (a length `keyLength` takes)
/// and `nonce` (1 byte or more): H and E(K, J0) worked out, and nothing
/// taken yet. The context's `size` stays as it was.
pub fn gmacBegin(cb: *CryptoBase, context: *GmacContext, key: [*]const u8, key_length: u32, nonce: [*]const u8, nonce_length: u32) void {
    var session = aes.begin(cb, key, key_length, false);
    defer session.end();
    var hash_key: [AES_BLOCK]u8 = @splat(0);
    session.block(&hash_key, &hash_key);
    const ghash = Ghash.init(&hash_key);
    var j0 = firstCounter(&ghash, nonce, nonce_length);
    session.block(&j0, &context.mask);
    _cipher.wipe(&j0);
    context.hash_key = hash_key;
    _cipher.wipe(&hash_key);
    context.key_length = key_length;
    for (0..key_length) |index| context.key[index] = key[index];
}

/// `length` bytes of `data` into the GMAC: the bytes before a whole block
/// gathered in the context, whole blocks taken where they lie.
pub fn gmacAbsorb(context: *GmacContext, data: [*]const u8, length: u32) void {
    context.total += length;
    const h = load128(&context.hash_key);
    var y = load128(&context.state);
    var at: u32 = 0;
    if (context.buffered != 0) {
        const take = @min(length, AES_BLOCK - context.buffered);
        for (0..take) |index| context.partial[context.buffered + index] = data[index];
        context.buffered += take;
        at = take;
        if (context.buffered < AES_BLOCK) return;
        y = multiply(y ^ load128(&context.partial), h);
        context.buffered = 0;
    }
    const whole = (length - at) & ~@as(u32, AES_BLOCK - 1);
    y = wholeBlocks(y, h, data + at, whole);
    at += whole;
    for (0..length - at) |index| context.partial[index] = data[at + index];
    context.buffered = length - at;
    store128(&context.state, y);
}

/// The GMAC's tag: the bytes short of a block padded with zeroes, the
/// lengths block (the data as header, no ciphertext), and the result
/// masked with E(K, J0).
pub fn gmacEnd(context: *GmacContext, tag: *[AES_BLOCK]u8) void {
    const h = load128(&context.hash_key);
    var y = load128(&context.state);
    if (context.buffered != 0) {
        for (context.buffered..AES_BLOCK) |index| context.partial[index] = 0;
        y = multiply(y ^ load128(&context.partial), h);
    }
    y = multiply(y ^ (@as(u128, context.total * 8) << 64), h);
    store128(tag, y ^ load128(&context.mask));
}

/// Seals the message (`seal`) or opens it: SealGcm's and OpenGcm's work.
pub fn run(cb: *CryptoBase, message: *const GcmMessage, seal: bool) i32 {
    if (!_cipher.keyLength(message.key_length)) return crypto.CRYPTOERR_KEY;
    if (message.nonce_length == 0) return crypto.CRYPTOERR_LENGTH;
    if (message.aad_length != 0 and message.aad == null) return crypto.CRYPTOERR_LENGTH;
    if (message.length != 0 and (message.input == null or message.output == null)) return crypto.CRYPTOERR_LENGTH;
    if (bulk(cb, message, seal)) |result| return result;

    var session = aes.begin(cb, message.key, message.key_length, false);
    defer session.end();
    var hash_key: [AES_BLOCK]u8 = @splat(0);
    session.block(&hash_key, &hash_key);
    var ghash = Ghash.init(&hash_key);
    _cipher.wipe(&hash_key);

    var j0 = firstCounter(&ghash, message.nonce, message.nonce_length);

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

/// The message through the JH7110's engine, where the board has one and
/// the message suits it - a 12-byte nonce and data fitting the engine's
/// buffers: the result, or null for the software.
///
/// The engine takes a header only through its registers, a word at a
/// time, so it is given none: it seals or opens the data alone, and the
/// header's share of the tag is added here. GHASH over blocks X1..Xm is
/// the sum of Xi * H^(m-i+1); the header's blocks come first, so each
/// carries c more powers of H than it would alone, c being the data's
/// blocks, and the lengths block differs. With Y_A the header's GHASH
/// without lengths, L the message's lengths block and L' the engine's
/// (no header), the tag is the engine's exclusive-ored with
/// (Y_A * H^c ^ L ^ L') * H. A message opened is copied out of the
/// engine's buffer only once its tag is right.
///
/// A message of header alone - GMAC, which SMB signs with - stays in the
/// software, which on the U74s hashes it faster than the engine does
/// (72 against 42 MB/s).
fn bulk(cb: *CryptoBase, message: *const GcmMessage, seal: bool) ?i32 {
    if (message.nonce_length != 12) return null;
    const length = message.length;
    if (length > jh7110.room or length < jh7110.least) return null;
    const state = jh7110.take(cb) orelse return null;
    defer jh7110.give(cb, state);
    @memcpy(state.input()[0..length], message.input.?[0..length]);
    var tag: [AES_BLOCK]u8 = undefined;
    if (!jh7110.gcm(cb, state, message.key, message.key_length, message.nonce, length, !seal, &tag)) return null;

    var hash_key: [AES_BLOCK]u8 = @splat(0);
    var session = aes.begin(cb, message.key, message.key_length, false);
    session.block(&hash_key, &hash_key);
    session.end();
    const h = load128(&hash_key);
    _cipher.wipe(&hash_key);
    // L ^ L': the lengths differ in the header's alone.
    var fix = (@as(u128, message.aad_length) * 8) << 64;
    if (message.aad_length != 0) {
        var header: Ghash = .{ .h = h };
        header.update(message.aad.?, message.aad_length);
        fix ^= multiply(header.y, power(h, (length + AES_BLOCK - 1) / AES_BLOCK));
    }
    store128(&tag, load128(&tag) ^ multiply(fix, h));

    if (!seal) {
        var differ: u8 = 0;
        for (tag, message.tag) |a, b| differ |= a ^ b;
        _cipher.wipe(&tag);
        if (differ != 0) return crypto.CRYPTOERR_TAG;
    }
    @memcpy(message.output.?[0..length], state.output()[0..length]);
    if (seal) message.tag.* = tag;
    _cipher.wipe(&tag);
    return crypto.CRYPTOERR_OK;
}

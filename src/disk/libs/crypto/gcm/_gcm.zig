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
//! 32-bit chip does Karatsuba again, 32 by 32 bits four parts by four
//! (`multiply32`). A 64-bit chip takes each product's low half four parts
//! by four (`lowHalf`) and its high half the same way from the halves'
//! bits reversed: 96 multiplications a block and about 400 instructions in
//! all, against 150 and 526 for five parts by five into whole products.
//! The U74 issues two instructions a cycle, one of them a multiplication,
//! so the instructions are what count. Four blocks at a time are summed
//! before the result is reversed back and reduced (`Sum`). GCM
//! numbers its bits from the most significant end, so the 256-bit product
//! of the blocks as they are loaded is the reversed product shifted by
//! one; it is shifted back and reduced modulo x^128 + x^7 + x^2 + x + 1 in
//! that reversed order (`reduce`).
//!
//! Opening checks the tag over the ciphertext before anything is
//! decrypted, so a forged message never reaches the output.
//!
//! A GMAC under way keeps H, E(K, J0) and GHASH's running value in its
//! context, and the bytes short of a block; whole blocks go through
//! straight from the caller's memory. It is software on every chip.
//!
//! GHASH is linear, so on the 64-bit chips a long run of whole blocks
//! given to a GMAC is cut into parts that the cores hash at once (exec's
//! ShareWork), each part from zero, and put together after: the GHASH so
//! far times H to the power of the next part's blocks, and that part's
//! added, part after part (`sharedBlocks`). Where the parts are cut
//! follows the length alone.

const std = @import("std");
const sdk = @import("sdk");
const crypto = sdk.crypto;
const GcmMessage = crypto.GcmMessage;
const GmacContext = crypto.GmacContext;
const AES_BLOCK = crypto.AES_BLOCK;
const CryptoBase = @import("../crypto_base.zig").CryptoBase;
const ExecBase = sdk.interface.exec.ExecBase;
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

/// 64 by 64 bits on a 32-bit chip: Karatsuba over halves with `multiply32`.
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

/// x * y in GCM's field, each 128 bits as a block's bytes read most
/// significant first.
fn multiply(x: u128, y: u128) u128 {
    if (quarters) {
        var sum: Sum = .{};
        sum.add(Operand.of(x), &Factor.of(y));
        return sum.total();
    }
    const x_low: u64 = @truncate(x);
    const x_high: u64 = @truncate(x >> 64);
    const y_low: u64 = @truncate(y);
    const y_high: u64 = @truncate(y >> 64);
    const low = multiply64(x_low, y_low);
    const high = multiply64(x_high, y_high);
    const middle = multiply64(x_low ^ x_high, y_low ^ y_high) ^ low ^ high;
    return reduce(high ^ (middle >> 64), low ^ (middle << 64));
}

/// The 255-bit product of two blocks, as its high and low 128 bits, in
/// the field.
inline fn reduce(high: u128, low: u128) u128 {
    // Shifted up one. Reversed, the high half is the product's low 128
    // coefficients and the low half its high ones (u), which come down by
    // x^128 = x^7 + x^2 + x + 1; what that pushes past x^127 comes down
    // again.
    const product_high = high << 1 | low >> 127;
    const u = low << 1;
    const w = (u << 127) ^ (u << 126) ^ (u << 121);
    return product_high ^ u ^ (u >> 1) ^ (u >> 2) ^ (u >> 7) ^ w ^ (w >> 1) ^ (w >> 2) ^ (w >> 7);
}

// --- 64-bit chips: four parts, and the halves reversed --------------------

/// Whether the chip multiplies 64 by 64 bits in one instruction: then
/// each product of 128 by 128 bits is six of 64 by 64 into their low
/// halves (`lowHalf`).
const quarters = @sizeOf(usize) == 8;

/// Bits 0, 4, 8 ... 60: the first of the four parts `lowHalf` splits an
/// operand into, the others this shifted up one to three.
const quarter: u64 = 0x1111_1111_1111_1111;

/// The low 64 bits of x * y without carries, in sixteen multiplications
/// (BearSSL's ctmul64): each operand split into four parts, every fourth
/// bit. A column of one part times another holds sixteen at the most, and
/// only from bit 60 on, whose carry leaves the word; below that fifteen,
/// which stay inside the three bits above it.
inline fn lowHalf(x: u64, y: u64) u64 {
    const x0 = x & quarter;
    const x1 = x & (quarter << 1);
    const x2 = x & (quarter << 2);
    const x3 = x & (quarter << 3);
    const y0 = y & quarter;
    const y1 = y & (quarter << 1);
    const y2 = y & (quarter << 2);
    const y3 = y & (quarter << 3);
    const z0 = (x0 *% y0) ^ (x1 *% y3) ^ (x2 *% y2) ^ (x3 *% y1);
    const z1 = (x0 *% y1) ^ (x1 *% y0) ^ (x2 *% y3) ^ (x3 *% y2);
    const z2 = (x0 *% y2) ^ (x1 *% y1) ^ (x2 *% y0) ^ (x3 *% y3);
    const z3 = (x0 *% y3) ^ (x1 *% y2) ^ (x2 *% y1) ^ (x3 *% y0);
    return (z0 & quarter) | (z1 & (quarter << 1)) | (z2 & (quarter << 2)) | (z3 & (quarter << 3));
}

/// `word`'s bytes the other way round, in three steps of masks and
/// shifts. Without Zbb's rev8 the compiler's own byte swap takes about
/// twice the instructions; `hidden` keeps it from seeing one here.
inline fn swapBytes(word: u64) u64 {
    const bytes: u64 = 0x00FF_00FF_00FF_00FF;
    const pairs: u64 = 0x0000_FFFF_0000_FFFF;
    var value = hidden(word);
    value = (value & bytes) << 8 | ((value >> 8) & bytes);
    value = hidden(value);
    value = (value & pairs) << 16 | ((value >> 16) & pairs);
    return value << 32 | value >> 32;
}

/// `word`'s bits the other way round.
inline fn reverse(word: u64) u64 {
    return bitsInBytes(swapBytes(word));
}

/// `value`, which the compiler can see nothing of: what it is worked out
/// from is not taken for one of its idioms. The asm is empty.
inline fn hidden(value: u64) u64 {
    return asm (""
        : [out] "=r" (-> u64),
        : [in] "0" (value),
    );
}

/// `word`'s bits the other way round inside each byte.
inline fn bitsInBytes(word: u64) u64 {
    const ones: u64 = 0x5555_5555_5555_5555;
    const twos: u64 = 0x3333_3333_3333_3333;
    const fours: u64 = 0x0F0F_0F0F_0F0F_0F0F;
    var value = word;
    value = (value & ones) << 1 | ((value >> 1) & ones);
    value = (value & twos) << 2 | ((value >> 2) & twos);
    return (value & fours) << 4 | ((value >> 4) & fours);
}

/// A block as a multiplication takes it: its halves, and each half's
/// bits the other way round. The product of two reversed halves has the
/// product's high half in its low one, reversed (`Sum.total`).
const Operand = struct {
    high: u64,
    low: u64,
    high_reversed: u64,
    low_reversed: u64,

    fn of(x: u128) Operand {
        const high: u64 = @truncate(x >> 64);
        const low: u64 = @truncate(x);
        return .{ .high = high, .low = low, .high_reversed = reverse(high), .low_reversed = reverse(low) };
    }

    /// The block at `bytes`, from the two words the chip loads there,
    /// least significant byte first: each half is its word's bytes the
    /// other way round, and the half reversed its word with each byte's
    /// bits reversed. `aligned`: `bytes` is on an 8-byte boundary, which
    /// the chip loads as a word instead of byte by byte.
    inline fn at(comptime aligned: bool, bytes: [*]const u8) Operand {
        const first = load(aligned, bytes);
        const second = load(aligned, bytes + 8);
        return .{ .high = swapBytes(first), .low = swapBytes(second), .high_reversed = bitsInBytes(first), .low_reversed = bitsInBytes(second) };
    }

    inline fn load(comptime aligned: bool, bytes: [*]const u8) u64 {
        if (aligned) {
            const words: [*]const u64 = @ptrCast(@alignCast(bytes));
            return std.mem.littleToNative(u64, words[0]);
        }
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    inline fn xor(a: Operand, b: Operand) Operand {
        return .{ .high = a.high ^ b.high, .low = a.low ^ b.low, .high_reversed = a.high_reversed ^ b.high_reversed, .low_reversed = a.low_reversed ^ b.low_reversed };
    }
};

/// H or one of its powers as a multiplication takes it: an operand, and
/// the sums of its halves for Karatsuba's third product.
const Factor = struct {
    high: u64,
    low: u64,
    sum: u64,
    high_reversed: u64,
    low_reversed: u64,
    sum_reversed: u64,

    fn of(y: u128) Factor {
        const operand = Operand.of(y);
        return .{
            .high = operand.high,
            .low = operand.low,
            .sum = operand.high ^ operand.low,
            .high_reversed = operand.high_reversed,
            .low_reversed = operand.low_reversed,
            .sum_reversed = operand.high_reversed ^ operand.low_reversed,
        };
    }
};

/// Products of blocks summed before they are brought into the field: the
/// low halves of Karatsuba's three products - low by low, high by high,
/// sum by sum - and the same of the reversed halves.
const Sum = struct {
    low: u64 = 0,
    high: u64 = 0,
    middle: u64 = 0,
    low_reversed: u64 = 0,
    high_reversed: u64 = 0,
    middle_reversed: u64 = 0,

    /// x * y added.
    inline fn add(sum: *Sum, x: Operand, y: *const Factor) void {
        sum.low ^= lowHalf(x.low, y.low);
        sum.high ^= lowHalf(x.high, y.high);
        sum.middle ^= lowHalf(x.low ^ x.high, y.sum);
        sum.low_reversed ^= lowHalf(x.low_reversed, y.low_reversed);
        sum.high_reversed ^= lowHalf(x.high_reversed, y.high_reversed);
        sum.middle_reversed ^= lowHalf(x.low_reversed ^ x.high_reversed, y.sum_reversed);
    }

    /// The sum in the field. A product of 64 by 64 bits has 127: its high
    /// half is the reversed product's low half, reversed and shifted down
    /// one. Reversing and shifting are linear, so the sums are reversed,
    /// not each product - three times however many products went in.
    inline fn total(sum: Sum) u128 {
        const low_high = reverse(sum.low_reversed) >> 1;
        const high_high = reverse(sum.high_reversed) >> 1;
        const middle_high = reverse(sum.middle_reversed ^ sum.low_reversed ^ sum.high_reversed) >> 1;
        const middle_low = sum.middle ^ sum.low ^ sum.high;
        return reduce(@as(u128, high_high) << 64 | (sum.high ^ middle_high), @as(u128, low_high ^ middle_low) << 64 | sum.low);
    }
};

/// Whole blocks go four at a time from this many bytes on, as H's powers
/// cost three multiplications.
const aggregate_least: u32 = 16 * AES_BLOCK;

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
    if (quarters) {
        if (@intFromPtr(data) % 8 == 0) return quarterBlocks(true, y, h, data, length);
        return quarterBlocks(false, y, h, data, length);
    }
    var value = y;
    var at: u32 = 0;
    while (at < length) : (at += AES_BLOCK) {
        value = multiply(value ^ load128(data[at..][0..AES_BLOCK]), h);
    }
    return value;
}

/// `wholeBlocks` on a 64-bit chip, `data` on an 8-byte boundary or not:
/// four blocks at a time from `aggregate_least` bytes on - (y ^ b1) h^4 ^
/// b2 h^3 ^ b3 h^2 ^ b4 h, summed and brought into the field once - and
/// the rest one at a time.
fn quarterBlocks(comptime aligned: bool, y: u128, h: u128, data: [*]const u8, length: u32) u128 {
    const by_h = Factor.of(h);
    var value = y;
    var at: u32 = 0;
    if (length >= aggregate_least) {
        const h2 = multiply(h, h);
        const h3 = multiply(h2, h);
        const powers = [4]Factor{ Factor.of(multiply(h3, h)), Factor.of(h3), Factor.of(h2), by_h };
        while (length - at >= 4 * AES_BLOCK) : (at += 4 * AES_BLOCK) {
            var sum: Sum = .{};
            inline for (&powers, 0..) |*by, index| {
                const block = Operand.at(aligned, data + at + index * AES_BLOCK);
                sum.add(if (index == 0) block.xor(Operand.of(value)) else block, by);
            }
            value = sum.total();
        }
    }
    while (at < length) : (at += AES_BLOCK) {
        var sum: Sum = .{};
        sum.add(Operand.at(aligned, data + at).xor(Operand.of(value)), &by_h);
        value = sum.total();
    }
    return value;
}

/// A run of whole blocks is shared between the cores from this many bytes
/// on, in parts of at least `share_part`, and in no more than
/// `share_parts_max`; on the 64-bit chips.
const share_least: u32 = 64 * 1024;
const share_part: u32 = 16 * 1024;
const share_parts_max = 4;

/// A GHASH shared out (`sharedBlocks`): H, the running value before it,
/// the blocks, and each part's GHASH - a cache line each, since the parts
/// write them at once.
const Shared = struct {
    h: u128,
    y: u128,
    data: [*]const u8,
    blocks: u32,
    results: [share_parts_max]Result = undefined,

    const Result = struct {
        value: u128 align(64),
    };

    /// Where part `part` of `parts` begins, in blocks, and how many it
    /// takes: as many each, part 0 the ones over.
    fn range(shared: *const Shared, part: u32, parts: u32) struct { u32, u32 } {
        const each = shared.blocks / parts;
        const first = shared.blocks - each * (parts - 1);
        if (part == 0) return .{ 0, first };
        return .{ first + (part - 1) * each, each };
    }
};

/// One part of a GHASH shared out, ShareWork's: its blocks' GHASH from
/// zero, part 0's from the running value.
fn hashPart(data: ?*anyopaque, part: u32, parts: u32) callconv(.c) void {
    const shared: *Shared = @ptrCast(@alignCast(data.?));
    const start, const count = shared.range(part, parts);
    const from: u128 = if (part == 0) shared.y else 0;
    shared.results[part].value = wholeBlocks(from, shared.h, shared.data + start * AES_BLOCK, count * AES_BLOCK);
}

/// The parts of a GHASH shared out, done in `parts`, put together: each
/// part after the first has as many blocks, so the value so far is
/// multiplied by the same power of H before each is added.
fn fold(shared: *const Shared, parts: u32) u128 {
    var value = shared.results[0].value;
    if (parts < 2) return value;
    const step = power(shared.h, shared.blocks / parts);
    for (shared.results[1..parts]) |result| value = multiply(value, step) ^ result.value;
    return value;
}

/// `wholeBlocks`, the blocks hashed in parts by the cores at once when
/// there are `share_least` bytes of them or more on a 64-bit chip; alone
/// when there are fewer, or ShareWork does the job alone.
fn sharedBlocks(sys: *ExecBase, y: u128, h: u128, data: [*]const u8, length: u32) u128 {
    if (!quarters or length < share_least) return wholeBlocks(y, h, data, length);
    var shared: Shared = .{ .h = h, .y = y, .data = data, .blocks = length / AES_BLOCK };
    const parts = sys.ShareWork(&hashPart, &shared, @min(length / share_part, share_parts_max));
    return fold(&shared, parts);
}

test "a GHASH shared out in parts comes to what one pass does" {
    var bytes: [4097 * AES_BLOCK + 3]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x6a09e667);
    random.random().bytes(&bytes);
    const h: u128 = 0x66e94bd4_ef8a2c3b_884cfa59_ca342b2e;
    const y: u128 = 0x0388dace_60b6a392_f328c2b9_71b2fe78;
    for ([_]usize{ 0, 3 }) |offset| {
        const data = bytes[offset..].ptr;
        for ([_]u32{ 1, 4, 4097 }) |blocks| {
            const whole = wholeBlocks(y, h, data, blocks * AES_BLOCK);
            for (1..share_parts_max + 1) |parts| {
                if (parts > blocks) continue;
                var shared: Shared = .{ .h = h, .y = y, .data = data, .blocks = blocks };
                for (0..parts) |part| hashPart(&shared, @intCast(part), @intCast(parts));
                try std.testing.expectEqual(whole, fold(&shared, @intCast(parts)));
            }
        }
    }
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
/// gathered in the context, whole blocks taken where they lie - a long
/// run of them shared between the cores (`sharedBlocks`).
pub fn gmacAbsorb(sys: *ExecBase, context: *GmacContext, data: [*]const u8, length: u32) void {
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
    y = sharedBlocks(sys, y, h, data + at, whole);
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

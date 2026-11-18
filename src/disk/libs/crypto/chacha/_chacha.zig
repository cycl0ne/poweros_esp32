// SPDX-License-Identifier: MIT
//! ChaCha20 and Poly1305 (RFC 8439), and the AEAD made of the two, as
//! the cipher calls, SealChaChaPoly, OpenChaChaPoly and Poly1305Pieces
//! share them. Software on every chip: no engine does either, and none
//! needs to - both take the same steps whatever the key and the data are,
//! and ChaCha20 is additions, rotations and exclusive-ors of 32-bit words,
//! which any core does fast.
//!
//! **ChaCha20** makes 64 bytes of key stream from a state of sixteen
//! words: four constants, the key's eight, a block counter and the
//! nonce's three. Twenty rounds of quarter-rounds mix it, and the state
//! it started from is added back. The state's last four words - the
//! counter, then the nonce - are handed in as 16 bytes, so the cipher
//! context and SSH's form (a 64-bit counter and a 64-bit nonce, which
//! the same 16 bytes hold) both go through as they are; the counter goes
//! up in the first word alone, as RFC 8439 counts, which no message of
//! less than 256 GiB tells apart from SSH's 64 bits.
//!
//! Where the core has 128-bit vectors - NEON on the AArch64 machines, SSE
//! on x86-64 - four blocks are made at once (`lanes`): each word of the
//! state is a vector of that word in four blocks with consecutive
//! counters, so a quarter-round is the same twelve operations on four
//! blocks, and the four are taken apart again by transposing 4 by 4
//! words. Elsewhere one block at a time, which keeps the sixteen words in
//! registers where a core has no vectors to spread four blocks over.
//!
//! **Poly1305** evaluates the message, cut into 16-byte pieces each with
//! a 1 above its top byte, as a polynomial at r modulo 2^130 - 5, and
//! adds s: r and s are the one-time key's halves, r with some bits
//! cleared. The accumulator and r are five 26-bit limbs, so each product
//! is a 64-bit integer on every chip (poly1305-donna's 32-bit form); the
//! carries are taken without a branch, and the last reduction picks the
//! result with a mask.
//!
//! **The AEAD** (RFC 8439, 2.8): the one-time key is the first 32 bytes
//! of block 0's key stream, the data is encrypted from block 1, and the
//! tag is Poly1305 over the header, zeroes to 16 bytes, the ciphertext,
//! zeroes to 16 bytes, and the two lengths as 64-bit little-endian
//! numbers. Opening checks the tag before anything is decrypted, so a
//! forged message never reaches the output.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const crypto = sdk.crypto;

pub const KEY = crypto.CHACHA_KEY;
pub const NONCE = crypto.CHACHA_NONCE;
pub const BLOCK = 64;
pub const TAG = crypto.POLY1305_TAG;

comptime {
    // The words are loaded and stored as the core holds them.
    if (builtin.cpu.arch.endian() != .little) @compileError("crypto.library's ChaCha20 is written for a little-endian core");
}

/// "expand 32-byte k".
const sigma = [4]u32{ 0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574 };

/// How many blocks are made at once: four where the core has 128-bit
/// vectors, one elsewhere.
pub const lanes: comptime_int = switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => 4,
    else => 1,
};
const V = @Vector(lanes, u32);

fn le32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

/// The key as eight words.
pub fn keyWords(key: *const [KEY]u8) [8]u32 {
    var words: [8]u32 = undefined;
    for (&words, 0..) |*word, index| word.* = le32(key[4 * index ..]);
    return words;
}

/// The state's last four words - the block counter, then the nonce - as
/// 16 bytes give them.
pub const Tail = struct {
    counter: u32,
    nonce: [3]u32,

    pub fn of(bytes: *const [16]u8) Tail {
        return .{ .counter = le32(bytes[0..]), .nonce = .{ le32(bytes[4..]), le32(bytes[8..]), le32(bytes[12..]) } };
    }

    /// The counter `counter` and RFC 8439's 12-byte nonce.
    pub fn rfc(counter: u32, nonce: *const [NONCE]u8) Tail {
        return .{ .counter = counter, .nonce = .{ le32(nonce[0..]), le32(nonce[4..]), le32(nonce[8..]) } };
    }

    pub fn store(tail: Tail, bytes: *[16]u8) void {
        std.mem.writeInt(u32, bytes[0..4], tail.counter, .little);
        for (tail.nonce, 0..) |word, index| std.mem.writeInt(u32, bytes[4 + 4 * index ..][0..4], word, .little);
    }
};

inline fn rotl(v: V, comptime n: u5) V {
    return (v << @splat(n)) | (v >> @splat(32 - @as(u6, n)));
}

inline fn quarter(x: *[16]V, comptime a: usize, comptime b: usize, comptime c: usize, comptime d: usize) void {
    x[a] +%= x[b];
    x[d] = rotl(x[d] ^ x[a], 16);
    x[c] +%= x[d];
    x[b] = rotl(x[b] ^ x[c], 12);
    x[a] +%= x[b];
    x[d] = rotl(x[d] ^ x[a], 8);
    x[c] +%= x[d];
    x[b] = rotl(x[b] ^ x[c], 7);
}

/// `lanes` blocks of key stream from block `tail.counter` on: each of the
/// sixteen words, one lane a block.
fn rounds(key: *const [8]u32, tail: Tail) [16]V {
    var x: [16]V = undefined;
    for (0..4) |index| x[index] = @splat(sigma[index]);
    for (0..8) |index| x[4 + index] = @splat(key[index]);
    const steps = comptime std.simd.iota(u32, lanes);
    const counters: V = @as(V, @splat(tail.counter)) +% steps;
    x[12] = counters;
    for (0..3) |index| x[13 + index] = @splat(tail.nonce[index]);
    const start = x;
    for (0..10) |_| {
        quarter(&x, 0, 4, 8, 12);
        quarter(&x, 1, 5, 9, 13);
        quarter(&x, 2, 6, 10, 14);
        quarter(&x, 3, 7, 11, 15);
        quarter(&x, 0, 5, 10, 15);
        quarter(&x, 1, 6, 11, 12);
        quarter(&x, 2, 7, 8, 13);
        quarter(&x, 3, 4, 9, 14);
    }
    for (&x, start) |*word, first| word.* +%= first;
    return x;
}

/// Four words of one block, from four vectors of four blocks each.
const Q = @Vector(4, u32);

/// The words `group * 4` to `group * 4 + 3` of each of the four blocks:
/// a 4 by 4 transposition.
inline fn transpose(a: Q, b: Q, c: Q, d: Q) [4]Q {
    const ab_low = @shuffle(u32, a, b, [4]i32{ 0, -1, 1, -2 });
    const ab_high = @shuffle(u32, a, b, [4]i32{ 2, -3, 3, -4 });
    const cd_low = @shuffle(u32, c, d, [4]i32{ 0, -1, 1, -2 });
    const cd_high = @shuffle(u32, c, d, [4]i32{ 2, -3, 3, -4 });
    return .{
        @shuffle(u32, ab_low, cd_low, [4]i32{ 0, 1, -1, -2 }),
        @shuffle(u32, ab_low, cd_low, [4]i32{ 2, 3, -3, -4 }),
        @shuffle(u32, ab_high, cd_high, [4]i32{ 0, 1, -1, -2 }),
        @shuffle(u32, ab_high, cd_high, [4]i32{ 2, 3, -3, -4 }),
    };
}

/// `lanes` blocks' key stream exclusive-ored over `lanes * BLOCK` bytes
/// of `from` into `to` - or, with `from` null, written there as it is.
fn streamBlocks(key: *const [8]u32, tail: Tail, from: ?[*]const u8, to: [*]u8) void {
    const x = rounds(key, tail);
    if (lanes == 4) {
        inline for (0..4) |group| {
            const words = transpose(x[4 * group], x[4 * group + 1], x[4 * group + 2], x[4 * group + 3]);
            inline for (0..4) |which| {
                const at = which * BLOCK + group * 16;
                var out: Q = words[which];
                if (from) |input| out ^= @bitCast(input[at..][0..16].*);
                to[at..][0..16].* = @bitCast(out);
            }
        }
    } else {
        for (0..16) |index| {
            var word = x[index][0];
            if (from) |input| word ^= le32(input[4 * index ..][0..4]);
            std.mem.writeInt(u32, to[4 * index ..][0..4], word, .little);
        }
    }
}

/// One block of key stream, block `tail.counter`.
pub fn block(key: *const [8]u32, tail: Tail, out: *[BLOCK]u8) void {
    var stream: [lanes * BLOCK]u8 = undefined;
    streamBlocks(key, tail, null, &stream);
    out.* = stream[0..BLOCK].*;
    wipe(&stream);
}

/// `length` bytes of `from` exclusive-ored with the key stream from the
/// start of block `tail.counter` into `to` (which may be `from`): the
/// counter after the last block begun is returned, and the bytes of that
/// block used, 0 when it ended on a block.
pub fn xor(key: *const [8]u32, tail: Tail, from: [*]const u8, to: [*]u8, length: usize) struct { tail: Tail, used: u32 } {
    var at_tail = tail;
    var at: usize = 0;
    const stride = lanes * BLOCK;
    while (length - at >= stride) : (at += stride) {
        streamBlocks(key, at_tail, from + at, to + at);
        at_tail.counter +%= lanes;
    }
    if (at == length) return .{ .tail = at_tail, .used = 0 };
    var stream: [stride]u8 = undefined;
    streamBlocks(key, at_tail, null, &stream);
    const left = length - at;
    for (0..left) |index| to[at + index] = from[at + index] ^ stream[index];
    wipe(&stream);
    at_tail.counter +%= @intCast(left / BLOCK);
    return .{ .tail = at_tail, .used = @intCast(left % BLOCK) };
}

/// A cipher context's data from where its last call left off: `tail`
/// the block under way, `used` the bytes of it already spent (0 to 63).
/// Both are moved on.
pub fn update(key: *const [KEY]u8, tail_bytes: *[16]u8, used: *u32, from: [*]const u8, to: [*]u8, length: usize) void {
    var words = keyWords(key);
    defer wipe(std.mem.asBytes(&words));
    var tail = Tail.of(tail_bytes);
    var at: usize = 0;
    if (used.* != 0) {
        var stream: [BLOCK]u8 = undefined;
        block(&words, tail, &stream);
        while (at < length and used.* < BLOCK) : (at += 1) {
            to[at] = from[at] ^ stream[used.*];
            used.* += 1;
        }
        wipe(&stream);
        if (used.* == BLOCK) {
            tail.counter +%= 1;
            used.* = 0;
        }
    }
    if (at < length) {
        const after = xor(&words, tail, from + at, to + at, length - at);
        tail = after.tail;
        used.* = after.used;
    }
    tail.store(tail_bytes);
}

// --- Poly1305 --------------------------------------------------------------------

/// A Poly1305 under way: the key's r (with its bits cleared) and r * 5 for
/// the reduction, the accumulator, s, and the bytes short of a piece.
pub const Poly1305 = struct {
    r: [5]u32,
    r5: [4]u32,
    h: [5]u32 = @splat(0),
    s: [4]u32,
    partial: [16]u8 = @splat(0),
    buffered: usize = 0,

    const mask26: u32 = 0x3FF_FFFF;

    pub fn init(key: *const [32]u8) Poly1305 {
        const r = [5]u32{
            le32(key[0..]) & 0x3FF_FFFF,
            (le32(key[3..]) >> 2) & 0x3FF_FF03,
            (le32(key[6..]) >> 4) & 0x3FF_C0FF,
            (le32(key[9..]) >> 6) & 0x3F0_3FFF,
            (le32(key[12..]) >> 8) & 0x00F_FFFF,
        };
        return .{
            .r = r,
            .r5 = .{ r[1] * 5, r[2] * 5, r[3] * 5, r[4] * 5 },
            .s = .{ le32(key[16..]), le32(key[20..]), le32(key[24..]), le32(key[28..]) },
        };
    }

    /// Whole 16-byte pieces, each with its 1 above the top byte - or,
    /// for the last piece padded by hand (`final`), without it.
    fn pieces(p: *Poly1305, data: []const u8, final: bool) void {
        const top: u32 = if (final) 0 else 1 << 24;
        const r0: u64 = p.r[0];
        const r1: u64 = p.r[1];
        const r2: u64 = p.r[2];
        const r3: u64 = p.r[3];
        const r4: u64 = p.r[4];
        const s1: u64 = p.r5[0];
        const s2: u64 = p.r5[1];
        const s3: u64 = p.r5[2];
        const s4: u64 = p.r5[3];
        var h0: u32 = p.h[0];
        var h1: u32 = p.h[1];
        var h2: u32 = p.h[2];
        var h3: u32 = p.h[3];
        var h4: u32 = p.h[4];
        var at: usize = 0;
        while (at + 16 <= data.len) : (at += 16) {
            const m = data[at..];
            h0 += le32(m[0..]) & mask26;
            h1 += (le32(m[3..]) >> 2) & mask26;
            h2 += (le32(m[6..]) >> 4) & mask26;
            h3 += (le32(m[9..]) >> 6) & mask26;
            h4 += (le32(m[12..]) >> 8) | top;
            const d0 = h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + @as(u64, h4) * s1;
            var d1 = h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + @as(u64, h4) * s2;
            var d2 = h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + @as(u64, h4) * s3;
            var d3 = h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + @as(u64, h4) * s4;
            var d4 = h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + @as(u64, h4) * r0;
            var c: u64 = d0 >> 26;
            h0 = @as(u32, @truncate(d0)) & mask26;
            d1 += c;
            c = d1 >> 26;
            h1 = @as(u32, @truncate(d1)) & mask26;
            d2 += c;
            c = d2 >> 26;
            h2 = @as(u32, @truncate(d2)) & mask26;
            d3 += c;
            c = d3 >> 26;
            h3 = @as(u32, @truncate(d3)) & mask26;
            d4 += c;
            c = d4 >> 26;
            h4 = @as(u32, @truncate(d4)) & mask26;
            h0 += @as(u32, @truncate(c)) * 5;
            h1 += h0 >> 26;
            h0 &= mask26;
        }
        p.h = .{ h0, h1, h2, h3, h4 };
    }

    pub fn update(p: *Poly1305, data: []const u8) void {
        var left = data;
        if (p.buffered != 0) {
            const take = @min(16 - p.buffered, left.len);
            @memcpy(p.partial[p.buffered..][0..take], left[0..take]);
            p.buffered += take;
            left = left[take..];
            if (p.buffered < 16) return;
            p.pieces(&p.partial, false);
            p.buffered = 0;
        }
        const whole = left.len / 16 * 16;
        p.pieces(left[0..whole], false);
        left = left[whole..];
        @memcpy(p.partial[0..left.len], left);
        p.buffered = left.len;
    }

    /// Zeroes up to the next 16 bytes, as the AEAD pads its parts.
    pub fn pad(p: *Poly1305) void {
        if (p.buffered == 0) return;
        const zeroes: [16]u8 = @splat(0);
        p.update(zeroes[0 .. 16 - p.buffered]);
    }

    /// The tag, and the state wiped.
    pub fn finish(p: *Poly1305, tag: *[TAG]u8) void {
        if (p.buffered != 0) {
            p.partial[p.buffered] = 1;
            @memset(p.partial[p.buffered + 1 ..], 0);
            p.pieces(&p.partial, true);
        }
        var h0 = p.h[0];
        var h1 = p.h[1];
        var h2 = p.h[2];
        var h3 = p.h[3];
        var h4 = p.h[4];
        // Carry fully.
        var c = h1 >> 26;
        h1 &= mask26;
        h2 += c;
        c = h2 >> 26;
        h2 &= mask26;
        h3 += c;
        c = h3 >> 26;
        h3 &= mask26;
        h4 += c;
        c = h4 >> 26;
        h4 &= mask26;
        h0 += c * 5;
        c = h0 >> 26;
        h0 &= mask26;
        h1 += c;
        // h - p, kept where it does not borrow: h mod 2^130 - 5.
        var g0 = h0 +% 5;
        c = g0 >> 26;
        g0 &= mask26;
        var g1 = h1 +% c;
        c = g1 >> 26;
        g1 &= mask26;
        var g2 = h2 +% c;
        c = g2 >> 26;
        g2 &= mask26;
        var g3 = h3 +% c;
        c = g3 >> 26;
        g3 &= mask26;
        const g4 = h4 +% c -% (1 << 26);
        // All ones where g4 did not go below zero: g is the result.
        const take_g = (g4 >> 31) -% 1;
        h0 = (h0 & ~take_g) | (g0 & take_g);
        h1 = (h1 & ~take_g) | (g1 & take_g);
        h2 = (h2 & ~take_g) | (g2 & take_g);
        h3 = (h3 & ~take_g) | (g3 & take_g);
        h4 = (h4 & ~take_g) | (g4 & take_g);
        // h mod 2^128, as four words, plus s.
        const w0: u32 = h0 | h1 << 26;
        const w1: u32 = h1 >> 6 | h2 << 20;
        const w2: u32 = h2 >> 12 | h3 << 14;
        const w3: u32 = h3 >> 18 | h4 << 8;
        var f: u64 = @as(u64, w0) + p.s[0];
        std.mem.writeInt(u32, tag[0..4], @truncate(f), .little);
        f = @as(u64, w1) + p.s[1] + (f >> 32);
        std.mem.writeInt(u32, tag[4..8], @truncate(f), .little);
        f = @as(u64, w2) + p.s[2] + (f >> 32);
        std.mem.writeInt(u32, tag[8..12], @truncate(f), .little);
        f = @as(u64, w3) + p.s[3] + (f >> 32);
        std.mem.writeInt(u32, tag[12..16], @truncate(f), .little);
        wipe(std.mem.asBytes(p));
    }
};

// --- the AEAD ---------------------------------------------------------------------

/// The AEAD's one-time Poly1305 key, from block 0.
fn oneTimeKey(key: *const [8]u32, nonce: *const [NONCE]u8) Poly1305 {
    var stream: [BLOCK]u8 = undefined;
    block(key, Tail.rfc(0, nonce), &stream);
    defer wipe(&stream);
    return Poly1305.init(stream[0..32]);
}

/// The tag over the header and the ciphertext.
fn tagOf(poly: *Poly1305, aad: []const u8, ciphertext: []const u8, tag: *[TAG]u8) void {
    poly.update(aad);
    poly.pad();
    poly.update(ciphertext);
    poly.pad();
    var lengths: [16]u8 = undefined;
    std.mem.writeInt(u64, lengths[0..8], aad.len, .little);
    std.mem.writeInt(u64, lengths[8..16], ciphertext.len, .little);
    poly.update(&lengths);
    poly.finish(tag);
}

/// `length` bytes of `from` encrypted into `to` (which may be `from`),
/// and the tag over `aad` and them.
pub fn seal(key: *const [KEY]u8, nonce: *const [NONCE]u8, aad: []const u8, from: [*]const u8, to: [*]u8, length: usize, tag: *[TAG]u8) void {
    var words = keyWords(key);
    defer wipe(std.mem.asBytes(&words));
    var poly = oneTimeKey(&words, nonce);
    if (length != 0) _ = xor(&words, Tail.rfc(1, nonce), from, to, length);
    tagOf(&poly, aad, to[0..length], tag);
}

/// The tag checked over `aad` and the `length` bytes of `from`, and only
/// then the bytes decrypted into `to`: false, with nothing written, when
/// it does not match.
pub fn open(key: *const [KEY]u8, nonce: *const [NONCE]u8, aad: []const u8, from: [*]const u8, to: [*]u8, length: usize, tag: *const [TAG]u8) bool {
    var words = keyWords(key);
    defer wipe(std.mem.asBytes(&words));
    var poly = oneTimeKey(&words, nonce);
    var expected: [TAG]u8 = undefined;
    tagOf(&poly, aad, from[0..length], &expected);
    var differ: u8 = 0;
    for (expected, tag) |a, b| differ |= a ^ b;
    wipe(&expected);
    if (differ != 0) return false;
    if (length != 0) _ = xor(&words, Tail.rfc(1, nonce), from, to, length);
    return true;
}

/// Seals the message (`seal`) or opens it: SealChaChaPoly's and
/// OpenChaChaPoly's work.
pub fn run(message: *const crypto.AeadMessage, sealing: bool) i32 {
    if (message.key_length != KEY) return crypto.CRYPTOERR_KEY;
    if (message.nonce_length != NONCE) return crypto.CRYPTOERR_LENGTH;
    if (message.aad_length != 0 and message.aad == null) return crypto.CRYPTOERR_LENGTH;
    if (message.length != 0 and (message.input == null or message.output == null)) return crypto.CRYPTOERR_LENGTH;
    const key = message.key[0..KEY];
    const nonce = message.nonce[0..NONCE];
    const aad: []const u8 = if (message.aad) |bytes| bytes[0..message.aad_length] else &.{};
    // A message of no data may come with null buffers.
    var none: [1]u8 = undefined;
    const from: [*]const u8 = message.input orelse &none;
    const to: [*]u8 = message.output orelse &none;
    if (sealing) {
        seal(key, nonce, aad, from, to, message.length, message.tag);
        return crypto.CRYPTOERR_OK;
    }
    return if (open(key, nonce, aad, from, to, message.length, message.tag)) crypto.CRYPTOERR_OK else crypto.CRYPTOERR_TAG;
}

/// `bytes` overwritten with zeroes in a way the compiler keeps.
pub fn wipe(bytes: []u8) void {
    for (bytes) |*byte| @as(*volatile u8, byte).* = 0;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

test "ChaCha20's block function (RFC 8439, 2.3.2)" {
    const key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    const nonce = hex("000000090000004a00000000");
    var out: [BLOCK]u8 = undefined;
    block(&keyWords(&key), Tail.rfc(1, &nonce), &out);
    try testing.expectEqualSlices(u8, &hex("10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e" ++
        "d2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e"), &out);
}

test "ChaCha20's encryption (RFC 8439, 2.4.2)" {
    const key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    const nonce = hex("000000000000004a00000000");
    const plain = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    var out: [plain.len]u8 = undefined;
    _ = xor(&keyWords(&key), Tail.rfc(1, &nonce), plain, &out, plain.len);
    try testing.expectEqualSlices(u8, &hex("6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b" ++
        "f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d8" ++
        "07ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab7793736" ++
        "5af90bbf74a35be6b40b8eedf2785e42874d"), &out);
}

test "Poly1305 (RFC 8439, 2.5.2)" {
    const key = hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b");
    var poly = Poly1305.init(&key);
    poly.update("Cryptographic Forum Research Group");
    var tag: [TAG]u8 = undefined;
    poly.finish(&tag);
    try testing.expectEqualSlices(u8, &hex("a8061dc1305136c6c22b8baf0c0127a9"), &tag);
}

test "the AEAD (RFC 8439, 2.8.2), sealed and opened, and a forged tag" {
    const key = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
    const nonce = hex("070000004041424344454647");
    const aad = hex("50515253c0c1c2c3c4c5c6c7");
    const plain = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    var data: [plain.len]u8 = plain.*;
    var tag: [TAG]u8 = undefined;
    seal(&key, &nonce, &aad, &data, &data, data.len, &tag);
    try testing.expectEqualSlices(u8, &hex("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6" ++
        "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36" ++
        "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc" ++
        "3ff4def08e4b7a9de576d26586cec64b6116"), &data);
    try testing.expectEqualSlices(u8, &hex("1ae10b594f09e26a7e902ecbd0600691"), &tag);
    var opened: [plain.len]u8 = undefined;
    try testing.expect(open(&key, &nonce, &aad, &data, &opened, data.len, &tag));
    try testing.expectEqualSlices(u8, plain, &opened);
    tag[0] ^= 1;
    @memset(&opened, 0xAA);
    try testing.expect(!open(&key, &nonce, &aad, &data, &opened, data.len, &tag));
    for (opened) |byte| try testing.expectEqual(@as(u8, 0xAA), byte);
}

test "ChaCha20, Poly1305 and the AEAD against std.crypto, every length to 600" {
    const Std = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
    var key: [KEY]u8 = undefined;
    for (&key, 0..) |*byte, index| byte.* = @truncate(index * 7 + 3);
    var nonce: [NONCE]u8 = undefined;
    for (&nonce, 0..) |*byte, index| byte.* = @truncate(index * 13 + 1);
    var plain: [600]u8 = undefined;
    for (&plain, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% 5);
    const aad = "a header of some length";
    var length: usize = 0;
    while (length <= plain.len) : (length += 1) {
        var ours: [600]u8 = undefined;
        var theirs: [600]u8 = undefined;
        var our_tag: [TAG]u8 = undefined;
        var their_tag: [TAG]u8 = undefined;
        seal(&key, &nonce, aad[0 .. length % aad.len], &plain, &ours, length, &our_tag);
        Std.encrypt(theirs[0..length], &their_tag, plain[0..length], aad[0 .. length % aad.len], nonce, key);
        try testing.expectEqualSlices(u8, theirs[0..length], ours[0..length]);
        try testing.expectEqualSlices(u8, &their_tag, &our_tag);
        // Poly1305 alone, over the plaintext, with the key as its key.
        var poly = Poly1305.init(&key);
        poly.update(plain[0 .. length / 3]);
        poly.update(plain[length / 3 .. length]);
        var tag: [TAG]u8 = undefined;
        poly.finish(&tag);
        var reference: [TAG]u8 = undefined;
        std.crypto.onetimeauth.Poly1305.create(&reference, plain[0..length], &key);
        try testing.expectEqualSlices(u8, &reference, &tag);
    }
}

test "ChaCha20 in pieces, from any byte of a block, as one run" {
    var key: [KEY]u8 = undefined;
    for (&key, 0..) |*byte, index| byte.* = @truncate(index + 100);
    var start: [16]u8 = undefined;
    for (&start, 0..) |*byte, index| byte.* = @truncate(index * 3);
    start[0] = 0xFE; // the counter crosses a byte as it goes
    var plain: [1100]u8 = undefined;
    for (&plain, 0..) |*byte, index| byte.* = @truncate(index ^ 0x5A);
    var whole: [1100]u8 = undefined;
    var tail_whole = start;
    var used_whole: u32 = 0;
    update(&key, &tail_whole, &used_whole, &plain, &whole, plain.len);
    for ([_]usize{ 1, 7, 63, 64, 65, 255, 256, 257, 300 }) |piece| {
        var split: [1100]u8 = undefined;
        var tail = start;
        var used: u32 = 0;
        var at: usize = 0;
        while (at < plain.len) {
            const take = @min(piece, plain.len - at);
            update(&key, &tail, &used, plain[at..].ptr, split[at..].ptr, take);
            at += take;
        }
        try testing.expectEqualSlices(u8, &whole, &split);
        try testing.expectEqualSlices(u8, &tail_whole, &tail);
        try testing.expectEqual(used_whole, used);
    }
    // And the key stream is IETF ChaCha20's from that counter.
    var reference: [1100]u8 = undefined;
    std.crypto.stream.chacha.ChaCha20IETF.xor(&reference, &plain, std.mem.readInt(u32, start[0..4], .little), key, start[4..16].*);
    try testing.expectEqualSlices(u8, &reference, &whole);
}

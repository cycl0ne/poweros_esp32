// SPDX-License-Identifier: MIT
//! MD4 and MD5 (RFC 1320, RFC 1321) over whole blocks, in software on
//! every chip: no engine has them. They take blocks the way the SHA
//! engine does - a first block from the algorithm's initial state, the
//! rest from the state kept between calls - and keep the state in the
//! digest's own byte order, low byte of each word first, so the finished
//! digest is its first 16 bytes.

const crypto = @import("sdk").crypto;
const _engine = @import("../engine/_engine.zig");

/// The four words both start from.
const initial = [4]u32{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 };

/// `blocks` whole 64-byte blocks of `data` through the hash whose state
/// is `state`; `first`: from the initial state instead.
pub fn run(algorithm: u32, state: *[16]u32, first: bool, data: [*]const u8, blocks: u32) void {
    const bytes: [*]u8 = @ptrCast(state);
    var h: [4]u32 = initial;
    if (!first) {
        for (&h, 0..) |*word, index| word.* = _engine.loadLittle(bytes + 4 * index);
    }
    for (0..blocks) |block| {
        if (algorithm == crypto.HASH_MD4) md4Block(&h, data + 64 * block) else md5Block(&h, data + 64 * block);
    }
    for (h, 0..) |word, index| _engine.storeLittle(bytes + 4 * index, word);
}

fn rotl(value: u32, by: u5) u32 {
    return value << by | value >> @intCast(32 - @as(u6, by));
}

fn words(block: [*]const u8) [16]u32 {
    var message: [16]u32 = undefined;
    for (&message, 0..) |*word, index| word.* = _engine.loadLittle(block + 4 * index);
    return message;
}

// --- MD5 ----------------------------------------------------------------------

/// The sines: the integer part of 2^32 * |sin(i + 1)|.
const md5_sines = [64]u32{
    0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
    0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
    0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
    0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
    0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
    0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
    0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
    0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
};

/// Each round's four rotations, taken in turn.
const md5_rotations = [4][4]u5{ .{ 7, 12, 17, 22 }, .{ 5, 9, 14, 20 }, .{ 4, 11, 16, 23 }, .{ 6, 10, 15, 21 } };

fn md5Block(h: *[4]u32, block: [*]const u8) void {
    const message = words(block);
    var a = h[0];
    var b = h[1];
    var c = h[2];
    var d = h[3];
    for (0..64) |step| {
        const round = step / 16;
        const mixed: u32, const word: usize = switch (round) {
            0 => .{ (b & c) | (~b & d), step },
            1 => .{ (d & b) | (~d & c), (5 * step + 1) % 16 },
            2 => .{ b ^ c ^ d, (3 * step + 5) % 16 },
            else => .{ c ^ (b | ~d), (7 * step) % 16 },
        };
        const turned = rotl(a +% mixed +% md5_sines[step] +% message[word], md5_rotations[round][step % 4]);
        a = d;
        d = c;
        c = b;
        b = b +% turned;
    }
    h[0] +%= a;
    h[1] +%= b;
    h[2] +%= c;
    h[3] +%= d;
}

// --- MD4 ----------------------------------------------------------------------

/// The words of the second and the third round, in the order they are
/// taken; the first takes them in order.
const md4_order = [2][16]u8{
    .{ 0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15 },
    .{ 0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15 },
};
const md4_rotations = [3][4]u5{ .{ 3, 7, 11, 19 }, .{ 3, 5, 9, 13 }, .{ 3, 9, 11, 15 } };
const md4_constants = [3]u32{ 0, 0x5a827999, 0x6ed9eba1 };

fn md4Block(h: *[4]u32, block: [*]const u8) void {
    const message = words(block);
    var a = h[0];
    var b = h[1];
    var c = h[2];
    var d = h[3];
    for (0..48) |step| {
        const round = step / 16;
        const mixed: u32, const word: usize = switch (round) {
            0 => .{ (b & c) | (~b & d), step },
            1 => .{ (b & c) | (b & d) | (c & d), md4_order[0][step % 16] },
            else => .{ b ^ c ^ d, md4_order[1][step % 16] },
        };
        const turned = rotl(a +% mixed +% message[word] +% md4_constants[round], md4_rotations[round][step % 4]);
        a = d;
        d = c;
        c = b;
        b = turned;
    }
    h[0] +%= a;
    h[1] +%= b;
    h[2] +%= c;
    h[3] +%= d;
}

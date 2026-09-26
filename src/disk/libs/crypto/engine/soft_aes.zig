// SPDX-License-Identifier: MIT
//! The AES engine as software, for the host: FIPS 197's cipher and
//! inverse cipher on one block, with a 128- or 256-bit key. The S-box
//! and its inverse are computed at compile time from the field's
//! inverses and the affine map.

const _engine = @import("_engine.zig");

/// A key expanded: the round keys, four words a round.
pub const Schedule = struct {
    words: [60]u32 = @splat(0),
    rounds: u32 = 0,
};

/// Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x + 1.
fn multiply(a: u8, b: u8) u8 {
    var x = a;
    var y = b;
    var product: u8 = 0;
    while (y != 0) : (y >>= 1) {
        if (y & 1 != 0) product ^= x;
        x = (x << 1) ^ (if (x & 0x80 != 0) @as(u8, 0x1B) else 0);
    }
    return product;
}

const sbox: [256]u8 = blk: {
    @setEvalBranchQuota(1_000_000);
    var table: [256]u8 = undefined;
    for (0..256) |value| {
        var inverse: u8 = 0;
        if (value != 0) {
            for (1..256) |candidate| {
                if (multiply(@intCast(value), @intCast(candidate)) == 1) inverse = @intCast(candidate);
            }
        }
        var result: u8 = inverse;
        var rotated: u8 = inverse;
        for (0..4) |_| {
            rotated = rotated << 1 | rotated >> 7;
            result ^= rotated;
        }
        table[value] = result ^ 0x63;
    }
    break :blk table;
};

const inverse_sbox: [256]u8 = blk: {
    var table: [256]u8 = undefined;
    for (sbox, 0..) |value, index| table[value] = @intCast(index);
    break :blk table;
};

fn subWord(word: u32) u32 {
    return @as(u32, sbox[word >> 24]) << 24 | @as(u32, sbox[(word >> 16) & 0xFF]) << 16 |
        @as(u32, sbox[(word >> 8) & 0xFF]) << 8 | sbox[word & 0xFF];
}

pub fn expand(schedule: *Schedule, key: [*]const u8, key_length: u32) void {
    const nk = key_length / 4;
    schedule.rounds = nk + 6;
    const total = 4 * (schedule.rounds + 1);
    for (0..nk) |index| schedule.words[index] = _engine.loadBig(key + 4 * index);
    var rcon: u8 = 1;
    var index = nk;
    while (index < total) : (index += 1) {
        var word = schedule.words[index - 1];
        if (index % nk == 0) {
            word = subWord(word << 8 | word >> 24) ^ (@as(u32, rcon) << 24);
            rcon = multiply(rcon, 2);
        } else if (nk > 6 and index % nk == 4) {
            word = subWord(word);
        }
        schedule.words[index] = schedule.words[index - nk] ^ word;
    }
}

fn addRoundKey(block: *[16]u8, schedule: *const Schedule, round: u32) void {
    for (0..4) |column| {
        const word = schedule.words[4 * round + column];
        block[4 * column] ^= @truncate(word >> 24);
        block[4 * column + 1] ^= @truncate(word >> 16);
        block[4 * column + 2] ^= @truncate(word >> 8);
        block[4 * column + 3] ^= @truncate(word);
    }
}

/// Row `row` moved left by `row` columns (right, to undo it).
fn shiftRows(block: *[16]u8, inverse: bool) void {
    const copy = block.*;
    for (0..4) |column| {
        for (0..4) |row| {
            const from = if (inverse) (column + 4 - row) % 4 else (column + row) % 4;
            block[4 * column + row] = copy[4 * from + row];
        }
    }
}

fn mixColumns(block: *[16]u8, inverse: bool) void {
    const factors: [4]u8 = if (inverse) .{ 14, 11, 13, 9 } else .{ 2, 3, 1, 1 };
    for (0..4) |column| {
        const c = block[4 * column ..][0..4].*;
        for (0..4) |row| {
            block[4 * column + row] = multiply(c[row], factors[0]) ^ multiply(c[(row + 1) % 4], factors[1]) ^
                multiply(c[(row + 2) % 4], factors[2]) ^ multiply(c[(row + 3) % 4], factors[3]);
        }
    }
}

pub fn encrypt(schedule: *const Schedule, input: *const [16]u8, output: *[16]u8) void {
    var block = input.*;
    addRoundKey(&block, schedule, 0);
    var round: u32 = 1;
    while (round <= schedule.rounds) : (round += 1) {
        for (&block) |*byte| byte.* = sbox[byte.*];
        shiftRows(&block, false);
        if (round != schedule.rounds) mixColumns(&block, false);
        addRoundKey(&block, schedule, round);
    }
    output.* = block;
}

pub fn decrypt(schedule: *const Schedule, input: *const [16]u8, output: *[16]u8) void {
    var block = input.*;
    addRoundKey(&block, schedule, schedule.rounds);
    var round = schedule.rounds;
    while (round > 0) {
        round -= 1;
        shiftRows(&block, true);
        for (&block) |*byte| byte.* = inverse_sbox[byte.*];
        addRoundKey(&block, schedule, round);
        if (round != 0) mixColumns(&block, true);
    }
    output.* = block;
}

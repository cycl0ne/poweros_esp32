// SPDX-License-Identifier: MIT
//! Big numbers for ModExp: the caller's big-endian bytes into the RSA
//! engine's little-endian words and back, and the two values the engine
//! needs besides the operands.
//!
//! - M' = -M^-1 mod 2^32, from the modulus's lowest word by Newton's
//!   iteration: each step doubles the bits that are right.
//! - R^2 mod M, R = 2^(32 n) for operands of n words: 1 shifted up a
//!   word at a time, 2 n times, each time reduced by long division - the
//!   modulus shifted up until its top bit is set, so that a quotient
//!   word guessed from the top words is at most two too large (Knuth's
//!   algorithm D). It depends on the modulus alone, which is public.
//! - A base that is not less than the modulus is reduced by doubling,
//!   fed its bits from the top, each time less M if it came to M or
//!   more; a base already below it is taken as it is.
//!
//! The doublings take the same steps whatever the bits: a subtraction is
//! always worked out and kept or dropped by a mask.

const sdk = @import("sdk");
const crypto = sdk.crypto;
const Number = crypto.Number;

/// The bytes of `number` after its leading zeroes.
pub fn significantBytes(number: *const Number) u32 {
    var skip: u32 = 0;
    while (skip < number.length and number.bytes[skip] == 0) skip += 1;
    return number.length - skip;
}

/// `number` into `words`, least significant word first, the rest of
/// `words` zero. The number fits: its significant bytes are no more than
/// four times the words.
pub fn load(words: []u32, number: *const Number) void {
    for (words) |*word| word.* = 0;
    var index: u32 = 0;
    while (index < number.length) : (index += 1) {
        const byte = number.bytes[number.length - 1 - index];
        if (byte == 0) continue;
        words[index / 4] |= @as(u32, byte) << @intCast(8 * (index % 4));
    }
}

/// `words` into `length` bytes, most significant first.
pub fn store(bytes: [*]u8, length: u32, words: []const u32) void {
    var index: u32 = 0;
    while (index < length) : (index += 1) {
        const word_index = index / 4;
        const byte: u8 = if (word_index < words.len) @truncate(words[word_index] >> @intCast(8 * (index % 4))) else 0;
        bytes[length - 1 - index] = byte;
    }
}

/// The length of `words` in bits: where its highest 1 is, plus one; 0
/// for zero.
pub fn bitLength(words: []const u32) u32 {
    var index: u32 = @intCast(words.len);
    while (index > 0) {
        index -= 1;
        if (words[index] != 0) return 32 * index + 32 - @clz(words[index]);
    }
    return 0;
}

/// -m^-1 mod 2^32, for an odd `lowest`, the modulus's lowest word.
pub fn mPrime(lowest: u32) u32 {
    // Right to 3 bits for any odd number; four steps make 48.
    var inverse = lowest;
    for (0..4) |_| inverse *%= 2 -% lowest *% inverse;
    return 0 -% inverse;
}

/// `value` = (2 * value + bit) mod `modulus`, with `value` already less
/// than the modulus.
fn doubleAdd(value: []u32, bit: u32, modulus: []const u32) void {
    var carry = bit;
    for (value) |*word| {
        const top = word.* >> 31;
        word.* = word.* << 1 | carry;
        carry = top;
    }
    // value - modulus, kept if there was a carry out or no borrow.
    var borrow: u32 = 0;
    var less: [crypto.NUMBER_MAX / 4]u32 = undefined;
    for (value, modulus, 0..) |word, subtract, index| {
        const difference = @as(u64, word) -% subtract -% borrow;
        less[index] = @truncate(difference);
        borrow = @truncate((difference >> 32) & 1);
    }
    const keep = 0 -% (carry | (borrow ^ 1));
    for (value, 0..) |*word, index| word.* = (less[index] & keep) | (word.* & ~keep);
}

/// `out` = R^2 mod `modulus`, R being 2 to the bits of `out`; the
/// modulus has as many words, its top one not zero.
pub fn rSquared(out: []u32, modulus: []const u32) void {
    const n = modulus.len;
    const shift: u5 = @intCast(@clz(modulus[n - 1]));
    // The modulus shifted up until its top bit is set, and y = 2^shift:
    // y * 2^(32 k) mod (M << shift) is (2^(32 k) mod M) << shift.
    var divisor: [crypto.NUMBER_MAX / 4]u32 = undefined;
    shiftUp(divisor[0..n], modulus, shift);
    var y: [crypto.NUMBER_MAX / 4 + 1]u32 = @splat(0);
    y[0] = @as(u32, 1) << shift;
    const top: u64 = divisor[n - 1];
    for (0..2 * n) |_| {
        // y * 2^32: one word up, n + 1 words.
        var index: usize = n;
        while (index > 0) : (index -= 1) y[index] = y[index - 1];
        y[0] = 0;
        // The quotient word, guessed from the top: never too small, at
        // most two too large.
        const guess: u64 = @min((@as(u64, y[n]) << 32 | y[n - 1]) / top, 0xFFFF_FFFF);
        const quotient: u32 = @intCast(guess);
        var carry: u64 = 0;
        var borrow: u64 = 0;
        for (0..n) |j| {
            const product = @as(u64, quotient) * divisor[j] + carry;
            carry = product >> 32;
            const difference = @as(u64, y[j]) -% (product & 0xFFFF_FFFF) -% borrow;
            y[j] = @truncate(difference);
            borrow = (difference >> 32) & 1;
        }
        const last = @as(u64, y[n]) -% carry -% borrow;
        y[n] = @truncate(last);
        var negative = (last >> 32) != 0;
        // Too large a guess: the divisor added back, once or twice.
        while (negative) {
            var add_carry: u64 = 0;
            for (0..n) |j| {
                const sum = @as(u64, y[j]) + divisor[j] + add_carry;
                y[j] = @truncate(sum);
                add_carry = sum >> 32;
            }
            const sum = @as(u64, y[n]) + add_carry;
            y[n] = @truncate(sum);
            negative = sum >> 32 == 0;
        }
    }
    // Back down by the shift.
    for (0..n) |index| {
        const high: u32 = if (index + 1 < n) y[index + 1] else 0;
        out[index] = if (shift == 0) y[index] else y[index] >> shift | high << @intCast(32 - @as(u6, shift));
    }
}

/// `value` shifted up by `shift` bits into `out`, as many words.
fn shiftUp(out: []u32, value: []const u32, shift: u5) void {
    if (shift == 0) {
        @memcpy(out, value);
        return;
    }
    var index: usize = value.len;
    while (index > 0) {
        index -= 1;
        const low: u32 = if (index > 0) value[index - 1] else 0;
        out[index] = value[index] << shift | low >> @intCast(32 - @as(u6, shift));
    }
}

/// Whether `value` is less than `modulus`, both as many words. The
/// answer only says which is larger, so a branch may say it.
pub fn below(value: []const u32, modulus: []const u32) bool {
    var index: usize = value.len;
    while (index > 0) {
        index -= 1;
        if (value[index] != modulus[index]) return value[index] < modulus[index];
    }
    return false;
}

/// `out` = `value` mod `modulus`; `value` may have more words.
pub fn reduce(out: []u32, value: []const u32, modulus: []const u32) void {
    for (out) |*word| word.* = 0;
    var bit: u32 = @intCast(32 * value.len);
    while (bit > 0) {
        bit -= 1;
        doubleAdd(out, (value[bit / 32] >> @intCast(bit % 32)) & 1, modulus);
    }
}

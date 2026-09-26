// SPDX-License-Identifier: MIT
//! Big numbers for ModExp: the caller's big-endian bytes into the RSA
//! engine's little-endian words and back, and the two values the engine
//! needs besides the operands.
//!
//! - M' = -M^-1 mod 2^32, from the modulus's lowest word by Newton's
//!   iteration: each step doubles the bits that are right.
//! - R^2 mod M, R = 2^(32 n) for operands of n words: 1 doubled 64 n
//!   times, each time less M if it came to M or more. The same doubling,
//!   fed a number's bits from the top, reduces a base that is not less
//!   than the modulus.
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

/// `out` = R^2 mod `modulus`, R being 2 to the bits of `out`.
pub fn rSquared(out: []u32, modulus: []const u32) void {
    for (out) |*word| word.* = 0;
    out[0] = 1;
    for (0..64 * out.len) |_| doubleAdd(out, 0, modulus);
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

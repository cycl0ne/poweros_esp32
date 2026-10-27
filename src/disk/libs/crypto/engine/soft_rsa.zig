// SPDX-License-Identifier: MIT
//! The RSA engine's modular exponentiation as software, wherever there
//! is no engine for it - the host, the P4, a modulus the JH7110's PKA
//! does not take: the same operands, the same Montgomery form, the same
//! answer. Montgomery multiplication word by word (CIOS), and the
//! exponent a window at a time from the top, as on the PKA.
//!
//! Nothing it does depends on the exponent's bits, only on its length:
//! each window costs its squarings and one multiplication by its entry
//! in the table, which `pick` reads whole, and each multiplication ends
//! in a subtraction that is always worked out and kept or dropped by a
//! mask.

const _base = @import("../crypto_base.zig");
const Numbers = _base.Numbers;
const number_words = _base.number_words;
const _bignum = @import("../bignum/_bignum.zig");

/// `out` = a * b / R mod m, all `words` long.
fn montgomery(out: []u32, a: []const u32, b: []const u32, m: []const u32, mprime: u32, words: u32) void {
    var t: [number_words + 2]u32 = @splat(0);
    for (0..words) |i| {
        var carry: u64 = 0;
        for (0..words) |j| {
            const sum = @as(u64, t[j]) + @as(u64, a[j]) * b[i] + carry;
            t[j] = @truncate(sum);
            carry = sum >> 32;
        }
        var sum = @as(u64, t[words]) + carry;
        t[words] = @truncate(sum);
        t[words + 1] = @truncate(sum >> 32);
        const factor: u32 = t[0] *% mprime;
        sum = @as(u64, t[0]) + @as(u64, factor) * m[0];
        carry = sum >> 32;
        for (1..words) |j| {
            sum = @as(u64, t[j]) + @as(u64, factor) * m[j] + carry;
            t[j - 1] = @truncate(sum);
            carry = sum >> 32;
        }
        sum = @as(u64, t[words]) + carry;
        t[words - 1] = @truncate(sum);
        t[words] = t[words + 1] + @as(u32, @truncate(sum >> 32));
    }
    // t < 2m: m taken off, and t kept instead where that went below 0 -
    // t's top word 0 and a borrow out of the rest.
    var borrow: u64 = 0;
    for (0..words) |index| {
        const difference = @as(u64, t[index]) -% m[index] -% borrow;
        out[index] = @truncate(difference);
        borrow = (difference >> 32) & 1;
    }
    const keep = 0 -% (@as(u32, @truncate(borrow)) & (t[words] ^ 1));
    for (0..words) |index| out[index] ^= (out[index] ^ t[index]) & keep;
}

/// `numbers.result` = base ^ exponent mod modulus, each `words` long,
/// with R^2 mod m in `numbers.rinv`; the exponent `exponent_bits` long,
/// at least 1. The table - x^i R mod m for every value i a window can
/// have - first, then each window from the top: its squarings and a
/// multiplication by its entry.
pub fn modExp(numbers: *Numbers, words: u32, mprime: u32, exponent_bits: u32) void {
    const m = numbers.modulus[0..words];
    const width = _bignum.windowBits(exponent_bits);
    const table = numbers.table[0 .. @as(u32, 1) << width];
    var z: [number_words]u32 = undefined;
    var picked: [number_words]u32 = undefined;
    defer {
        const bytes: [*]volatile u8 = @ptrCast(&picked);
        for (0..@sizeOf(@TypeOf(picked))) |index| bytes[index] = 0;
    }
    var one: [number_words]u32 = @splat(0);
    one[0] = 1;
    // R mod m, which is 1 in Montgomery form, and x R mod m; then each
    // entry the one before times x.
    montgomery(table[0][0..words], one[0..words], numbers.rinv[0..words], m, mprime, words);
    montgomery(table[1][0..words], numbers.base_value[0..words], numbers.rinv[0..words], m, mprime, words);
    for (2..table.len) |index| {
        montgomery(table[index][0..words], table[index - 1][0..words], table[1][0..words], m, mprime, words);
    }
    var window = (exponent_bits + width - 1) / width - 1;
    _bignum.pick(table, _bignum.digit(numbers.exponent[0..words], window, width), z[0..words]);
    while (window > 0) {
        window -= 1;
        for (0..width) |_| montgomery(z[0..words], z[0..words], z[0..words], m, mprime, words);
        _bignum.pick(table, _bignum.digit(numbers.exponent[0..words], window, width), picked[0..words]);
        montgomery(z[0..words], z[0..words], picked[0..words], m, mprime, words);
    }
    // Out of Montgomery form: times 1, over R.
    montgomery(numbers.result[0..words], z[0..words], one[0..words], m, mprime, words);
}

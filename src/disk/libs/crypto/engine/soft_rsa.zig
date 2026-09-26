// SPDX-License-Identifier: MIT
//! The RSA engine's modular exponentiation as software, for the host:
//! the same operands, the same Montgomery form, the same answer.
//! Montgomery multiplication word by word (CIOS), and square-and-multiply
//! from the exponent's top bit.

const _base = @import("../crypto_base.zig");
const Numbers = _base.Numbers;
const number_words = _base.number_words;

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
    // t < 2m: once more m off if it is not less.
    var less = t[words] == 0;
    if (less) {
        var index = words;
        while (index > 0) {
            index -= 1;
            if (t[index] != m[index]) {
                less = t[index] < m[index];
                break;
            }
        } else less = false;
    }
    if (less) {
        for (0..words) |index| out[index] = t[index];
        return;
    }
    var borrow: u64 = 0;
    for (0..words) |index| {
        const difference = @as(u64, t[index]) -% m[index] -% borrow;
        out[index] = @truncate(difference);
        borrow = (difference >> 32) & 1;
    }
}

pub fn modExp(numbers: *Numbers, words: u32, mprime: u32, exponent_bits: u32) void {
    const m = numbers.modulus[0..words];
    var x: [number_words]u32 = undefined;
    var z: [number_words]u32 = undefined;
    var one: [number_words]u32 = @splat(0);
    one[0] = 1;
    // X in Montgomery form, and Z = R mod m, which is 1 in it.
    montgomery(x[0..words], numbers.base_value[0..words], numbers.rinv[0..words], m, mprime, words);
    montgomery(z[0..words], one[0..words], numbers.rinv[0..words], m, mprime, words);
    var bit = exponent_bits;
    while (bit > 0) {
        bit -= 1;
        montgomery(z[0..words], z[0..words], z[0..words], m, mprime, words);
        if (numbers.exponent[bit / 32] >> @intCast(bit % 32) & 1 != 0) {
            montgomery(z[0..words], z[0..words], x[0..words], m, mprime, words);
        }
    }
    montgomery(numbers.result[0..words], z[0..words], one[0..words], m, mprime, words);
}

// SPDX-License-Identifier: MIT
//! The RSA engine's modular exponentiation as software, wherever there
//! is no engine for it - the host, the P4, a modulus the JH7110's PKA
//! does not take: the same operands, the same Montgomery form, the same
//! answer. Montgomery multiplication a limb at a time (CIOS), and the
//! exponent a window at a time from the top, as on the PKA.
//!
//! A limb is the chip's own (`field.native_limb`): on a 64-bit chip two
//! of the engine's words, multiplied 64 by 64 into 128 bits - a quarter
//! of the multiplications - wherever the number has an even count of
//! words, which leaves R and the Montgomery form as they are; a word
//! otherwise. The base keeps the numbers aligned to the limb for it.
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
const field = @import("../math/field.zig");

/// `out` = a * b / R mod m, all `words` long, worked in `Limb`s; for
/// u64 the words are an even count and 8-aligned.
fn montgomery(comptime Limb: type, out: []u32, a: []const u32, b: []const u32, m: []const u32, mprime: Limb, words: u32) void {
    const Double = if (Limb == u64) u128 else u64;
    const limb_bits = @bitSizeOf(Limb);
    const limbs = words / (limb_bits / 32);
    const x: [*]const Limb = @ptrCast(@alignCast(a.ptr));
    const y: [*]const Limb = @ptrCast(@alignCast(b.ptr));
    const n: [*]const Limb = @ptrCast(@alignCast(m.ptr));
    const z: [*]Limb = @ptrCast(@alignCast(out.ptr));
    var t: [number_words + 2]Limb = undefined;
    @memset(t[0 .. limbs + 2], 0);
    for (0..limbs) |i| {
        var carry: Limb = 0;
        for (0..limbs) |j| {
            const sum = @as(Double, t[j]) + @as(Double, x[j]) * y[i] + carry;
            t[j] = @truncate(sum);
            carry = @truncate(sum >> limb_bits);
        }
        var sum = @as(Double, t[limbs]) + carry;
        t[limbs] = @truncate(sum);
        t[limbs + 1] = @truncate(sum >> limb_bits);
        const factor: Limb = t[0] *% mprime;
        sum = @as(Double, t[0]) + @as(Double, factor) * n[0];
        carry = @truncate(sum >> limb_bits);
        for (1..limbs) |j| {
            sum = @as(Double, t[j]) + @as(Double, factor) * n[j] + carry;
            t[j - 1] = @truncate(sum);
            carry = @truncate(sum >> limb_bits);
        }
        sum = @as(Double, t[limbs]) + carry;
        t[limbs - 1] = @truncate(sum);
        t[limbs] = t[limbs + 1] + @as(Limb, @truncate(sum >> limb_bits));
    }
    // t < 2m: m taken off, and t kept instead where that went below 0 -
    // t's top limb 0 and a borrow out of the rest. `out` may be `a` or
    // `b`, which are read no more.
    var borrow: Limb = 0;
    for (0..limbs) |index| {
        const difference = @as(Double, t[index]) -% n[index] -% borrow;
        z[index] = @truncate(difference);
        borrow = @truncate((difference >> limb_bits) & 1);
    }
    const keep = 0 -% (borrow & (t[limbs] ^ 1));
    for (0..limbs) |index| z[index] ^= (z[index] ^ t[index]) & keep;
}

/// `numbers.result` = base ^ exponent mod modulus, each `words` long,
/// with R^2 mod m in `numbers.rinv` and -m^-1 mod 2^32 in `mprime`; the
/// exponent `exponent_bits` long, at least 1. In the chip's own limbs
/// where the words allow it.
pub fn modExp(numbers: *Numbers, words: u32, mprime: u32, exponent_bits: u32) void {
    if (field.native_limb == u64 and words % 2 == 0) {
        const low = @as(u64, numbers.modulus[1]) << 32 | numbers.modulus[0];
        return modExpIn(u64, numbers, words, mPrime64(low), exponent_bits);
    }
    modExpIn(u32, numbers, words, mprime, exponent_bits);
}

/// -m^-1 mod 2^64, for an odd `lowest`, the modulus's lowest 64 bits.
fn mPrime64(lowest: u64) u64 {
    // Right to 3 bits for any odd number; five steps make 96.
    var inverse = lowest;
    for (0..5) |_| inverse *%= 2 -% lowest *% inverse;
    return 0 -% inverse;
}

/// The exponentiation in `Limb`s. The table - x^i R mod m for every
/// value i a window can have - first, then each window from the top: its
/// squarings and a multiplication by its entry.
fn modExpIn(comptime Limb: type, numbers: *Numbers, words: u32, mprime: Limb, exponent_bits: u32) void {
    const m = numbers.modulus[0..words];
    const width = _bignum.windowBits(exponent_bits);
    const table = numbers.table[0 .. @as(u32, 1) << width];
    var z: [number_words]u32 align(8) = undefined;
    var picked: [number_words]u32 align(8) = undefined;
    defer {
        const bytes: [*]volatile u8 = @ptrCast(&picked);
        for (0..@sizeOf(@TypeOf(picked))) |index| bytes[index] = 0;
    }
    var one: [number_words]u32 align(8) = @splat(0);
    one[0] = 1;
    // R mod m, which is 1 in Montgomery form, and x R mod m; then each
    // entry the one before times x.
    montgomery(Limb, table[0][0..words], one[0..words], numbers.rinv[0..words], m, mprime, words);
    montgomery(Limb, table[1][0..words], numbers.base_value[0..words], numbers.rinv[0..words], m, mprime, words);
    for (2..table.len) |index| {
        montgomery(Limb, table[index][0..words], table[index - 1][0..words], table[1][0..words], m, mprime, words);
    }
    var window = (exponent_bits + width - 1) / width - 1;
    _bignum.pick(table, _bignum.digit(numbers.exponent[0..words], window, width), z[0..words]);
    while (window > 0) {
        window -= 1;
        for (0..width) |_| montgomery(Limb, z[0..words], z[0..words], z[0..words], m, mprime, words);
        _bignum.pick(table, _bignum.digit(numbers.exponent[0..words], window, width), picked[0..words]);
        montgomery(Limb, z[0..words], z[0..words], picked[0..words], m, mprime, words);
    }
    // Out of Montgomery form: times 1, over R.
    montgomery(Limb, numbers.result[0..words], z[0..words], one[0..words], m, mprime, words);
}

// --- tests (host: ./zig build test) -----------------------------------------

test "ModExp in 64-bit limbs gives the 32-bit limbs' answer" {
    const std = @import("std");
    const Prng = std.Random.DefaultPrng;
    var random = Prng.init(0x4D6F_6445);
    const numbers = try std.testing.allocator.create(Numbers);
    defer std.testing.allocator.destroy(numbers);
    for ([_]u32{ 2, 8, 64, 128 }) |words| {
        for ([_]u32{ 1, 17, 64, 32 * words }) |exponent_bits| {
            numbers.* = .{};
            random.random().bytes(std.mem.sliceAsBytes(numbers.modulus[0..words]));
            numbers.modulus[0] |= 1;
            numbers.modulus[words - 1] |= 0x8000_0000;
            random.random().bytes(std.mem.sliceAsBytes(numbers.base_value[0..words]));
            numbers.base_value[words - 1] &= 0x7FFF_FFFF;
            random.random().bytes(std.mem.sliceAsBytes(numbers.exponent[0..words]));
            const top = exponent_bits - 1;
            for (top / 32 + 1..words) |index| numbers.exponent[index] = 0;
            numbers.exponent[top / 32] &= @truncate((@as(u64, 2) << @intCast(top % 32)) - 1);
            numbers.exponent[top / 32] |= @as(u32, 1) << @intCast(top % 32);
            _bignum.rSquared(numbers.rinv[0..words], numbers.modulus[0..words]);
            const low = @as(u64, numbers.modulus[1]) << 32 | numbers.modulus[0];
            modExpIn(u64, numbers, words, mPrime64(low), exponent_bits);
            var wide: [number_words]u32 = undefined;
            @memcpy(wide[0..words], numbers.result[0..words]);
            modExpIn(u32, numbers, words, _bignum.mPrime(numbers.modulus[0]), exponent_bits);
            try std.testing.expectEqualSlices(u32, numbers.result[0..words], wide[0..words]);
        }
    }
}

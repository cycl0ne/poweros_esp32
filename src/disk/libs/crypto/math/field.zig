// SPDX-License-Identifier: MIT
//! Arithmetic modulo an odd number fixed at compile time: the fields the
//! curves are over, and the orders their scalars are taken modulo.
//!
//! A number is an array of 32-bit words, least significant first, kept
//! in Montgomery form - aR mod m for a, R being 2 to the bits of the
//! array - so that a product is reduced without a division (CIOS: one
//! word of the multiplier at a time, the reduction folded in). The chip
//! multiplies 32 by 32 into 64 bits in two instructions, which is what
//! this is built on.
//!
//! Every operation takes the same steps whatever the values: a carry or
//! a borrow is kept or dropped by a mask, never by a branch, and a
//! choice between two numbers (`select`, `swap`) is made the same way.
//! Only an exponent known at compile time (`powPublic`) steers the work
//! - it is the same for every caller.
//!
//! The operations every curve step is made of run without Zig's runtime
//! checks: their arrays have one length, fixed when the field is made,
//! and their sums are worked in 64 bits where they cannot overflow - the
//! tests hold them to big-integer arithmetic.
//!
//! The constants - the modulus's words, -m^-1 mod 2^32, R mod m and
//! R^2 mod m - are worked out at compile time from the modulus.

/// The field of numbers modulo `modulus`, in `words` 32-bit words.
pub fn Field(comptime words: comptime_int, comptime modulus: comptime_int) type {
    if (modulus % 2 == 0) @compileError("Montgomery form needs an odd modulus");
    if (modulus >= 1 << (32 * words)) @compileError("the modulus does not fit its words");

    return struct {
        const Self = @This();

        /// A number of the field, as words; in Montgomery form unless a
        /// function says otherwise.
        pub const Number = [words]u32;

        /// How many words, and the bytes the modulus takes.
        pub const word_count = words;
        pub const byte_count = (bitLength(modulus) + 7) / 8;
        pub const bit_count = bitLength(modulus);

        pub const m: Number = wordsOf(modulus, words);
        /// -m^-1 mod 2^32.
        const m_prime: u32 = blk: {
            const low: u32 = @intCast(modulus & 0xFFFF_FFFF);
            var inverse: u32 = low;
            for (0..5) |_| inverse *%= 2 -% low *% inverse;
            break :blk 0 -% inverse;
        };
        const r2: Number = wordsOf((1 << (64 * words)) % modulus, words);

        pub const zero: Number = @splat(0);
        /// 1, in Montgomery form.
        pub const one: Number = wordsOf((1 << (32 * words)) % modulus, words);

        /// A constant, in Montgomery form, from its value.
        pub fn constant(comptime value: comptime_int) Number {
            return comptime wordsOf((value << (32 * words)) % modulus, words);
        }

        /// a * b, both in Montgomery form.
        pub fn mul(a: *const Number, b: *const Number) Number {
            @setRuntimeSafety(false);
            var t: [words + 2]u32 = @splat(0);
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

                const factor: u32 = t[0] *% m_prime;
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
            return subtractOnce(t[0..words].*, t[words]);
        }

        pub fn square(a: *const Number) Number {
            return mul(a, a);
        }

        pub fn add(a: *const Number, b: *const Number) Number {
            @setRuntimeSafety(false);
            var sum: Number = undefined;
            var carry: u32 = 0;
            for (0..words) |j| {
                const total = @as(u64, a[j]) + b[j] + carry;
                sum[j] = @truncate(total);
                carry = @truncate(total >> 32);
            }
            return subtractOnce(sum, carry);
        }

        pub fn sub(a: *const Number, b: *const Number) Number {
            @setRuntimeSafety(false);
            var difference: Number = undefined;
            var borrow: u32 = 0;
            for (0..words) |j| {
                const total = @as(u64, a[j]) -% b[j] -% borrow;
                difference[j] = @truncate(total);
                borrow = @truncate((total >> 32) & 1);
            }
            // Below zero: the modulus added back.
            const mask = 0 -% borrow;
            var carry: u32 = 0;
            for (0..words) |j| {
                const total = @as(u64, difference[j]) + (m[j] & mask) + carry;
                difference[j] = @truncate(total);
                carry = @truncate(total >> 32);
            }
            return difference;
        }

        pub fn negate(a: *const Number) Number {
            return sub(&zero, a);
        }

        /// `value` (and `high`, a word above it) less the modulus if it
        /// came to the modulus or more; `value` is below twice it.
        fn subtractOnce(value: Number, high: u32) Number {
            @setRuntimeSafety(false);
            var less: Number = undefined;
            var borrow: u32 = 0;
            for (0..words) |j| {
                const total = @as(u64, value[j]) -% m[j] -% borrow;
                less[j] = @truncate(total);
                borrow = @truncate((total >> 32) & 1);
            }
            // At least the modulus: a word above, or no borrow.
            const mask = 0 -% ((high | (borrow ^ 1)) & 1);
            var out: Number = undefined;
            for (0..words) |j| out[j] = (less[j] & mask) | (value[j] & ~mask);
            return out;
        }

        /// A number below R into Montgomery form, reduced on the way.
        pub fn toMontgomery(value: *const Number) Number {
            return mul(value, &r2);
        }

        /// A number out of Montgomery form, fully reduced.
        pub fn fromMontgomery(value: *const Number) Number {
            var unit: Number = zero;
            unit[0] = 1;
            return mul(value, &unit);
        }

        /// `value` to the power of `exponent`, which is public and fixed.
        pub fn powPublic(value: *const Number, comptime exponent: comptime_int) Number {
            const bits = comptime bitLength(exponent);
            const exponent_words = comptime wordsOf(exponent, wordCount(exponent));
            var result = one;
            var bit: usize = bits;
            while (bit > 0) {
                bit -= 1;
                result = square(&result);
                if ((exponent_words[bit / 32] >> @intCast(bit % 32)) & 1 != 0) result = mul(&result, value);
            }
            return result;
        }

        /// 1 / value, by Fermat: value^(m - 2). Zero gives zero.
        pub fn invert(value: *const Number) Number {
            return powPublic(value, modulus - 2);
        }

        /// All ones if `value` is zero, else 0.
        pub fn isZeroMask(value: *const Number) u32 {
            var any: u32 = 0;
            for (value) |word| any |= word;
            // 0 -> 1 -> all ones; anything else -> 0.
            return 0 -% (((any | (0 -% any)) >> 31) ^ 1);
        }

        /// All ones if a and b are the same number, else 0.
        pub fn equalMask(a: *const Number, b: *const Number) u32 {
            const difference = sub(a, b);
            return isZeroMask(&difference);
        }

        /// `a` where `mask` is all ones, `b` where it is 0.
        pub fn select(mask: u32, a: *const Number, b: *const Number) Number {
            @setRuntimeSafety(false);
            var out: Number = undefined;
            for (0..words) |j| out[j] = (a[j] & mask) | (b[j] & ~mask);
            return out;
        }

        /// a and b exchanged where `mask` is all ones.
        pub fn swap(mask: u32, a: *Number, b: *Number) void {
            @setRuntimeSafety(false);
            for (0..words) |j| {
                const difference = (a[j] ^ b[j]) & mask;
                a[j] ^= difference;
                b[j] ^= difference;
            }
        }

        /// A number from `byte_count` bytes, most significant first, into
        /// Montgomery form; null when it is not below the modulus.
        pub fn fromBytesBig(bytes: *const [byte_count]u8) ?Number {
            var value: Number = zero;
            for (0..byte_count) |index| {
                const byte = bytes[byte_count - 1 - index];
                value[index / 4] |= @as(u32, byte) << @intCast(8 * (index % 4));
            }
            if (!below(&value)) return null;
            return toMontgomery(&value);
        }

        /// The same, least significant byte first.
        pub fn fromBytesLittle(bytes: *const [byte_count]u8) ?Number {
            var value: Number = zero;
            for (0..byte_count) |index| value[index / 4] |= @as(u32, bytes[index]) << @intCast(8 * (index % 4));
            if (!below(&value)) return null;
            return toMontgomery(&value);
        }

        /// A number out of Montgomery form into bytes, most significant
        /// first.
        pub fn toBytesBig(value: *const Number, bytes: *[byte_count]u8) void {
            const plain = fromMontgomery(value);
            for (0..byte_count) |index| bytes[byte_count - 1 - index] = @truncate(plain[index / 4] >> @intCast(8 * (index % 4)));
        }

        /// The same, least significant byte first.
        pub fn toBytesLittle(value: *const Number, bytes: *[byte_count]u8) void {
            const plain = fromMontgomery(value);
            for (0..byte_count) |index| bytes[index] = @truncate(plain[index / 4] >> @intCast(8 * (index % 4)));
        }

        /// Whether a plain number (not in Montgomery form) is below the
        /// modulus. Public data only: it answers by a branch.
        pub fn below(value: *const Number) bool {
            var index: usize = words;
            while (index > 0) {
                index -= 1;
                if (value[index] != m[index]) return value[index] < m[index];
            }
            return false;
        }

        /// Whether a plain number is zero.
        pub fn isZeroPlain(value: *const Number) bool {
            for (value) |word| if (word != 0) return false;
            return true;
        }
    };
}

/// The bits a number takes.
pub fn bitLength(comptime value: comptime_int) comptime_int {
    var bits = 0;
    var left = value;
    while (left != 0) : (left >>= 1) bits += 1;
    return bits;
}

/// A number as `count` words, least significant first.
pub fn wordsOf(comptime value: comptime_int, comptime count: comptime_int) [count]u32 {
    @setEvalBranchQuota(100_000);
    var out: [count]u32 = undefined;
    var left = value;
    for (&out) |*word| {
        word.* = @intCast(left & 0xFFFF_FFFF);
        left >>= 32;
    }
    return out;
}

pub fn wordCount(comptime value: comptime_int) comptime_int {
    return @max((bitLength(value) + 31) / 32, 1);
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

fn plainOf(comptime F: type, value: u512) F.Number {
    var out: F.Number = undefined;
    var left = value;
    for (&out) |*word| {
        word.* = @truncate(left);
        left >>= 32;
    }
    return out;
}

fn valueOf(comptime F: type, number: *const F.Number) u512 {
    var out: u512 = 0;
    var index: usize = F.word_count;
    while (index > 0) {
        index -= 1;
        out = out << 32 | number[index];
    }
    return out;
}

fn checkField(comptime words: comptime_int, comptime modulus: comptime_int) !void {
    const F = Field(words, modulus);
    var random = std.Random.DefaultPrng.init(0x5EED_0000 + words);
    const p: u512 = modulus;
    for (0..300) |_| {
        const a: u512 = @as(u512, random.random().int(u384)) % p;
        const b: u512 = @as(u512, random.random().int(u384)) % p;
        const am = F.toMontgomery(&plainOf(F, a));
        const bm = F.toMontgomery(&plainOf(F, b));
        const product = F.fromMontgomery(&F.mul(&am, &bm));
        try testing.expectEqual(@as(u1024, a) * b % p, valueOf(F, &product));
        const sum = F.fromMontgomery(&F.add(&am, &bm));
        try testing.expectEqual((a + b) % p, valueOf(F, &sum));
        const difference = F.fromMontgomery(&F.sub(&am, &bm));
        try testing.expectEqual((a + p - b) % p, valueOf(F, &difference));
        if (a != 0) {
            const inverse = F.invert(&am);
            const unit = F.fromMontgomery(&F.mul(&inverse, &am));
            try testing.expectEqual(@as(u512, 1), valueOf(F, &unit));
        }
        try testing.expectEqual(@as(u32, 0), F.equalMask(&am, &F.add(&am, &F.one)));
        try testing.expectEqual(~@as(u32, 0), F.equalMask(&am, &am));
    }
}

test "the field arithmetic against big integers" {
    try checkField(8, (1 << 255) - 19);
    try checkField(8, (1 << 256) - (1 << 224) + (1 << 192) + (1 << 96) - 1);
    try checkField(12, (1 << 384) - (1 << 128) - (1 << 96) + (1 << 32) - 1);
    try checkField(8, (1 << 252) + 27742317777372353535851937790883648493);
}

// SPDX-License-Identifier: MIT
//! The two checksums the wrappings carry, as the engines and the two
//! calls (Crc32, Adler32) share them: CRC-32 for gzip, Adler-32 for zlib.
//!
//! CRC-32 is the reflected polynomial 0xEDB88320, the running value kept
//! inverted between bytes and turned the right way out at each end, so
//! that a value handed back is the CRC of everything so far and may be
//! handed in again. There are three ways through the bytes, and the
//! library picks one when it is made (`Path`):
//!
//! - `tables`, on every chip: eight bytes a step from eight 256-entry
//!   tables made at compile time, a byte a step up to a word's boundary
//!   and for what is left.
//! - `products`, on an x86-64 core with the carry-less product
//!   (PCLMULQDQ): 64 bytes a step. Four 128-bit blocks are each carried
//!   past the next 512 bits by two products with x^(512+-32) mod P and
//!   summed with the four blocks found there; the four are folded into
//!   one, that one carried on 16 bytes a step, and the last 16 bytes it
//!   holds and the bytes after them go through the tables. The system is
//!   built for x86-64-v2, which has no such instruction, so it is written
//!   in its SSE encoding; it works in the 128-bit registers every task
//!   has.
//! - `instructions`, on an AArch64 core with CRC32: `crc32x`, eight
//!   bytes an instruction, the rest by `crc32b`.
//!
//! Adler-32 is the two sums modulo 65521, the modulo taken once per 5552
//! bytes, the most that cannot overflow 32 bits.

const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("the tables take a word's first byte as its lowest");
}

/// How CRC-32 goes through the bytes: what the core has, asked once when
/// the library is made.
pub const Path = enum(u8) { tables, products, instructions };

/// Whether a path's code is in this build at all.
pub const has_products = builtin.cpu.arch == .x86_64;
pub const has_instructions = builtin.cpu.arch == .aarch64;

/// Table 0 is a byte's; table n a byte's with n zero bytes after it.
const crc_tables = blk: {
    @setEvalBranchQuota(40000);
    var tables: [8][256]u32 = undefined;
    for (&tables[0], 0..) |*entry, index| {
        var crc: u32 = index;
        for (0..8) |_| crc = if (crc & 1 != 0) 0xEDB8_8320 ^ (crc >> 1) else crc >> 1;
        entry.* = crc;
    }
    for (1..8) |table| {
        for (&tables[table], 0..) |*entry, index| {
            const before = tables[table - 1][index];
            entry.* = tables[0][before & 0xFF] ^ (before >> 8);
        }
    }
    break :blk tables;
};

/// `crc` (the CRC-32 of what came before, 0 for nothing) carried on over
/// `bytes`, by `path`.
pub fn crc32(path: Path, crc: u32, bytes: []const u8) u32 {
    const value = ~crc;
    return ~switch (path) {
        .tables => byTables(value, bytes),
        .products => if (has_products) byProducts(value, bytes) else byTables(value, bytes),
        .instructions => if (has_instructions) byInstructions(value, bytes) else byTables(value, bytes),
    };
}

fn byByte(value: u32, byte: u8) u32 {
    return crc_tables[0][(value ^ byte) & 0xFF] ^ (value >> 8);
}

/// The running value carried over `bytes`, eight at a time once the
/// address is a word's.
fn byTables(running: u32, bytes: []const u8) u32 {
    const t = &crc_tables;
    var value = running;
    var at: usize = 0;
    while (at < bytes.len and (@intFromPtr(bytes.ptr) + at) & 3 != 0) : (at += 1) value = byByte(value, bytes[at]);
    while (bytes.len - at >= 8) : (at += 8) {
        const words: *const [2]u32 = @ptrCast(@alignCast(bytes.ptr + at));
        const low = words[0] ^ value;
        const high = words[1];
        value = t[7][low & 0xFF] ^ t[6][(low >> 8) & 0xFF] ^ t[5][(low >> 16) & 0xFF] ^ t[4][low >> 24] ^
            t[3][high & 0xFF] ^ t[2][(high >> 8) & 0xFF] ^ t[1][(high >> 16) & 0xFF] ^ t[0][high >> 24];
    }
    while (at < bytes.len) : (at += 1) value = byByte(value, bytes[at]);
    return value;
}

// --- x86-64: carry-less products ---------------------------------------------------

/// A 128-bit block in a register: its 16 bytes in memory order.
const Block = @Vector(2, u64);

/// x^(512+32) mod P and x^(512-32) mod P, x^(128+32) mod P and
/// x^(128-32) mod P, each bit-reflected and moved up a bit: what carries
/// a block past 512 bits, and past 128.
const fold_512: Block = .{ 0x01_5444_2BD4, 0x01_C6E4_1596 };
const fold_128: Block = .{ 0x01_7519_97D0, 0x00_CCAA_009E };

inline fn load(bytes: [*]const u8) Block {
    return @bitCast(@as(*align(1) const [16]u8, @ptrCast(bytes)).*);
}

/// x * y without carries: the low halves of both, or the high halves.
inline fn productLow(x: Block, y: Block) Block {
    return asm ("pclmulqdq $0, %[y], %[out]"
        : [out] "=x" (-> Block),
        : [in] "0" (x),
          [y] "x" (y),
    );
}

inline fn productHigh(x: Block, y: Block) Block {
    return asm ("pclmulqdq $17, %[y], %[out]"
        : [out] "=x" (-> Block),
        : [in] "0" (x),
          [y] "x" (y),
    );
}

/// `block` carried past as many bits as `by` is for, and `next` - what
/// is found there - added.
inline fn fold(block: Block, by: Block, next: Block) Block {
    return productLow(block, by) ^ productHigh(block, by) ^ next;
}

/// The running value carried over `bytes` by products; a run too short
/// for them goes through the tables.
fn byProducts(running: u32, bytes: []const u8) u32 {
    if (bytes.len < 64) return byTables(running, bytes);
    var from = bytes.ptr;
    var left = bytes.len;
    // The running value is the same as nothing before a message whose
    // first four bytes have it added.
    var first = load(from) ^ Block{ running, 0 };
    var second = load(from + 16);
    var third = load(from + 32);
    var fourth = load(from + 48);
    from += 64;
    left -= 64;
    while (left >= 64) : ({
        from += 64;
        left -= 64;
    }) {
        first = fold(first, fold_512, load(from));
        second = fold(second, fold_512, load(from + 16));
        third = fold(third, fold_512, load(from + 32));
        fourth = fold(fourth, fold_512, load(from + 48));
    }
    // The four into one, each carried past the next.
    var one = fold(first, fold_128, second);
    one = fold(one, fold_128, third);
    one = fold(one, fold_128, fourth);
    while (left >= 16) : ({
        from += 16;
        left -= 16;
    }) one = fold(one, fold_128, load(from));
    // What the block holds is 16 bytes of a message with nothing before
    // them, and the rest follows.
    const held: [16]u8 align(8) = @bitCast(one);
    return byTables(byTables(0, &held), from[0..left]);
}

// --- AArch64: the core's CRC32 instructions ----------------------------------------

inline fn crcWord(value: u32, word: u64) u32 {
    return @truncate(asm ("crc32x w0, w0, x1"
        : [out] "={x0}" (-> u64),
        : [value] "{x0}" (@as(u64, value)),
          [word] "{x1}" (word),
    ));
}

inline fn crcByte(value: u32, byte: u8) u32 {
    return @truncate(asm ("crc32b w0, w0, w1"
        : [out] "={x0}" (-> u64),
        : [value] "{x0}" (@as(u64, value)),
          [byte] "{x1}" (@as(u64, byte)),
    ));
}

/// The running value carried over `bytes` by the core's instructions.
fn byInstructions(running: u32, bytes: []const u8) u32 {
    var value = running;
    var at: usize = 0;
    while (bytes.len - at >= 8) : (at += 8) {
        value = crcWord(value, @as(*align(1) const u64, @ptrCast(bytes.ptr + at)).*);
    }
    while (at < bytes.len) : (at += 1) value = crcByte(value, bytes[at]);
    return value;
}

const adler_base = 65521;
/// The most bytes the sums take before they must be brought down.
const adler_run = 5552;

/// `adler` (the Adler-32 of what came before, 1 for nothing) carried on
/// over `bytes`.
pub fn adler32(adler: u32, bytes: []const u8) u32 {
    var low = adler & 0xFFFF;
    var high = adler >> 16;
    var rest = bytes;
    while (rest.len > 0) {
        const run = @min(rest.len, adler_run);
        for (rest[0..run]) |byte| {
            low += byte;
            high += low;
        }
        low %= adler_base;
        high %= adler_base;
        rest = rest[run..];
    }
    return high << 16 | low;
}

// --- tests (host) ------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// CRC-32 a bit at a time: what every path is held against.
fn plain(crc: u32, bytes: []const u8) u32 {
    var value = ~crc;
    for (bytes) |byte| {
        value ^= byte;
        for (0..8) |_| value = if (value & 1 != 0) 0xEDB8_8320 ^ (value >> 1) else value >> 1;
    }
    return ~value;
}

/// The paths this host can run.
fn paths() []const Path {
    const products_here = comptime has_products and std.Target.x86.featureSetHas(builtin.cpu.features, .pclmul);
    const instructions_here = comptime has_instructions and std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc);
    if (products_here) return &.{ .tables, .products };
    if (instructions_here) return &.{ .tables, .instructions };
    return &.{.tables};
}

test "CRC-32 of the check string" {
    for (paths()) |path| try testing.expectEqual(@as(u32, 0xCBF4_3926), crc32(path, 0, "123456789"));
}

test "every path agrees with the bit-by-bit CRC at every length and alignment" {
    var bytes: [8 + 700]u8 align(16) = undefined;
    var random = std.Random.DefaultPrng.init(0x1EDC_6F41);
    random.random().bytes(&bytes);
    for (paths()) |path| {
        for (0..8) |offset| {
            for (0..301) |length| {
                const run = bytes[offset..][0..length];
                try testing.expectEqual(plain(0, run), crc32(path, 0, run));
            }
            // Long enough for several steps of 64 bytes and a tail.
            const long = bytes[offset..][0..689];
            try testing.expectEqual(plain(0x1234_5678, long), crc32(path, 0x1234_5678, long));
        }
    }
}

test "a CRC carried across calls is the CRC of the whole, cut anywhere" {
    var bytes: [400]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x04C1_1DB7);
    random.random().bytes(&bytes);
    const whole = plain(0, &bytes);
    for (paths()) |path| {
        for (0..bytes.len + 1) |cut| {
            try testing.expectEqual(whole, crc32(path, crc32(path, 0, bytes[0..cut]), bytes[cut..]));
        }
        // And from one path to another.
        try testing.expectEqual(whole, crc32(.tables, crc32(path, 0, bytes[0..200]), bytes[200..]));
    }
}

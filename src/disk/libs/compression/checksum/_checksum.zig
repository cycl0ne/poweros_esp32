// SPDX-License-Identifier: MIT
//! The two checksums the wrappings carry, as the engines and the two
//! calls (Crc32, Adler32) share them: CRC-32 for gzip, Adler-32 for zlib.
//!
//! CRC-32 is the reflected polynomial 0xEDB88320 by a 256-entry table
//! made at compile time, the running value kept inverted between bytes
//! and turned the right way out at each end, so that a value handed back
//! is the CRC of everything so far and may be handed in again. Adler-32
//! is the two sums modulo 65521, the modulo taken once per 5552 bytes,
//! the most that cannot overflow 32 bits.

const crc_table = blk: {
    @setEvalBranchQuota(4000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, index| {
        var crc: u32 = index;
        for (0..8) |_| crc = if (crc & 1 != 0) 0xEDB8_8320 ^ (crc >> 1) else crc >> 1;
        entry.* = crc;
    }
    break :blk table;
};

/// `crc` (the CRC-32 of what came before, 0 for nothing) carried on over
/// `bytes`.
pub fn crc32(crc: u32, bytes: []const u8) u32 {
    var value = ~crc;
    for (bytes) |byte| value = crc_table[(value ^ byte) & 0xFF] ^ (value >> 8);
    return ~value;
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

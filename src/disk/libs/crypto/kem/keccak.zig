// SPDX-License-Identifier: MIT
//! Keccak (FIPS 202): the permutation Keccak-f[1600] and the sponge on
//! it, as ML-KEM needs it - SHA3-256, SHA3-512, SHAKE128 and SHAKE256.
//!
//! **The sponge** takes its input `rate` bytes at a time into the first
//! bytes of its 200-byte state, permuting after each block; the end of the
//! input is marked with the function's suffix bits and a final 1 bit at
//! the end of the rate (SHA3: 0x06, SHAKE: 0x1F). Output is the state's
//! first `rate` bytes, permuted again for each further block. The state's
//! bytes are its 25 lanes of 64 bits, each least significant byte first.

/// The rates: SHA3-256 and SHAKE256, SHA3-512, SHAKE128.
pub const rate_256 = 136;
pub const rate_512 = 72;
pub const rate_shake128 = 168;

const suffix_sha3: u8 = 0x06;
const suffix_shake: u8 = 0x1F;

const round_constants = [24]u64{
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
};

/// The rotation of each lane, at x + 5y.
const rotations = [25]u6{
    0,  1,  62, 28, 27,
    36, 44, 6,  55, 20,
    3,  10, 43, 25, 39,
    41, 45, 15, 21, 8,
    18, 2,  61, 56, 14,
};

fn rotate(value: u64, amount: u6) u64 {
    if (amount == 0) return value;
    return (value << amount) | (value >> @intCast(@as(u7, 64) - amount));
}

/// Keccak-f[1600], 24 rounds of theta, rho and pi, chi and iota.
pub fn permute(lanes: *[25]u64) void {
    for (round_constants) |constant| {
        var columns: [5]u64 = undefined;
        for (0..5) |x| columns[x] = lanes[x] ^ lanes[x + 5] ^ lanes[x + 10] ^ lanes[x + 15] ^ lanes[x + 20];
        for (0..5) |x| {
            const mix = columns[(x + 4) % 5] ^ rotate(columns[(x + 1) % 5], 1);
            var y: usize = 0;
            while (y < 25) : (y += 5) lanes[x + y] ^= mix;
        }
        var moved: [25]u64 = undefined;
        for (0..5) |x| {
            for (0..5) |y| moved[y + 5 * ((2 * x + 3 * y) % 5)] = rotate(lanes[x + 5 * y], rotations[x + 5 * y]);
        }
        for (0..5) |y| {
            for (0..5) |x| {
                lanes[x + 5 * y] = moved[x + 5 * y] ^ (~moved[(x + 1) % 5 + 5 * y] & moved[(x + 2) % 5 + 5 * y]);
            }
        }
        lanes[0] ^= constant;
    }
}

/// One sponge: absorbing until `finish`, then squeezing.
pub const Sponge = struct {
    lanes: [25]u64 = @splat(0),
    rate: usize,
    suffix: u8,
    /// Where in the rate the next byte goes in or comes out.
    offset: usize = 0,

    pub fn sha3(rate: usize) Sponge {
        return .{ .rate = rate, .suffix = suffix_sha3 };
    }

    pub fn shake(rate: usize) Sponge {
        return .{ .rate = rate, .suffix = suffix_shake };
    }

    fn mixByte(sponge: *Sponge, at: usize, byte: u8) void {
        sponge.lanes[at / 8] ^= @as(u64, byte) << @intCast((at % 8) * 8);
    }

    fn byteAt(sponge: *const Sponge, at: usize) u8 {
        return @truncate(sponge.lanes[at / 8] >> @intCast((at % 8) * 8));
    }

    pub fn absorb(sponge: *Sponge, data: []const u8) void {
        for (data) |byte| {
            sponge.mixByte(sponge.offset, byte);
            sponge.offset += 1;
            if (sponge.offset == sponge.rate) {
                permute(&sponge.lanes);
                sponge.offset = 0;
            }
        }
    }

    /// The end of the input: the padding, and the first output ready.
    pub fn finish(sponge: *Sponge) void {
        sponge.mixByte(sponge.offset, sponge.suffix);
        sponge.mixByte(sponge.rate - 1, 0x80);
        permute(&sponge.lanes);
        sponge.offset = 0;
    }

    pub fn squeeze(sponge: *Sponge, out: []u8) void {
        for (out) |*byte| {
            if (sponge.offset == sponge.rate) {
                permute(&sponge.lanes);
                sponge.offset = 0;
            }
            byte.* = sponge.byteAt(sponge.offset);
            sponge.offset += 1;
        }
    }

    /// The state cleared, for what it held about a secret.
    pub fn wipe(sponge: *Sponge) void {
        const volatile_lanes: *volatile [25]u64 = &sponge.lanes;
        for (volatile_lanes) |*lane| lane.* = 0;
    }
};

/// SHA3-256 of the parts, one after another.
pub fn digest256(parts: []const []const u8, out: *[32]u8) void {
    var sponge = Sponge.sha3(rate_256);
    for (parts) |part| sponge.absorb(part);
    sponge.finish();
    sponge.squeeze(out);
    sponge.wipe();
}

/// SHA3-512 of the parts.
pub fn digest512(parts: []const []const u8, out: *[64]u8) void {
    var sponge = Sponge.sha3(rate_512);
    for (parts) |part| sponge.absorb(part);
    sponge.finish();
    sponge.squeeze(out);
    sponge.wipe();
}

/// SHAKE256 of the parts, as many bytes as `out` holds.
pub fn shake256(parts: []const []const u8, out: []u8) void {
    var sponge = Sponge.shake(rate_256);
    for (parts) |part| sponge.absorb(part);
    sponge.finish();
    sponge.squeeze(out);
    sponge.wipe();
}

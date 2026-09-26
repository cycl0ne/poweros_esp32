// SPDX-License-Identifier: MIT
//! The SHA engine as software, for the host: the same blocks, the same
//! START and CONTINUE, the same state layout (the digest's own byte
//! order). FIPS 180-4's compression functions for SHA-1, SHA-256 and
//! SHA-512; SHA-224 and SHA-384 are the last two with their own initial
//! state.

const crypto = @import("sdk").crypto;
const _engine = @import("_engine.zig");

pub fn run(algorithm: u32, state: *[16]u32, first: bool, data: [*]const u8, blocks: u32) void {
    const bytes: [*]u8 = @ptrCast(state);
    switch (algorithm) {
        crypto.HASH_SHA1 => {
            var h: [5]u32 = sha1_iv;
            if (!first) {
                for (&h, 0..) |*word, index| word.* = _engine.loadBig(bytes + 4 * index);
            }
            for (0..blocks) |block| sha1Block(&h, data + 64 * block);
            for (h, 0..) |word, index| _engine.storeBig(bytes + 4 * index, word);
        },
        crypto.HASH_SHA224, crypto.HASH_SHA256 => {
            var h: [8]u32 = if (algorithm == crypto.HASH_SHA224) sha224_iv else sha256_iv;
            if (!first) {
                for (&h, 0..) |*word, index| word.* = _engine.loadBig(bytes + 4 * index);
            }
            for (0..blocks) |block| sha256Block(&h, data + 64 * block);
            for (h, 0..) |word, index| _engine.storeBig(bytes + 4 * index, word);
        },
        else => {
            var h: [8]u64 = if (algorithm == crypto.HASH_SHA384) sha384_iv else sha512_iv;
            if (!first) {
                for (&h, 0..) |*word, index| word.* = load64(bytes + 8 * index);
            }
            for (0..blocks) |block| sha512Block(&h, data + 128 * block);
            for (h, 0..) |word, index| {
                _engine.storeBig(bytes + 8 * index, @truncate(word >> 32));
                _engine.storeBig(bytes + 8 * index + 4, @truncate(word));
            }
        },
    }
}

fn load64(bytes: [*]const u8) u64 {
    return @as(u64, _engine.loadBig(bytes)) << 32 | _engine.loadBig(bytes + 4);
}

fn rotr32(value: u32, comptime by: u5) u32 {
    return value >> by | value << comptime @as(u5, @intCast(32 - @as(u6, by)));
}

fn rotl32(value: u32, comptime by: u5) u32 {
    return value << by | value >> comptime @as(u5, @intCast(32 - @as(u6, by)));
}

fn rotr64(value: u64, comptime by: u6) u64 {
    return value >> by | value << comptime @as(u6, @intCast(64 - @as(u7, by)));
}

// --- SHA-1 ------------------------------------------------------------------

const sha1_iv = [5]u32{ 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 };

fn sha1Block(h: *[5]u32, block: [*]const u8) void {
    var w: [80]u32 = undefined;
    for (0..16) |index| w[index] = _engine.loadBig(block + 4 * index);
    for (16..80) |index| w[index] = rotl32(w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16], 1);
    var a = h[0];
    var b = h[1];
    var c = h[2];
    var d = h[3];
    var e = h[4];
    for (0..80) |index| {
        const f, const k = if (index < 20)
            .{ (b & c) | (~b & d), @as(u32, 0x5A827999) }
        else if (index < 40)
            .{ b ^ c ^ d, @as(u32, 0x6ED9EBA1) }
        else if (index < 60)
            .{ (b & c) | (b & d) | (c & d), @as(u32, 0x8F1BBCDC) }
        else
            .{ b ^ c ^ d, @as(u32, 0xCA62C1D6) };
        const t = rotl32(a, 5) +% f +% e +% k +% w[index];
        e = d;
        d = c;
        c = rotl32(b, 30);
        b = a;
        a = t;
    }
    h[0] +%= a;
    h[1] +%= b;
    h[2] +%= c;
    h[3] +%= d;
    h[4] +%= e;
}

// --- SHA-256 ----------------------------------------------------------------

const sha224_iv = [8]u32{ 0xC1059ED8, 0x367CD507, 0x3070DD17, 0xF70E5939, 0xFFC00B31, 0x68581511, 0x64F98FA7, 0xBEFA4FA4 };
const sha256_iv = [8]u32{ 0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19 };

const k256 = [64]u32{
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
};

fn sha256Block(h: *[8]u32, block: [*]const u8) void {
    var w: [64]u32 = undefined;
    for (0..16) |index| w[index] = _engine.loadBig(block + 4 * index);
    for (16..64) |index| {
        const s0 = rotr32(w[index - 15], 7) ^ rotr32(w[index - 15], 18) ^ (w[index - 15] >> 3);
        const s1 = rotr32(w[index - 2], 17) ^ rotr32(w[index - 2], 19) ^ (w[index - 2] >> 10);
        w[index] = w[index - 16] +% s0 +% w[index - 7] +% s1;
    }
    var v = h.*;
    for (0..64) |index| {
        const s1 = rotr32(v[4], 6) ^ rotr32(v[4], 11) ^ rotr32(v[4], 25);
        const ch = (v[4] & v[5]) ^ (~v[4] & v[6]);
        const t1 = v[7] +% s1 +% ch +% k256[index] +% w[index];
        const s0 = rotr32(v[0], 2) ^ rotr32(v[0], 13) ^ rotr32(v[0], 22);
        const maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
        const t2 = s0 +% maj;
        // A new array: assigned in place, v[1] would read the new v[0].
        const next: @TypeOf(v) = .{ t1 +% t2, v[0], v[1], v[2], v[3] +% t1, v[4], v[5], v[6] };
        v = next;
    }
    for (h, v) |*word, add| word.* +%= add;
}

// --- SHA-512 ----------------------------------------------------------------

const sha384_iv = [8]u64{
    0xCBBB9D5DC1059ED8, 0x629A292A367CD507, 0x9159015A3070DD17, 0x152FECD8F70E5939,
    0x67332667FFC00B31, 0x8EB44A8768581511, 0xDB0C2E0D64F98FA7, 0x47B5481DBEFA4FA4,
};
const sha512_iv = [8]u64{
    0x6A09E667F3BCC908, 0xBB67AE8584CAA73B, 0x3C6EF372FE94F82B, 0xA54FF53A5F1D36F1,
    0x510E527FADE682D1, 0x9B05688C2B3E6C1F, 0x1F83D9ABFB41BD6B, 0x5BE0CD19137E2179,
};

const k512 = [80]u64{
    0x428A2F98D728AE22, 0x7137449123EF65CD, 0xB5C0FBCFEC4D3B2F, 0xE9B5DBA58189DBBC, 0x3956C25BF348B538,
    0x59F111F1B605D019, 0x923F82A4AF194F9B, 0xAB1C5ED5DA6D8118, 0xD807AA98A3030242, 0x12835B0145706FBE,
    0x243185BE4EE4B28C, 0x550C7DC3D5FFB4E2, 0x72BE5D74F27B896F, 0x80DEB1FE3B1696B1, 0x9BDC06A725C71235,
    0xC19BF174CF692694, 0xE49B69C19EF14AD2, 0xEFBE4786384F25E3, 0x0FC19DC68B8CD5B5, 0x240CA1CC77AC9C65,
    0x2DE92C6F592B0275, 0x4A7484AA6EA6E483, 0x5CB0A9DCBD41FBD4, 0x76F988DA831153B5, 0x983E5152EE66DFAB,
    0xA831C66D2DB43210, 0xB00327C898FB213F, 0xBF597FC7BEEF0EE4, 0xC6E00BF33DA88FC2, 0xD5A79147930AA725,
    0x06CA6351E003826F, 0x142929670A0E6E70, 0x27B70A8546D22FFC, 0x2E1B21385C26C926, 0x4D2C6DFC5AC42AED,
    0x53380D139D95B3DF, 0x650A73548BAF63DE, 0x766A0ABB3C77B2A8, 0x81C2C92E47EDAEE6, 0x92722C851482353B,
    0xA2BFE8A14CF10364, 0xA81A664BBC423001, 0xC24B8B70D0F89791, 0xC76C51A30654BE30, 0xD192E819D6EF5218,
    0xD69906245565A910, 0xF40E35855771202A, 0x106AA07032BBD1B8, 0x19A4C116B8D2D0C8, 0x1E376C085141AB53,
    0x2748774CDF8EEB99, 0x34B0BCB5E19B48A8, 0x391C0CB3C5C95A63, 0x4ED8AA4AE3418ACB, 0x5B9CCA4F7763E373,
    0x682E6FF3D6B2B8A3, 0x748F82EE5DEFB2FC, 0x78A5636F43172F60, 0x84C87814A1F0AB72, 0x8CC702081A6439EC,
    0x90BEFFFA23631E28, 0xA4506CEBDE82BDE9, 0xBEF9A3F7B2C67915, 0xC67178F2E372532B, 0xCA273ECEEA26619C,
    0xD186B8C721C0C207, 0xEADA7DD6CDE0EB1E, 0xF57D4F7FEE6ED178, 0x06F067AA72176FBA, 0x0A637DC5A2C898A6,
    0x113F9804BEF90DAE, 0x1B710B35131C471B, 0x28DB77F523047D84, 0x32CAAB7B40C72493, 0x3C9EBE0A15C9BEBC,
    0x431D67C49C100D4C, 0x4CC5D4BECB3E42B6, 0x597F299CFC657E2A, 0x5FCB6FAB3AD6FAEC, 0x6C44198C4A475817,
};

fn sha512Block(h: *[8]u64, block: [*]const u8) void {
    var w: [80]u64 = undefined;
    for (0..16) |index| w[index] = load64(block + 8 * index);
    for (16..80) |index| {
        const s0 = rotr64(w[index - 15], 1) ^ rotr64(w[index - 15], 8) ^ (w[index - 15] >> 7);
        const s1 = rotr64(w[index - 2], 19) ^ rotr64(w[index - 2], 61) ^ (w[index - 2] >> 6);
        w[index] = w[index - 16] +% s0 +% w[index - 7] +% s1;
    }
    var v = h.*;
    for (0..80) |index| {
        const s1 = rotr64(v[4], 14) ^ rotr64(v[4], 18) ^ rotr64(v[4], 41);
        const ch = (v[4] & v[5]) ^ (~v[4] & v[6]);
        const t1 = v[7] +% s1 +% ch +% k512[index] +% w[index];
        const s0 = rotr64(v[0], 28) ^ rotr64(v[0], 34) ^ rotr64(v[0], 39);
        const maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
        const t2 = s0 +% maj;
        // A new array: assigned in place, v[1] would read the new v[0].
        const next: @TypeOf(v) = .{ t1 +% t2, v[0], v[1], v[2], v[3] +% t1, v[4], v[5], v[6] };
        v = next;
    }
    for (h, v) |*word, add| word.* +%= add;
}

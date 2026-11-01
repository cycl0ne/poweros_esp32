// SPDX-License-Identifier: MIT
//! The H.265 standard's tables (ITU-T H.265 v8, 2021) that the decoder
//! looks up: scan orders, the transform matrices, the intra angles, the
//! interpolation filters and the deblocking thresholds. What can be
//! worked out is worked out at compile time and checked by the tests
//! against the standard's printed values.

/// ScanOrder[ log2BlockSize ][ scanIdx ][ sPos ] (6.5.3 to 6.5.5) for
/// blocks of 1, 2, 4 and 8 on a side: x in the low nibble, y in the
/// high. scanIdx 0 is the up-right diagonal, 1 horizontal, 2 vertical.
pub const scan: [4][3][64]u8 = blk: {
    @setEvalBranchQuota(20000);
    var t: [4][3][64]u8 = undefined;
    for (0..4) |log2| {
        const n: usize = 1 << log2;
        // Up-right diagonal: each diagonal from its bottom-left.
        var i: usize = 0;
        var x: isize = 0;
        var y: isize = 0;
        while (i < n * n) {
            while (y >= 0) {
                if (x < n and y < n) {
                    t[log2][0][i] = @intCast(@as(usize, @intCast(y)) << 4 | @as(usize, @intCast(x)));
                    i += 1;
                }
                y -= 1;
                x += 1;
            }
            y = x;
            x = 0;
        }
        for (0..n) |r| {
            for (0..n) |c| {
                t[log2][1][r * n + c] = @intCast(r << 4 | c);
                t[log2][2][r * n + c] = @intCast(c << 4 | r);
            }
        }
        for (n * n..64) |k| {
            t[log2][0][k] = 0;
            t[log2][1][k] = 0;
            t[log2][2][k] = 0;
        }
    }
    break :blk t;
};

/// ctxIdxMap (9-41): sig_coeff_flag's context in a 4x4 block, by
/// ( yC << 2 ) + xC.
pub const ctx_idx_map = [16]u8{ 0, 1, 4, 5, 2, 3, 4, 5, 6, 6, 8, 8, 7, 7, 8, 8 };

/// The magnitudes of the transform's cosines: 90.5 cos( k pi / 64 ),
/// rounded as the standard rounds them, by k.
const cos_mag = [33]i8{
    64, 90, 90, 90, 89, 88, 87, 85, 83, 82, 80, 78, 75, 73, 70, 67,
    64, 61, 57, 54, 50, 46, 43, 38, 36, 31, 25, 22, 18, 13, 9,  4,
    0,
};

/// transMatrix (8-319 to 8-321): dct[ n ][ m ] is coefficient n's weight
/// at sample m of a 32-point block. A smaller block of N takes every
/// 32 / N-th row and its first N columns.
pub const dct: [32][32]i8 = blk: {
    @setEvalBranchQuota(20000);
    var t: [32][32]i8 = undefined;
    for (0..32) |n| {
        for (0..32) |m| {
            if (n == 0) {
                t[n][m] = 64;
                continue;
            }
            var k = ((2 * m + 1) * n) % 128;
            if (k > 64) k = 128 - k;
            t[n][m] = if (k > 32) -cos_mag[64 - k] else cos_mag[k];
        }
    }
    break :blk t;
};

/// The 4x4 DST of intra luma (8-316): row j is coefficient j's weights.
pub const dst4 = [4][4]i8{
    .{ 29, 55, 74, 84 },
    .{ 74, 74, 0, -74 },
    .{ 84, -29, -74, 55 },
    .{ 55, -84, 74, -29 },
};

/// levelScale (8.6.3).
pub const level_scale = [6]i32{ 40, 45, 51, 57, 64, 72 };

/// QpC by qPi for ChromaArrayType 1 (Table 8-10), qPi from -QpBdOffsetC
/// (at most 48) up to 57.
pub fn qpc420(qpi: i32) i32 {
    if (qpi < 30) return qpi;
    if (qpi > 43) return qpi - 6;
    const t = [14]i8{ 29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37 };
    return t[@intCast(qpi - 30)];
}

/// intraPredAngle (Table 8-5) by predModeIntra; 0 for planar and DC.
pub const intra_angle = [35]i8{
    0,   0,   32,  26,  21,  17, 13, 9,  5, 2, 0, -2, -5, -9, -13, -17, -21, -26,
    -32, -26, -21, -17, -13, -9, -5, -2, 0, 2, 5, 9,  13, 17, 21,  26,  32,
};

/// invAngle (Table 8-6) by predModeIntra 11 to 25.
pub const inv_angle = [15]i16{ -4096, -1638, -910, -630, -482, -390, -315, -256, -315, -390, -482, -630, -910, -1638, -4096 };

/// IntraPredModeC for 4:2:2 by modeIdx (Table 8-3).
pub const chroma422 = [35]u8{
    0,  1,  2,  2,  2,  2,  3,  5,  7,  8,  10, 12, 13, 15, 17, 18, 19, 20,
    21, 22, 23, 23, 24, 24, 25, 25, 26, 27, 27, 28, 28, 29, 29, 30, 31,
};

/// The luma interpolation filter (8-224 to 8-229) by quarter position.
pub const luma_filter = [4][8]i8{
    .{ 0, 0, 0, 64, 0, 0, 0, 0 },
    .{ -1, 4, -10, 58, 17, -5, 1, 0 },
    .{ -1, 4, -11, 40, 40, -11, 4, -1 },
    .{ 0, 1, -5, 17, 58, -10, 4, -1 },
};

/// The chroma interpolation filter (8-241 to 8-247) by eighth position.
pub const chroma_filter = [8][4]i8{
    .{ 0, 64, 0, 0 },
    .{ -2, 58, 10, -2 },
    .{ -4, 54, 16, -2 },
    .{ -6, 46, 28, -4 },
    .{ -4, 36, 36, -4 },
    .{ -4, 28, 46, -6 },
    .{ -2, 16, 54, -4 },
    .{ -2, 10, 58, -2 },
};

/// beta' (Table 8-12) by Q 0 to 51.
pub const beta_table = [52]u8{
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  6,  7,
    8,  9,  10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 26, 28, 30, 32,
    34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64,
};

/// tC' (Table 8-12) by Q 0 to 53.
pub const tc_table = [54]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  0,  0,  0,  0,  0,  0,  0,  0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 2,  2,  2,  2,  3,  3,  3,  3,  4,
    4, 4, 5, 5, 6, 6, 7, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 24,
};

/// The z-order of the 4x4 blocks in a block of 16 by 16 of them, by
/// y << 4 | x: a CTB's minimum blocks in decoding order.
pub const morton: [256]u8 = blk: {
    @setEvalBranchQuota(20000);
    var t: [256]u8 = undefined;
    for (0..16) |y| {
        for (0..16) |x| {
            var v: usize = 0;
            for (0..4) |b| v |= ((x >> b) & 1) << (2 * b) | ((y >> b) & 1) << (2 * b + 1);
            t[y << 4 | x] = @intCast(v);
        }
    }
    break :blk t;
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "transform matrix as printed" {
    // Rows 1, 3, 30 and 31 of transMatrixCol0to15, and row 1 of
    // transMatrixCol16to31.
    const r1 = [16]i8{ 90, 90, 88, 85, 82, 78, 73, 67, 61, 54, 46, 38, 31, 22, 13, 4 };
    const r3 = [16]i8{ 90, 82, 67, 46, 22, -4, -31, -54, -73, -85, -90, -88, -78, -61, -38, -13 };
    const r30 = [16]i8{ 9, -25, 43, -57, 70, -80, 87, -90, 90, -87, 80, -70, 57, -43, 25, -9 };
    const r31 = [16]i8{ 4, -13, 22, -31, 38, -46, 54, -61, 67, -73, 78, -82, 85, -88, 90, -90 };
    const r1b = [16]i8{ -4, -13, -22, -31, -38, -46, -54, -61, -67, -73, -78, -82, -85, -88, -90, -90 };
    const r27b = [16]i8{ 88, -67, 31, 13, -54, 82, -90, 78, -46, 4, 38, -73, 90, -85, 61, -22 };
    for (0..16) |m| {
        try testing.expectEqual(r1[m], dct[1][m]);
        try testing.expectEqual(r3[m], dct[3][m]);
        try testing.expectEqual(r30[m], dct[30][m]);
        try testing.expectEqual(r31[m], dct[31][m]);
        try testing.expectEqual(r1b[m], dct[1][16 + m]);
        try testing.expectEqual(r27b[m], dct[27][16 + m]);
    }
    try testing.expectEqual(@as(i8, 83), dct[8][0]);
    try testing.expectEqual(@as(i8, 36), dct[8][1]);
    try testing.expectEqual(@as(i8, -64), dct[16][1]);
}

test "scan orders" {
    // The 4x4 diagonal: (0,0) (0,1) (1,0) (0,2) (1,1) (2,0) ...
    try testing.expectEqual(@as(u8, 0x00), scan[2][0][0]);
    try testing.expectEqual(@as(u8, 0x10), scan[2][0][1]);
    try testing.expectEqual(@as(u8, 0x01), scan[2][0][2]);
    try testing.expectEqual(@as(u8, 0x20), scan[2][0][3]);
    try testing.expectEqual(@as(u8, 0x33), scan[2][0][15]);
    try testing.expectEqual(@as(u8, 0x01), scan[1][1][1]);
    try testing.expectEqual(@as(u8, 0x10), scan[1][2][1]);
    try testing.expectEqual(@as(u8, 0x77), scan[3][0][63]);
    try testing.expectEqual(@as(u8, 0), morton[0]);
    try testing.expectEqual(@as(u8, 3), morton[0x11]);
    try testing.expectEqual(@as(u8, 255), morton[0xff]);
}

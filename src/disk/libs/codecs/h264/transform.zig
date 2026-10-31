// SPDX-License-Identifier: MIT
//! The residual: scaling the coefficients by the quantiser and the
//! scaling matrices (8.5.9), the DC transforms of Intra_16x16 and chroma
//! (8.5.10, 8.5.11), the inverse 4x4 and 8x8 transforms (8.5.12.2,
//! 8.5.13.2), and the bypass of lossless macroblocks (8.5.15).
//!
//! Coefficients are in raster order, y * 4 + x (y * 8 + x), as the
//! inverse scans put them.

pub const field4 = [16]u8{ 0, 4, 1, 8, 12, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15 };
pub const field8 = [64]u8{
    0,  8,  16, 1,  9,  24, 32, 17, 2,  25, 40, 48, 56, 33, 10, 3,
    18, 41, 49, 57, 26, 11, 4,  19, 34, 42, 50, 58, 27, 12, 5,  20,
    35, 43, 51, 59, 28, 13, 6,  21, 36, 44, 52, 60, 29, 14, 22, 37,
    45, 53, 61, 30, 7,  15, 38, 46, 54, 62, 23, 31, 39, 47, 55, 63,
};

const norm4 = [6][3]u8{ .{ 10, 16, 13 }, .{ 11, 18, 14 }, .{ 13, 20, 16 }, .{ 14, 23, 18 }, .{ 16, 25, 20 }, .{ 18, 29, 23 } };
const norm8 = [6][6]u8{
    .{ 20, 18, 32, 19, 25, 24 }, .{ 22, 19, 35, 21, 28, 26 }, .{ 26, 23, 42, 24, 33, 31 },
    .{ 28, 25, 45, 26, 35, 33 }, .{ 32, 28, 51, 30, 40, 38 }, .{ 36, 32, 58, 34, 46, 43 },
};

fn norm4At(m: usize, r: usize) u32 {
    const x = r & 3;
    const y = r >> 2;
    if (x & 1 == 0 and y & 1 == 0) return norm4[m][0];
    if (x & 1 == 1 and y & 1 == 1) return norm4[m][1];
    return norm4[m][2];
}

fn norm8At(m: usize, r: usize) u32 {
    const j = r & 7;
    const i = r >> 3;
    if (i % 4 == 0 and j % 4 == 0) return norm8[m][0];
    if (i % 2 == 1 and j % 2 == 1) return norm8[m][1];
    if (i % 4 == 2 and j % 4 == 2) return norm8[m][2];
    if ((i % 4 == 0 and j % 2 == 1) or (i % 2 == 1 and j % 4 == 0)) return norm8[m][3];
    if ((i % 4 == 0 and j % 4 == 2) or (i % 4 == 2 and j % 4 == 0)) return norm8[m][4];
    return norm8[m][5];
}

/// LevelScale4x4 and LevelScale8x8 of a picture's scaling matrices, for
/// each qP % 6.
pub const Scales = struct {
    s4: [6][6][16]u32 = undefined,
    s8: [6][6][64]u32 = undefined,

    pub fn init(sc: *Scales, m4: *const [6][16]u8, m8: *const [6][64]u8) void {
        for (0..6) |l| {
            for (0..6) |m| {
                for (0..16) |r| sc.s4[l][m][r] = @as(u32, m4[l][r]) * norm4At(m, r);
                for (0..64) |r| sc.s8[l][m][r] = @as(u32, m8[l][r]) * norm8At(m, r);
            }
        }
    }
};

/// A 4x4 block's coefficients scaled (8.5.12.1); the DC left as it is
/// when it came from a DC transform.
pub fn scale4(c: *[16]i32, ls: *const [16]u32, qp: i32, skip_dc: bool) void {
    const q6: i32 = @divTrunc(qp, 6);
    const first: usize = @intFromBool(skip_dc);
    if (qp >= 24) {
        const shift: u5 = @intCast(q6 - 4);
        for (first..16) |r| {
            if (c[r] != 0) c[r] = (c[r] * @as(i32, @intCast(ls[r]))) << shift;
        }
    } else {
        const shift: u5 = @intCast(4 - q6);
        const round: i32 = @as(i32, 1) << (shift - 1);
        for (first..16) |r| {
            if (c[r] != 0) c[r] = (c[r] * @as(i32, @intCast(ls[r])) + round) >> shift;
        }
    }
}

/// An 8x8 block's coefficients scaled (8.5.13.1).
pub fn scale8(c: *[64]i32, ls: *const [64]u32, qp: i32) void {
    const q6: i32 = @divTrunc(qp, 6);
    if (qp >= 36) {
        const shift: u5 = @intCast(q6 - 6);
        for (0..64) |r| {
            if (c[r] != 0) c[r] = (c[r] * @as(i32, @intCast(ls[r]))) << shift;
        }
    } else {
        const shift: u5 = @intCast(6 - q6);
        const round: i32 = @as(i32, 1) << (shift - 1);
        for (0..64) |r| {
            if (c[r] != 0) c[r] = (c[r] * @as(i32, @intCast(ls[r])) + round) >> shift;
        }
    }
}

/// Intra_16x16's DC (8.5.10): the 4x4 Hadamard of the sixteen DCs
/// (raster by block), scaled; each into `out[k]` (raster by block too).
pub fn lumaDc(dc: *const [16]i32, out: *[16]i32, ls00: u32, qp: i32) void {
    var t: [16]i32 = undefined;
    for (0..4) |i| {
        const a = dc[i * 4 + 0];
        const b = dc[i * 4 + 1];
        const cc = dc[i * 4 + 2];
        const d = dc[i * 4 + 3];
        t[i * 4 + 0] = a + b + cc + d;
        t[i * 4 + 1] = a + b - cc - d;
        t[i * 4 + 2] = a - b - cc + d;
        t[i * 4 + 3] = a - b + cc - d;
    }
    const q6: i32 = @divTrunc(qp, 6);
    const scale: i32 = @intCast(ls00);
    for (0..4) |j| {
        const a = t[0 * 4 + j];
        const b = t[1 * 4 + j];
        const cc = t[2 * 4 + j];
        const d = t[3 * 4 + j];
        const f = [4]i32{ a + b + cc + d, a + b - cc - d, a - b - cc + d, a - b + cc - d };
        for (0..4) |i| {
            out[i * 4 + j] = if (qp >= 36)
                (f[i] * scale) << @intCast(q6 - 6)
            else
                (f[i] * scale + (@as(i32, 1) << @intCast(5 - q6))) >> @intCast(6 - q6);
        }
    }
}

/// 4:2:0 chroma DC (8.5.11.1, 8.5.11.2): the 2x2 transform, scaled.
pub fn chromaDc420(dc: *[4]i32, ls00: u32, qp: i32) void {
    const a = dc[0] + dc[1];
    const b = dc[0] - dc[1];
    const cc = dc[2] + dc[3];
    const d = dc[2] - dc[3];
    const f = [4]i32{ a + cc, b + d, a - cc, b - d };
    const q6: u5 = @intCast(@divTrunc(qp, 6));
    const scale: i32 = @intCast(ls00);
    for (0..4) |k| dc[k] = ((f[k] * scale) << q6) >> 5;
}

/// 4:2:2 chroma DC: the 2x4 transform (four rows of two), scaled with
/// QP'c + 3.
pub fn chromaDc422(dc: *[8]i32, ls00_of: *const [6]u32, qp: i32) void {
    // dc is raster: row r (0..3), column c (0..1) at r * 2 + c.
    var t: [8]i32 = undefined;
    for (0..2) |cidx| {
        const a = dc[0 * 2 + cidx];
        const b = dc[1 * 2 + cidx];
        const cc = dc[2 * 2 + cidx];
        const d = dc[3 * 2 + cidx];
        t[0 * 2 + cidx] = a + b + cc + d;
        t[1 * 2 + cidx] = a + b - cc - d;
        t[2 * 2 + cidx] = a - b - cc + d;
        t[3 * 2 + cidx] = a - b + cc - d;
    }
    const qp_dc = qp + 3;
    const q6: i32 = @divTrunc(qp_dc, 6);
    const scale: i32 = @intCast(ls00_of[@intCast(@mod(qp_dc, 6))]);
    for (0..4) |r| {
        const f = [2]i32{ t[r * 2] + t[r * 2 + 1], t[r * 2] - t[r * 2 + 1] };
        for (0..2) |cidx| {
            dc[r * 2 + cidx] = if (qp_dc >= 36)
                (f[cidx] * scale) << @intCast(q6 - 6)
            else
                (f[cidx] * scale + (@as(i32, 1) << @intCast(5 - q6))) >> @intCast(6 - q6);
        }
    }
}

inline fn clip(comptime P: type, v: i32, max: i32) P {
    return @intCast(if (v < 0) 0 else if (v > max) max else v);
}

/// The inverse 4x4 transform of `c`, added to the prediction at `dst`.
pub fn idct4Add(comptime P: type, dst: [*]P, stride: usize, c: *const [16]i32, max: i32) void {
    var t: [16]i32 = undefined;
    for (0..4) |i| {
        const d0 = c[i * 4 + 0];
        const d1 = c[i * 4 + 1];
        const d2 = c[i * 4 + 2];
        const d3 = c[i * 4 + 3];
        const e = d0 + d2;
        const f = d0 - d2;
        const g = (d1 >> 1) - d3;
        const h = d1 + (d3 >> 1);
        t[i * 4 + 0] = e + h;
        t[i * 4 + 1] = f + g;
        t[i * 4 + 2] = f - g;
        t[i * 4 + 3] = e - h;
    }
    for (0..4) |j| {
        const f0 = t[0 * 4 + j];
        const f1 = t[1 * 4 + j];
        const f2 = t[2 * 4 + j];
        const f3 = t[3 * 4 + j];
        const e = f0 + f2;
        const f = f0 - f2;
        const g = (f1 >> 1) - f3;
        const h = f1 + (f3 >> 1);
        const r = [4]i32{ e + h, f + g, f - g, e - h };
        for (0..4) |i| {
            const p = &dst[i * stride + j];
            p.* = clip(P, @as(i32, p.*) + ((r[i] + 32) >> 6), max);
        }
    }
}

/// A block with only its DC: every sample moved by the same amount.
pub fn dcAdd(comptime P: type, dst: [*]P, stride: usize, size: usize, dc: i32, max: i32) void {
    const v = (dc + 32) >> 6;
    for (0..size) |i| {
        for (0..size) |j| {
            const p = &dst[i * stride + j];
            p.* = clip(P, @as(i32, p.*) + v, max);
        }
    }
}

/// The inverse 8x8 transform of `c`, added to the prediction at `dst`.
pub fn idct8Add(comptime P: type, dst: [*]P, stride: usize, c: *const [64]i32, max: i32) void {
    var t: [64]i32 = undefined;
    for (0..8) |i| {
        idct8Row(c[i * 8 ..][0..8], t[i * 8 ..][0..8], 1);
    }
    var col: [8]i32 = undefined;
    var out: [8]i32 = undefined;
    for (0..8) |j| {
        for (0..8) |i| col[i] = t[i * 8 + j];
        idct8Row(&col, &out, 1);
        for (0..8) |i| {
            const p = &dst[i * stride + j];
            p.* = clip(P, @as(i32, p.*) + ((out[i] + 32) >> 6), max);
        }
    }
}

fn idct8Row(d: *const [8]i32, out: *[8]i32, comptime _: u32) void {
    const a0 = d[0] + d[4];
    const a1 = -d[3] + d[5] - d[7] - (d[7] >> 1);
    const a2 = d[0] - d[4];
    const a3 = d[1] + d[7] - d[3] - (d[3] >> 1);
    const a4 = (d[2] >> 1) - d[6];
    const a5 = -d[1] + d[7] + d[5] + (d[5] >> 1);
    const a6 = d[2] + (d[6] >> 1);
    const a7 = d[3] + d[5] + d[1] + (d[1] >> 1);
    const b0 = a0 + a6;
    const b1 = a1 + (a7 >> 2);
    const b2 = a2 + a4;
    const b3 = a3 + (a5 >> 2);
    const b4 = a2 - a4;
    const b5 = (a3 >> 2) - a5;
    const b6 = a0 - a6;
    const b7 = a7 - (a1 >> 2);
    out[0] = b0 + b7;
    out[1] = b2 + b5;
    out[2] = b4 + b3;
    out[3] = b6 + b1;
    out[4] = b6 - b1;
    out[5] = b4 - b3;
    out[6] = b2 - b5;
    out[7] = b0 - b7;
}

/// A lossless block (8.5.15): the residual is the coefficients, summed
/// down the columns after a vertical prediction, along the rows after a
/// horizontal one.
pub const Dpcm = enum { none, vertical, horizontal };

pub fn bypassAdd(comptime P: type, dst: [*]P, stride: usize, c: []const i32, size: usize, dpcm: Dpcm, max: i32) void {
    var r: [64]i32 = undefined;
    for (0..size * size) |k| r[k] = c[k];
    switch (dpcm) {
        .none => {},
        .vertical => for (1..size) |i| {
            for (0..size) |j| r[i * size + j] += r[(i - 1) * size + j];
        },
        .horizontal => for (0..size) |i| {
            for (1..size) |j| r[i * size + j] += r[i * size + j - 1];
        },
    }
    for (0..size) |i| {
        for (0..size) |j| {
            const p = &dst[i * stride + j];
            p.* = clip(P, @as(i32, p.*) + r[i * size + j], max);
        }
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "a DC alone through the 4x4 transform moves every sample by (dc + 32) >> 6" {
    var c: [16]i32 = @splat(0);
    c[0] = 640;
    var px: [16]u8 = @splat(100);
    idct4Add(u8, &px, 4, &c, 255);
    for (px) |p| try testing.expectEqual(@as(u8, 110), p);
    var c8: [64]i32 = @splat(0);
    c8[0] = 64 * 7;
    var px8: [64]u8 = @splat(10);
    idct8Add(u8, &px8, 8, &c8, 255);
    for (px8) |p| try testing.expectEqual(@as(u8, 17), p);
}

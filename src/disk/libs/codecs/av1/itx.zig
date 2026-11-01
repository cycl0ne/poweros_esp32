// SPDX-License-Identifier: MIT
//! The inverse transforms (7.13): the DCT of 4 to 64, the ADST of 4 to
//! 16, the identity of 4 to 32 and, for lossless blocks, the
//! Walsh-Hadamard transform of 4; rows first, then columns.

const common = @import("common.zig");
const tables = @import("tables.zig");

const SINPI_1_9 = 1321;
const SINPI_2_9 = 2482;
const SINPI_3_9 = 3344;
const SINPI_4_9 = 3803;

fn cos128(angle: i32) i64 {
    const a2: usize = @intCast(angle & 255);
    if (a2 <= 64) return tables.cos128_lookup[a2];
    if (a2 <= 128) return -@as(i64, tables.cos128_lookup[128 - a2]);
    if (a2 <= 192) return -@as(i64, tables.cos128_lookup[a2 - 128]);
    return tables.cos128_lookup[256 - a2];
}

fn sin128(angle: i32) i64 {
    return cos128(angle - 64);
}

fn round12(x: i64) i32 {
    return @truncate((x + 2048) >> 12);
}

fn brev(comptime bits: u5, x: usize) usize {
    var t: usize = 0;
    for (0..bits) |i| t |= ((x >> @intCast(i)) & 1) << @intCast(bits - 1 - i);
    return t;
}

/// B(a, b, angle, flip).
inline fn bf(t: []i32, a: usize, b: usize, angle: i32, flip: bool) void {
    const x = @as(i64, t[a]) * cos128(angle) - @as(i64, t[b]) * sin128(angle);
    const y = @as(i64, t[a]) * sin128(angle) + @as(i64, t[b]) * cos128(angle);
    if (flip) {
        t[a] = round12(y);
        t[b] = round12(x);
    } else {
        t[a] = round12(x);
        t[b] = round12(y);
    }
}

/// H(a, b, flip, r).
inline fn hd(t: []i32, a0: usize, b0: usize, flip: bool, lo: i32, hi: i32) void {
    const a = if (flip) b0 else a0;
    const b = if (flip) a0 else b0;
    const x = t[a];
    const y = t[b];
    t[a] = @max(lo, @min(hi, x +% y));
    t[b] = @max(lo, @min(hi, x -% y));
}

/// The inverse DCT (7.13.2.3) of 2^n values, clamped to `r` bits.
pub fn dct(t: []i32, comptime n: u5, r: u5) void {
    const lo: i32 = -(@as(i32, 1) << (r - 1));
    const hi: i32 = (@as(i32, 1) << (r - 1)) - 1;
    const len = @as(usize, 1) << n;
    var copy: [64]i32 = undefined;
    @memcpy(copy[0..len], t[0..len]);
    for (0..len) |i| t[i] = copy[brev(n, i)];
    if (n == 6) {
        for (0..16) |i| bf(t, 32 + i, 63 - i, 63 - 4 * @as(i32, @intCast(brev(4, i))), false);
    }
    if (n >= 5) {
        for (0..8) |i| bf(t, 16 + i, 31 - i, 6 + (@as(i32, @intCast(brev(3, 7 - i))) << 3), false);
    }
    if (n == 6) {
        for (0..16) |i| hd(t, 32 + i * 2, 33 + i * 2, i & 1 != 0, lo, hi);
    }
    if (n >= 4) {
        for (0..4) |i| bf(t, 8 + i, 15 - i, 12 + (@as(i32, @intCast(brev(2, 3 - i))) << 4), false);
    }
    if (n >= 5) {
        for (0..8) |i| hd(t, 16 + 2 * i, 17 + 2 * i, i & 1 != 0, lo, hi);
    }
    if (n == 6) {
        for (0..4) |i| {
            for (0..2) |j| bf(t, 62 - i * 4 - j, 33 + i * 4 + j, 60 - 16 * @as(i32, @intCast(brev(2, i))) + 64 * @as(i32, @intCast(j)), true);
        }
    }
    if (n >= 3) {
        for (0..2) |i| bf(t, 4 + i, 7 - i, 56 - 32 * @as(i32, @intCast(i)), false);
    }
    if (n >= 4) {
        for (0..4) |i| hd(t, 8 + 2 * i, 9 + 2 * i, i & 1 != 0, lo, hi);
    }
    if (n >= 5) {
        for (0..2) |i| {
            for (0..2) |j| bf(t, 30 - 4 * i - j, 17 + 4 * i + j, 24 + (@as(i32, @intCast(j)) << 6) + ((1 - @as(i32, @intCast(i))) << 5), true);
        }
    }
    if (n == 6) {
        for (0..8) |i| {
            for (0..2) |j| hd(t, 32 + i * 4 + j, 35 + i * 4 - j, i & 1 != 0, lo, hi);
        }
    }
    for (0..2) |i| bf(t, 2 * i, 2 * i + 1, 32 + 16 * @as(i32, @intCast(i)), i == 0);
    if (n >= 3) {
        for (0..2) |i| hd(t, 4 + 2 * i, 5 + 2 * i, i != 0, lo, hi);
    }
    if (n >= 4) {
        for (0..2) |i| bf(t, 14 - i, 9 + i, 48 + 64 * @as(i32, @intCast(i)), true);
    }
    if (n >= 5) {
        for (0..4) |i| {
            for (0..2) |j| hd(t, 16 + 4 * i + j, 19 + 4 * i - j, i & 1 != 0, lo, hi);
        }
    }
    if (n == 6) {
        for (0..2) |i| {
            for (0..4) |j| bf(t, 61 - i * 8 - j, 34 + i * 8 + j, 56 - @as(i32, @intCast(i)) * 32 + @as(i32, @intCast(j >> 1)) * 64, true);
        }
    }
    for (0..2) |i| hd(t, i, 3 - i, false, lo, hi);
    if (n >= 3) bf(t, 6, 5, 32, true);
    if (n >= 4) {
        for (0..2) |i| {
            for (0..2) |j| hd(t, 8 + 4 * i + j, 11 + 4 * i - j, i != 0, lo, hi);
        }
    }
    if (n >= 5) {
        for (0..4) |i| bf(t, 29 - i, 18 + i, 48 + @as(i32, @intCast(i >> 1)) * 64, true);
    }
    if (n == 6) {
        for (0..4) |i| {
            for (0..4) |j| hd(t, 32 + 8 * i + j, 39 + 8 * i - j, i & 1 != 0, lo, hi);
        }
    }
    if (n >= 3) {
        for (0..4) |i| hd(t, i, 7 - i, false, lo, hi);
    }
    if (n >= 4) {
        for (0..2) |i| bf(t, 13 - i, 10 + i, 32, true);
    }
    if (n >= 5) {
        for (0..2) |i| {
            for (0..4) |j| hd(t, 16 + i * 8 + j, 23 + i * 8 - j, i != 0, lo, hi);
        }
    }
    if (n == 6) {
        for (0..8) |i| bf(t, 59 - i, 36 + i, if (i < 4) 48 else 112, true);
    }
    if (n >= 4) {
        for (0..8) |i| hd(t, i, 15 - i, false, lo, hi);
    }
    if (n >= 5) {
        for (0..4) |i| bf(t, 27 - i, 20 + i, 32, true);
    }
    if (n == 6) {
        for (0..8) |i| {
            hd(t, 32 + i, 47 - i, false, lo, hi);
            hd(t, 48 + i, 63 - i, true, lo, hi);
        }
    }
    if (n >= 5) {
        for (0..16) |i| hd(t, i, 31 - i, false, lo, hi);
    }
    if (n == 6) {
        for (0..8) |i| bf(t, 55 - i, 40 + i, 32, true);
    }
    if (n == 6) {
        for (0..32) |i| hd(t, i, 63 - i, false, lo, hi);
    }
}

fn adstIn(t: []i32, comptime n: u5) void {
    const n0 = @as(usize, 1) << n;
    var copy: [16]i32 = undefined;
    @memcpy(copy[0..n0], t[0..n0]);
    for (0..n0) |i| {
        const idx = if (i & 1 != 0) i - 1 else n0 - i - 1;
        t[i] = copy[idx];
    }
}

fn adstOut(t: []i32, comptime n: u5) void {
    const n0 = @as(usize, 1) << n;
    var copy: [16]i32 = undefined;
    @memcpy(copy[0..n0], t[0..n0]);
    for (0..n0) |i| {
        const a = (i >> 3) & 1;
        const b = ((i >> 2) & 1) ^ ((i >> 3) & 1);
        const c = ((i >> 1) & 1) ^ ((i >> 2) & 1);
        const d = (i & 1) ^ ((i >> 1) & 1);
        const idx = ((d << 3) | (c << 2) | (b << 1) | a) >> (4 - n);
        t[i] = if (i & 1 != 0) -%copy[idx] else copy[idx];
    }
}

fn adst4(t: []i32) void {
    var s: [7]i64 = undefined;
    s[0] = SINPI_1_9 * @as(i64, t[0]);
    s[1] = SINPI_2_9 * @as(i64, t[0]);
    s[2] = SINPI_3_9 * @as(i64, t[1]);
    s[3] = SINPI_4_9 * @as(i64, t[2]);
    s[4] = SINPI_1_9 * @as(i64, t[2]);
    s[5] = SINPI_2_9 * @as(i64, t[3]);
    s[6] = SINPI_4_9 * @as(i64, t[3]);
    const a7: i64 = @as(i64, t[0]) - t[2];
    const b7: i64 = a7 + t[3];
    s[0] = s[0] + s[3];
    s[1] = s[1] - s[4];
    s[3] = s[2];
    s[2] = SINPI_3_9 * b7;
    s[0] = s[0] + s[5];
    s[1] = s[1] - s[6];
    const x0 = s[0] + s[3];
    const x1 = s[1] + s[3];
    const x2 = s[2];
    var x3 = s[0] + s[1];
    x3 = x3 - s[3];
    t[0] = round12(x0);
    t[1] = round12(x1);
    t[2] = round12(x2);
    t[3] = round12(x3);
}

fn adst8(t: []i32, lo: i32, hi: i32) void {
    adstIn(t, 3);
    for (0..4) |i| bf(t, 2 * i, 2 * i + 1, 60 - 16 * @as(i32, @intCast(i)), true);
    for (0..4) |i| hd(t, i, 4 + i, false, lo, hi);
    for (0..2) |i| bf(t, 4 + 3 * i, 5 + i, 48 - 32 * @as(i32, @intCast(i)), true);
    for (0..2) |i| {
        for (0..2) |j| hd(t, 4 * j + i, 2 + 4 * j + i, false, lo, hi);
    }
    for (0..2) |i| bf(t, 2 + 4 * i, 3 + 4 * i, 32, true);
    adstOut(t, 3);
}

fn adst16(t: []i32, lo: i32, hi: i32) void {
    adstIn(t, 4);
    for (0..8) |i| bf(t, 2 * i, 2 * i + 1, 62 - 8 * @as(i32, @intCast(i)), true);
    for (0..8) |i| hd(t, i, 8 + i, false, lo, hi);
    for (0..2) |i| {
        bf(t, 8 + 2 * i, 9 + 2 * i, 56 - 32 * @as(i32, @intCast(i)), true);
        bf(t, 13 + 2 * i, 12 + 2 * i, 8 + 32 * @as(i32, @intCast(i)), true);
    }
    for (0..4) |i| {
        for (0..2) |j| hd(t, 8 * j + i, 4 + 8 * j + i, false, lo, hi);
    }
    for (0..2) |i| {
        for (0..2) |j| bf(t, 4 + 8 * j + 3 * i, 5 + 8 * j + i, 48 - 32 * @as(i32, @intCast(i)), true);
    }
    for (0..2) |i| {
        for (0..4) |j| hd(t, 4 * j + i, 2 + 4 * j + i, false, lo, hi);
    }
    for (0..4) |i| bf(t, 2 + 4 * i, 3 + 4 * i, 32, true);
    adstOut(t, 4);
}

fn adst(t: []i32, comptime n: u5, r: u5) void {
    const lo: i32 = -(@as(i32, 1) << (r - 1));
    const hi: i32 = (@as(i32, 1) << (r - 1)) - 1;
    switch (n) {
        2 => adst4(t),
        3 => adst8(t, lo, hi),
        else => adst16(t, lo, hi),
    }
}

fn identity(t: []i32, comptime n: u5) void {
    const len = @as(usize, 1) << n;
    for (t[0..len]) |*v| {
        v.* = switch (n) {
            2 => round12(@as(i64, v.*) * 5793),
            3 => v.* *% 2,
            4 => round12(@as(i64, v.*) * 11586),
            else => v.* *% 4,
        };
    }
}

fn wht(t: []i32, shift: u5) void {
    var a = t[0] >> shift;
    var c = t[1] >> shift;
    var d = t[2] >> shift;
    var b = t[3] >> shift;
    a +%= c;
    d -%= b;
    const e = (a -% d) >> 1;
    b = e -% b;
    c = e -% c;
    a -%= b;
    d +%= c;
    t[0] = a;
    t[1] = b;
    t[2] = c;
    t[3] = d;
}

const Kind = enum { dct, adst, identity };

/// The rows' and the columns' transform of a type.
fn kinds(tx_type: u8) [2]Kind {
    const row: Kind = switch (tx_type) {
        common.DCT_DCT, common.ADST_DCT, common.FLIPADST_DCT, common.H_DCT => .dct,
        common.DCT_ADST, common.ADST_ADST, common.DCT_FLIPADST, common.FLIPADST_FLIPADST, common.ADST_FLIPADST, common.FLIPADST_ADST, common.H_ADST, common.H_FLIPADST => .adst,
        else => .identity,
    };
    const col: Kind = switch (tx_type) {
        common.DCT_DCT, common.DCT_ADST, common.DCT_FLIPADST, common.V_DCT => .dct,
        common.ADST_DCT, common.ADST_ADST, common.FLIPADST_DCT, common.FLIPADST_FLIPADST, common.ADST_FLIPADST, common.FLIPADST_ADST, common.V_ADST, common.V_FLIPADST => .adst,
        else => .identity,
    };
    return .{ row, col };
}

fn run(t: []i32, kind: Kind, n: u5, r: u5) void {
    switch (kind) {
        .dct => switch (n) {
            2 => dct(t, 2, r),
            3 => dct(t, 3, r),
            4 => dct(t, 4, r),
            5 => dct(t, 5, r),
            else => dct(t, 6, r),
        },
        .adst => switch (n) {
            2 => adst(t, 2, r),
            3 => adst(t, 3, r),
            else => adst(t, 4, r),
        },
        .identity => switch (n) {
            2 => identity(t, 2),
            3 => identity(t, 3),
            4 => identity(t, 4),
            else => identity(t, 5),
        },
    }
}

/// The 2D inverse transform (7.13.3) of the dequantised coefficients
/// `coefs` (`eob` of them, in the order of `scan`) of a transform block
/// of size `txsz` and type `tx_type`, into `res` (at the stride of its
/// width).
pub fn inverse(res: *[64 * 64]i32, coefs: []const i32, scan: []const u16, txsz: u8, tx_type: u8, lossless: bool, bit_depth: u8) void {
    const log2w: u5 = @intCast(tables.tx_width_log2[txsz]);
    const log2h: u5 = @intCast(tables.tx_height_log2[txsz]);
    const w = @as(usize, 1) << log2w;
    const h = @as(usize, 1) << log2h;
    const tw: usize = @min(32, w);
    const th: usize = @min(32, h);
    // The coefficients in place, and the rows that have any.
    var dq: [32 * 32]i32 = undefined;
    @memset(dq[0 .. tw * th], 0);
    var rows: usize = 0;
    const bwl: u4 = if (tw == 32) 5 else @intCast(log2w);
    for (coefs, 0..) |c, i| {
        const pos = scan[i];
        dq[pos] = c;
        rows = @max(rows, (pos >> bwl) + 1);
    }
    const row_shift: u5 = if (lossless) 0 else @intCast(tables.transform_row_shift[txsz]);
    const col_shift: u5 = if (lossless) 0 else 4;
    const row_r: u5 = @intCast(bit_depth + 8);
    const col_r: u5 = @intCast(@max(bit_depth + 6, 16));
    const col_lo: i32 = -(@as(i32, 1) << (col_r - 1));
    const col_hi: i32 = (@as(i32, 1) << (col_r - 1)) - 1;
    const row_lo: i32 = -(@as(i32, 1) << (row_r - 1));
    const row_hi: i32 = (@as(i32, 1) << (row_r - 1)) - 1;
    const k = kinds(tx_type);
    const rect = log2w > log2h and log2w - log2h == 1 or log2h > log2w and log2h - log2w == 1;
    var t: [64]i32 = undefined;
    for (0..h) |i| {
        const out = res[i * w ..][0..w];
        if (i >= rows) {
            @memset(out, 0);
            continue;
        }
        @memset(t[0..w], 0);
        if (i < 32) {
            for (0..tw) |j| t[j] = dq[i * tw + j];
        }
        if (rect) {
            for (t[0..w]) |*v| v.* = round12(@as(i64, v.*) * 2896);
        }
        // As libaom, the row's input clamped to the range its values
        // must lie in.
        if (!lossless) {
            for (t[0..w]) |*v| v.* = @max(row_lo, @min(row_hi, v.*));
        }
        if (lossless) wht(&t, 2) else run(&t, k[0], log2w, row_r);
        for (0..w) |j| out[j] = @max(col_lo, @min(col_hi, common.round2(t[j], row_shift)));
    }
    for (0..w) |j| {
        for (0..h) |i| t[i] = res[i * w + j];
        if (lossless) wht(&t, 0) else run(&t, k[1], log2h, col_r);
        for (0..h) |i| res[i * w + j] = common.round2(t[i], col_shift);
    }
}

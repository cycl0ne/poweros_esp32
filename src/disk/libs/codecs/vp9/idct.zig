// SPDX-License-Identifier: MIT
//! The inverse transforms (8.7): the DCT of 4 to 32 points, the ADST of 4
//! to 16 and the Walsh-Hadamard transform of lossless frames, each
//! unrolled at compile time from the butterflies the specification builds
//! them of, and their sum into the prediction.

const tables = @import("tables.zig");

fn brev(comptime bits: u5, x: usize) usize {
    var t: usize = 0;
    for (0..bits) |i| t |= ((x >> @intCast(i)) & 1) << @intCast(bits - 1 - i);
    return t;
}

fn cos64(comptime angle: i32) i64 {
    const a2: i32 = angle & 127;
    if (a2 <= 32) return tables.cos64_lookup[@intCast(a2)];
    if (a2 <= 64) return -@as(i64, tables.cos64_lookup[@intCast(64 - a2)]);
    if (a2 <= 96) return -@as(i64, tables.cos64_lookup[@intCast(a2 - 64)]);
    return tables.cos64_lookup[@intCast(128 - a2)];
}

fn sin64(comptime angle: i32) i64 {
    return cos64(angle - 32);
}

inline fn round14(x: i64) i32 {
    return @truncate((x + (1 << 13)) >> 14);
}

/// The butterfly rotation B (8.7.1.1), flipped when `flip`.
inline fn B(t: []i32, comptime a: usize, comptime b: usize, comptime angle: i32, comptime flip: bool) void {
    const ta: i64 = t[a];
    const tb: i64 = t[b];
    const x = round14(ta * cos64(angle) - tb * sin64(angle));
    const y = round14(ta * sin64(angle) + tb * cos64(angle));
    t[a] = if (flip) y else x;
    t[b] = if (flip) x else y;
}

/// The Hadamard rotation H, its indices flipped when `flip`.
inline fn H(t: []i32, comptime a: usize, comptime b: usize, comptime flip: bool) void {
    const x = t[if (flip) b else a];
    const y = t[if (flip) a else b];
    t[if (flip) b else a] = x +% y;
    t[if (flip) a else b] = x -% y;
}

inline fn SB(t: []const i32, s: []i64, comptime a: usize, comptime b: usize, comptime angle: i32, comptime flip: bool) void {
    const ta: i64 = t[a];
    const tb: i64 = t[b];
    const x = ta * cos64(angle) - tb * sin64(angle);
    const y = ta * sin64(angle) + tb * cos64(angle);
    s[a] = if (flip) y else x;
    s[b] = if (flip) x else y;
}

inline fn SH(t: []i32, s: []const i64, comptime a: usize, comptime b: usize) void {
    const sa = s[a];
    const sb = s[b];
    t[a] = round14(sa + sb);
    t[b] = round14(sa - sb);
}

/// The inverse DCT of the permuted `t` (8.7.1.3).
inline fn idctCore(comptime n: u5, t: []i32) void {
    const k: usize = n;
    const n0 = 1 << n;
    const n1 = 1 << (n - 1);
    const n2 = 1 << (n - 2);
    const n3 = if (n >= 3) 1 << (n - 3) else 0;
    if (n == 2) B(t, 0, 1, 16, true) else idctCore(n - 1, t);
    inline for (0..n2) |i| B(t, n1 + i, n0 - 1 - i, 32 - @as(i32, @intCast(brev(5, n1 + i))), false);
    if (n >= 3) {
        inline for (0..n3) |i| {
            inline for (0..2) |j| H(t, n1 + 4 * i + 2 * j, n1 + 1 + 4 * i + 2 * j, j == 1);
        }
    }
    if (n == 5) {
        inline for (0..2) |i| {
            inline for (0..2) |j| B(t, n0 - k + 3 - n2 * j - 4 * i, n1 + k - 4 + n2 * j + 4 * i, 28 - 16 * @as(i32, i) + 56 * @as(i32, j), true);
        }
        inline for (0..2) |i| {
            inline for (0..4) |j| H(t, n1 + n3 * j + i, n1 + n2 - 5 + n3 * j - i, j & 1 == 1);
        }
    }
    if (n >= 4) {
        inline for (0..@as(usize, if (n == 5) 2 else 1)) |i| {
            inline for (0..2) |j| B(t, n0 - k + 2 - i - n2 * j, n1 + k - 3 + i + n2 * j, 24 + 48 * @as(i32, j), true);
        }
        inline for (0..2 * k - 6) |i| {
            inline for (0..2) |j| H(t, n1 + n2 * j + i, n1 + n2 - 1 + n2 * j - i, j & 1 == 1);
        }
    }
    if (n >= 3) {
        inline for (0..n3) |i| B(t, n0 - n3 - 1 - i, n1 + n3 + i, 16, true);
    }
    inline for (0..n1) |i| H(t, i, n0 - 1 - i, false);
}

fn idct(comptime n: u5, t: *[1 << n]i32) void {
    const copy = t.*;
    inline for (0..1 << n) |i| t[i] = copy[brev(n, i)];
    idctCore(n, t);
}

fn adst4(t: *[4]i32) void {
    const t0: i64 = t[0];
    const t1: i64 = t[1];
    const t2: i64 = t[2];
    const t3: i64 = t[3];
    const s0 = 5283 * t0;
    const s1 = 9929 * t0;
    const s2 = 13377 * t1;
    const s3 = 15212 * t2;
    const s4 = 5283 * t2;
    const s5 = 9929 * t3;
    const s6 = 15212 * t3;
    const s7 = 13377 * (t0 - t2 + t3);
    const x0 = s0 + s3 + s5;
    const x1 = s1 - s4 - s6;
    t[0] = round14(x0 + s2);
    t[1] = round14(x1 + s2);
    t[2] = round14(s7);
    t[3] = round14(x0 + x1 - s2);
}

fn adstIn(comptime n: u5, t: []i32) void {
    const n0 = 1 << n;
    var copy: [n0]i32 = undefined;
    @memcpy(&copy, t[0..n0]);
    inline for (0..n0 / 2) |i| {
        t[2 * i] = copy[n0 - 1 - 2 * i];
        t[2 * i + 1] = copy[2 * i];
    }
}

fn adstOut(comptime n: u5, t: []i32) void {
    const n0 = 1 << n;
    var copy: [n0]i32 = undefined;
    @memcpy(&copy, t[0..n0]);
    if (n == 4) {
        inline for (0..16) |k| {
            const a = (k >> 3) & 1;
            const b = (k >> 2) & 1;
            const c = (k >> 1) & 1;
            const d = k & 1;
            t[k] = copy[8 * (d ^ c) + 4 * (c ^ b) + 2 * (b ^ a) + a];
        }
    } else {
        inline for (0..8) |k| {
            const a = (k >> 2) & 1;
            const b = (k >> 1) & 1;
            const c = k & 1;
            t[k] = copy[4 * (c ^ b) + 2 * (b ^ a) + a];
        }
    }
}

fn adst8(t: *[8]i32) void {
    var s: [8]i64 = undefined;
    adstIn(3, t);
    inline for (0..4) |i| SB(t, &s, 2 * i, 1 + 2 * i, 30 - 8 * @as(i32, i), true);
    inline for (0..4) |i| SH(t, &s, i, 4 + i);
    inline for (0..2) |i| SB(t, &s, 4 + 3 * i, 5 + i, 24 - 16 * @as(i32, i), true);
    inline for (0..2) |i| SH(t, &s, 4 + i, 6 + i);
    inline for (0..2) |i| H(t, i, 2 + i, false);
    inline for (0..2) |i| B(t, 2 + 4 * i, 3 + 4 * i, 16, true);
    adstOut(3, t);
    inline for (0..4) |i| t[1 + 2 * i] = -%t[1 + 2 * i];
}

fn adst16(t: *[16]i32) void {
    var s: [16]i64 = undefined;
    adstIn(4, t);
    inline for (0..8) |i| SB(t, &s, 2 * i, 1 + 2 * i, 31 - 4 * @as(i32, i), true);
    inline for (0..8) |i| SH(t, &s, i, 8 + i);
    inline for (0..4) |i| SB(t, &s, 8 + 2 * i, 9 + 2 * i, 28 - 16 * @as(i32, i), true);
    inline for (0..4) |i| SH(t, &s, 8 + i, 12 + i);
    inline for (0..4) |i| H(t, i, 4 + i, false);
    inline for (0..2) |i| {
        inline for (0..2) |j| SB(t, &s, 4 + 8 * i + 3 * j, 5 + 8 * i + j, 24 - 16 * @as(i32, j), true);
    }
    inline for (0..2) |i| {
        inline for (0..2) |j| SH(t, &s, 4 + 8 * j + i, 6 + 8 * j + i);
    }
    inline for (0..2) |i| {
        inline for (0..2) |j| H(t, 8 * j + i, 2 + 8 * j + i, false);
    }
    inline for (0..2) |i| {
        inline for (0..2) |j| B(t, 2 + 4 * j + 8 * i, 3 + 4 * j + 8 * i, 48 + 64 * @as(i32, i ^ j), false);
    }
    adstOut(4, t);
    inline for (0..2) |i| {
        inline for (0..2) |j| t[1 + 12 * j + 2 * i] = -%t[1 + 12 * j + 2 * i];
    }
}

fn wht(t: *[4]i32, comptime shift: u5) void {
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
    t.* = .{ a, b, c, d };
}

/// One row or column of `n` points; ADST when `adst`.
fn line(comptime n: u5, t: *[1 << n]i32, adst: bool) void {
    if (adst) {
        switch (n) {
            2 => adst4(t),
            3 => adst8(t),
            4 => adst16(t),
            else => unreachable,
        }
    } else idct(n, t);
}

/// The residual of a transform block added to the prediction at `dst`:
/// `c` holds its coefficients by position (zero where none) and is left
/// zero; `rows` has a bit for each row that may hold one.
pub fn add(comptime P: type, comptime n: u5, dst: [*]P, stride: usize, c: *[1 << (2 * n)]i32, rows: u32, tx_type: u8, lossless: bool, eob: u32, max: i32) void {
    const n0 = 1 << n;
    if (lossless) {
        // Only 4x4.
        if (n != 2) unreachable;
        var t: [4]i32 = undefined;
        for (0..4) |i| {
            t = c[i * 4 ..][0..4].*;
            wht(&t, 2);
            c[i * 4 ..][0..4].* = t;
        }
        for (0..4) |j| {
            for (0..4) |i| t[i] = c[i * 4 + j];
            wht(&t, 0);
            for (0..4) |i| put(P, dst + i * stride + j, t[i], max);
        }
        @memset(c, 0);
        return;
    }
    const shift: u5 = @min(6, n + 2);
    if (eob == 1 and tx_type == tables.DCT_DCT) {
        const r = round14(@as(i64, round14(@as(i64, c[0]) * 11585)) * 11585);
        const v = (r + (@as(i32, 1) << (shift - 1))) >> shift;
        c[0] = 0;
        for (0..n0) |y| {
            for (0..n0) |x| put(P, dst + y * stride + x, v, max);
        }
        return;
    }
    const row_adst = tx_type == tables.DCT_ADST or tx_type == tables.ADST_ADST;
    const col_adst = tx_type == tables.ADST_DCT or tx_type == tables.ADST_ADST;
    for (0..n0) |i| {
        if ((rows >> @intCast(i)) & 1 == 0) continue;
        line(n, c[i * n0 ..][0..n0], row_adst);
    }
    var t: [n0]i32 = undefined;
    for (0..n0) |j| {
        for (0..n0) |i| t[i] = c[i * n0 + j];
        line(n, &t, col_adst);
        for (0..n0) |i| put(P, dst + i * stride + j, (t[i] + (@as(i32, 1) << (shift - 1))) >> shift, max);
    }
    @memset(c, 0);
}

inline fn put(comptime P: type, p: [*]P, residual: i32, max: i32) void {
    p[0] = @intCast(@max(0, @min(max, @as(i32, p[0]) + residual)));
}

const testing = @import("std").testing;

test "the DCT of a DC coefficient is flat, as the shortcut takes it" {
    inline for (2..6) |nn| {
        const n: u5 = nn;
        const n0 = 1 << n;
        var c: [n0 * n0]i32 = @splat(0);
        var dst: [n0 * n0]u8 = @splat(100);
        c[0] = 333;
        // Through the full transform: a second coefficient that is zero
        // makes eob 2.
        add(u8, n, &dst, n0, &c, 1, tables.DCT_DCT, false, 2, 255);
        var dst2: [n0 * n0]u8 = @splat(100);
        c[0] = 333;
        add(u8, n, &dst2, n0, &c, 1, tables.DCT_DCT, false, 1, 255);
        try testing.expectEqualSlices(u8, &dst, &dst2);
        for (dst) |v| try testing.expectEqual(dst[0], v);
        try testing.expect(dst[0] != 100);
    }
}

test "the 4-point transforms match libvpx's" {
    // idct4_c and iadst4_c on one input, worked by hand from inv_txfm.c.
    var t: [4]i32 = .{ 100, -50, 25, 10 };
    idct(2, &t);
    // step0 = round((100+25)*11585) = 88, step1 = round(75*11585) = 53,
    // step2 = round(-50*6270 - 10*15137) = -28, step3 = round(-50*15137 + 10*6270) = -42
    try testing.expectEqualSlices(i32, &.{ 46, 25, 81, 130 }, &t);
    var a: [4]i32 = .{ 100, -50, 25, 10 };
    adst4(&a);
    // s0 = 528300, s1 = 992900, s2 = -668850, s3 = 380300, s4 = 132075,
    // s5 = 99290, s6 = 152120, s7 = 13377*85 = 1137045
    // x0 = 1007890, x1 = 708705
    try testing.expectEqualSlices(i32, &.{ 21, 2, 69, 146 }, &a);
}

test "the transforms match libvpx's on random input" {
    // Made by running libvpx's idct*_c and iadst*_c (inv_txfm.c).
    const Vector = struct { n: u8, adst: bool, in: []const i32, out: []const i32 };
    const vectors = [_]Vector{
        .{ .n = 4, .adst = false, .in = &.{ -2484, 1058, 0, 109 }, .out = &.{ -737, -1452, -2060, -2775 } },
        .{ .n = 4, .adst = false, .in = &.{ 0, -2768, 0, 1976 }, .out = &.{ -1801, -2885, 2885, 1801 } },
        .{ .n = 4, .adst = true, .in = &.{ 0, 648, -1126, -2163 }, .out = &.{ -1827, 2900, -847, -514 } },
        .{ .n = 4, .adst = true, .in = &.{ 0, -2792, 0, 122 }, .out = &.{ -2206, -2393, 100, 2240 } },
        .{ .n = 8, .adst = false, .in = &.{ 0, 0, 0, 587, 0, -169, -1208, 0 }, .out = &.{ -68, 1168, -1725, -5, 929, -507, 1064, -856 } },
        .{ .n = 8, .adst = false, .in = &.{ 0, 0, 1558, 0, 2155, 0, 0, -275 }, .out = &.{ 2909, -775, -2349, 355, -185, -1891, -1081, 3017 } },
        .{ .n = 8, .adst = true, .in = &.{ 0, 0, 457, 2491, -673, 1090, 0, 1825 }, .out = &.{ 4053, 481, 977, -2913, -510, 675, 3428, -2642 } },
        .{ .n = 8, .adst = true, .in = &.{ 0, 311, -1583, 2759, 0, 0, 2437, -1659 }, .out = &.{ 1775, 1139, -2720, 419, -1811, 7041, -1418, -2956 } },
        .{ .n = 16, .adst = false, .in = &.{ 221, -2758, -473, 0, 0, 224, 0, -1141, 0, 0, 1491, 1208, 1733, -795, 0, 0 }, .out = &.{ -1908, -5968, 246, -765, -6137, 1096, 1461, -812, 1722, -641, 2362, 2827, 2047, 3324, -632, 4274 } },
        .{ .n = 16, .adst = false, .in = &.{ 0, 1198, 0, 1598, -2541, -13, -1363, 0, -78, -2988, 2107, 0, 1914, -1120, 0, -1520 }, .out = &.{ -1293, 1616, 4803, 3232, -3005, 4104, -3938, -3929, 515, 2166, -2008, 1107, 4906, 4285, -10588, -1973 } },
        .{ .n = 16, .adst = true, .in = &.{ 0, 0, 0, 0, 2514, -2864, -697, -2104, 0, -622, -1693, -1623, 0, 0, 2755, 881 }, .out = &.{ -2040, -6028, 7925, -970, 2394, -2360, -6139, 1762, 2031, 3155, 356, 2563, -6294, -3010, -2064, 6284 } },
        .{ .n = 16, .adst = true, .in = &.{ -445, 448, 0, -924, 0, -1288, 0, -2830, 254, 2888, 0, 1147, 0, -1193, 0, 0 }, .out = &.{ -442, -2495, -4004, 4504, 3176, -4866, 1291, 3214, 989, -4392, -529, 4797, -4854, -4278, 707, 1434 } },
        .{ .n = 32, .adst = false, .in = &.{ 0, 1291, 0, 1717, 0, 0, -554, -1263, 0, -2374, -560, 0, -933, 1593, 0, -1218, 0, -1595, 0, 0, 0, 0, -1359, -1315, 546, 1033, 2455, 1129, -335, 0, -696, -1355 }, .out = &.{ -2700, 2019, 7867, 1082, 6989, 4111, -5059, 1986, -10566, 6692, 730, -4848, 325, -1324, -976, 2615, -1839, 2206, 342, 3593, -2406, -996, -3468, 4390, 8390, -1657, -4373, -3959, -2448, -2325, -3789, -604 } },
        .{ .n = 32, .adst = false, .in = &.{ 0, 0, -1893, -1255, -2211, 0, 0, 2628, 1362, 2943, -1911, 1409, -279, 0, 0, -213, -1074, 0, 0, 0, 0, 1515, 0, 330, -1794, 0, 2039, 96, 1507, -2331, 0, -579 }, .out = &.{ 246, -3085, -4148, -8286, -8336, -439, 3682, 7804, 2631, 12727, -1301, 937, -23, -5435, 5556, -161, 1527, 2230, -483, -3281, -721, 1675, 5879, -519, -2236, -52, -6807, 9812, -750, 5578, -3433, -10788 } },
    };
    for (vectors) |v| {
        var t: [32]i32 = undefined;
        @memcpy(t[0..v.in.len], v.in);
        switch (v.n) {
            4 => line(2, t[0..4], v.adst),
            8 => line(3, t[0..8], v.adst),
            16 => line(4, t[0..16], v.adst),
            else => line(5, t[0..32], v.adst),
        }
        try testing.expectEqualSlices(i32, v.out, t[0..v.out.len]);
    }
}

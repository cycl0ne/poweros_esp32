// SPDX-License-Identifier: MIT
//! The scaling of transform coefficients (8.6.3) and their transform
//! into residual samples (8.6.4): the DCT of 4 to 32 points and the 4x4
//! DST, done by columns and then rows, each split into its even and odd
//! halves, and only over the coefficients that are not zero.
//!
//! The sums are i32, or i64 with extended precision at a depth whose
//! coefficients need more than 16 bits.

const tables = @import("tables.zig");
const params = @import("params.zig");

/// ScalingFactor (7.4.5) of each size and matrixId, by y * size + x; all
/// 16 without scaling lists.
pub const Scales = struct {
    m4: [6][16]u8 = @splat(@splat(16)),
    m8: [6][64]u8 = @splat(@splat(16)),
    m16: [6][256]u8 = @splat(@splat(16)),
    m32: [6][1024]u8 = @splat(@splat(16)),
    flat: bool = true,

    /// The factors of `l`, or flat ones without.
    pub fn init(s: *Scales, l: ?*const params.ScalingList) void {
        const list = l orelse {
            s.* = .{};
            return;
        };
        s.flat = false;
        for (0..6) |m| {
            for (0..16) |i| {
                const p = tables.scan[2][0][i];
                s.m4[m][(p >> 4) * 4 + (p & 15)] = list.coef[0][m][i];
            }
            for (0..64) |i| {
                const p = tables.scan[3][0][i];
                const x: usize = p & 15;
                const y: usize = p >> 4;
                s.m8[m][y * 8 + x] = list.coef[1][m][i];
                for (0..2) |j| {
                    for (0..2) |k| s.m16[m][(y * 2 + j) * 16 + x * 2 + k] = list.coef[2][m][i];
                }
                for (0..4) |j| {
                    for (0..4) |k| s.m32[m][(y * 4 + j) * 32 + x * 4 + k] = list.coef[3][m][i];
                }
            }
            s.m16[m][0] = list.dc[0][m];
            s.m32[m][0] = list.dc[1][m];
        }
    }

    /// The factors of a block of 1 << `log2` for matrixId `m`.
    pub fn of(s: *const Scales, log2: u3, m: usize) []const u8 {
        return switch (log2) {
            2 => &s.m4[m],
            3 => &s.m8[m],
            4 => &s.m16[m],
            else => &s.m32[m],
        };
    }
};

/// What scaling a block's coefficients takes (8.6.3).
pub const Dequant = struct {
    /// levelScale[ qP % 6 ] << ( qP / 6 ), split so that it multiplies
    /// before it shifts.
    scale: i32,
    shift: u5,
    bd_shift: u6,
    min: i32,
    max: i32,

    pub fn init(qp: i32, depth: u5, log2: u3, range: u5, min: i32, max: i32) Dequant {
        return .{
            .scale = tables.level_scale[@intCast(@mod(qp, 6))],
            .shift = @intCast(@divTrunc(qp, 6)),
            .bd_shift = @intCast(@as(u32, depth) + log2 + 10 - range),
            .min = min,
            .max = max,
        };
    }

    /// d[ x ][ y ] (8-309) of `level` with factor `m`.
    pub inline fn apply(q: Dequant, level: i32, m: i32) i32 {
        const v = (@as(i64, level) * m * q.scale) << q.shift;
        const r = (v + (@as(i64, 1) << (q.bd_shift - 1))) >> q.bd_shift;
        return @intCast(@max(q.min, @min(q.max, r)));
    }
};

/// The transform's scratch: one pass's output.
pub const Work = struct {
    tmp: [32 * 32]i32 = undefined,
};

/// The residual of an N x N block of scaled coefficients `c` (by
/// y * N + x, zero past column `max_x` and row `max_y`) into `res`:
/// the DST when `dst`, else the DCT; the result shifted down by
/// `bd_shift` (8-299), the pass between clipped to `min`..`max`.
pub fn inverse(comptime Acc: type, work: *Work, c: []const i32, log2: u3, dst: bool, max_x: u32, max_y: u32, bd_shift: u6, min: i32, max: i32, res: []i32) void {
    const n: usize = @as(usize, 1) << log2;
    if (!dst and max_x == 0 and max_y == 0) {
        // DC alone: one value.
        const g: Acc = clip(Acc, (@as(Acc, 64) * c[0] + 64) >> 7, min, max);
        const r: Acc = (64 * g + (@as(Acc, 1) << @intCast(bd_shift - 1))) >> @intCast(bd_shift);
        const v: i32 = @intCast(r);
        @memset(res[0 .. n * n], v);
        return;
    }
    const t = &work.tmp;
    // Columns: tmp[ y ][ x ] for the columns with coefficients.
    var col: [32]Acc = undefined;
    for (0..max_x + 1) |x| {
        oneD(Acc, log2, dst, c[x..], n, max_y + 1, &col);
        for (0..n) |y| t[y * n + x] = @intCast(clip(Acc, (col[y] + 64) >> 7, min, max));
    }
    // Rows.
    const rnd: Acc = @as(Acc, 1) << @intCast(bd_shift - 1);
    for (0..n) |y| {
        oneD(Acc, log2, dst, t[y * n ..], 1, max_x + 1, &col);
        for (0..n) |x| res[y * n + x] = @intCast((col[x] + rnd) >> @intCast(bd_shift));
    }
}

inline fn clip(comptime Acc: type, v: Acc, min: i32, max: i32) Acc {
    return if (v < min) min else if (v > max) max else v;
}

/// One transform of N points (8.6.4.2) of `src` (its j-th `stride`
/// apart, those from `count` on zero) into `out`.
fn oneD(comptime Acc: type, log2: u3, dst: bool, src: []const i32, stride: usize, count: usize, out: *[32]Acc) void {
    if (dst) {
        for (0..4) |i| {
            var s: Acc = 0;
            for (0..count) |j| s += @as(Acc, tables.dst4[j][i]) * src[j * stride];
            out[i] = s;
        }
        return;
    }
    const n: usize = @as(usize, 1) << log2;
    const step = @as(usize, 32) >> log2;
    // Even coefficients are even about the middle, odd ones odd.
    for (0..n / 2) |i| {
        var e: Acc = 0;
        var o: Acc = 0;
        var j: usize = 0;
        while (j + 1 < count) : (j += 2) {
            e += @as(Acc, tables.dct[j * step][i]) * src[j * stride];
            o += @as(Acc, tables.dct[(j + 1) * step][i]) * src[(j + 1) * stride];
        }
        if (j < count) e += @as(Acc, tables.dct[j * step][i]) * src[j * stride];
        out[i] = e + o;
        out[n - 1 - i] = e - o;
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

/// The transform as the standard writes it, for comparison.
fn naive(c: []const i32, log2: u3, dst: bool, bd_shift: u6, res: []i64) void {
    const n: usize = @as(usize, 1) << log2;
    var g: [1024]i64 = undefined;
    for (0..n) |x| {
        for (0..n) |i| {
            var s: i64 = 0;
            for (0..n) |j| {
                const m: i64 = if (dst) tables.dst4[j][i] else tables.dct[j * (@as(usize, 32) >> log2)][i];
                s += m * c[j * n + x];
            }
            g[i * n + x] = @max(-32768, @min(32767, (s + 64) >> 7));
        }
    }
    for (0..n) |y| {
        for (0..n) |i| {
            var s: i64 = 0;
            for (0..n) |j| {
                const m: i64 = if (dst) tables.dst4[j][i] else tables.dct[j * (@as(usize, 32) >> log2)][i];
                s += m * g[y * n + j];
            }
            res[y * n + i] = (s + (@as(i64, 1) << @intCast(bd_shift - 1))) >> @intCast(bd_shift);
        }
    }
}

test "transforms against the standard's sums" {
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var work: Work = .{};
    var c: [1024]i32 = undefined;
    var res: [1024]i32 = undefined;
    var want: [1024]i64 = undefined;
    for (2..6) |l| {
        const log2: u3 = @intCast(l);
        const n: usize = @as(usize, 1) << log2;
        for (0..40) |round| {
            const mx: u32 = if (round % 3 == 0) 0 else rnd.intRangeLessThan(u32, 0, @intCast(n));
            const my: u32 = if (round % 3 == 0) 0 else rnd.intRangeLessThan(u32, 0, @intCast(n));
            @memset(c[0 .. n * n], 0);
            for (0..my + 1) |y| {
                for (0..mx + 1) |x| c[y * n + x] = rnd.intRangeAtMost(i32, -3000, 3000);
            }
            const dst = log2 == 2 and round % 2 == 1;
            inverse(i32, &work, c[0 .. n * n], log2, dst, mx, my, 12, -32768, 32767, res[0 .. n * n]);
            naive(c[0 .. n * n], log2, dst, 12, want[0 .. n * n]);
            for (0..n * n) |k| try testing.expectEqual(want[k], res[k]);
            inverse(i64, &work, c[0 .. n * n], log2, dst, mx, my, 12, -32768, 32767, res[0 .. n * n]);
            for (0..n * n) |k| try testing.expectEqual(want[k], res[k]);
        }
    }
}

test "scaling factors of the default lists" {
    var s: Scales = .{};
    const l = params.ScalingList.default();
    s.init(&l);
    try testing.expectEqual(@as(u8, 16), s.m4[0][5]);
    // Table 7-6's intra 8x8 list: 16 at the corner, 115 at the far one.
    try testing.expectEqual(@as(u8, 16), s.m8[0][0]);
    try testing.expectEqual(@as(u8, 115), s.m8[0][63]);
    try testing.expectEqual(@as(u8, 16), s.m16[0][0]);
    try testing.expectEqual(@as(u8, 115), s.m32[3 - 3][1023]);
    const q = Dequant.init(4, 8, 2, 15, -32768, 32767);
    // 4x4 at qP 4: level * 16 * 64 >> 5.
    try testing.expectEqual(@as(i32, 32), q.apply(1, 16));
}

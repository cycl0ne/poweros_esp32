// SPDX-License-Identifier: MIT
//! Intra prediction (8.3): a block predicted from the samples above it
//! and to its left - Intra_4x4 and Intra_8x8's nine directions (8.3.1.2,
//! 8.3.2.2), Intra_16x16's four (8.3.3) and chroma's (8.3.4).
//!
//! The caller gathers the neighbouring samples into an `Edge`, saying
//! which are there; the functions here only predict, into `dst`.

/// The samples around an N x N block: p[-1, -1], p[x, -1] for x up to
/// 2N - 1 (or N - 1 for 16x16 and chroma), p[-1, y] for y up to N - 1.
pub fn Edge(comptime P: type, comptime N: usize) type {
    return struct {
        corner: i32 = 0,
        top: [2 * N]i32 = @splat(0),
        left: [N]i32 = @splat(0),
        has_corner: bool = false,
        has_top: bool = false,
        has_topright: bool = false,
        has_left: bool = false,
        /// Which four rows of the left samples are there when not all of
        /// them are (MBAFF with constrained intra prediction): chroma's DC
        /// takes them block by block.
        left4: u4 = 0,

        const Self = @This();

        /// The ones to the right above copied from the last above, where
        /// they are not there (8.3.1.2, 8.3.2.2).
        pub fn fillTopRight(e: *Self) void {
            if (e.has_top and !e.has_topright) {
                for (N..2 * N) |x| e.top[x] = e.top[N - 1];
            }
        }

        pub fn fromRow(e: *Self, row: [*]const P, count: usize) void {
            for (0..count) |x| e.top[x] = row[x];
        }
    };
}

inline fn clip(v: i32, max: i32) i32 {
    return if (v < 0) 0 else if (v > max) max else v;
}

/// Intra_4x4 and Intra_8x8's modes over `e`'s samples (already filtered
/// for 8x8), into an N x N block.
pub fn predictNxN(comptime P: type, comptime N: usize, dst: [*]P, stride: usize, mode: u8, e: *const Edge(P, N), depth: u5) void {
    const n: i32 = @intCast(N);
    // p(x, -1) for x >= -1 and p(-1, y) for y >= -1.
    const T = struct {
        fn top(ed: *const Edge(P, N), x: i32) i32 {
            return if (x < 0) ed.corner else ed.top[@intCast(x)];
        }
        fn left(ed: *const Edge(P, N), y: i32) i32 {
            return if (y < 0) ed.corner else ed.left[@intCast(y)];
        }
    };
    var y: i32 = 0;
    while (y < n) : (y += 1) {
        var x: i32 = 0;
        while (x < n) : (x += 1) {
            const v: i32 = switch (mode) {
                0 => T.top(e, x),
                1 => T.left(e, y),
                2 => dc: {
                    var sum: i32 = 0;
                    if (e.has_top and e.has_left) {
                        for (0..N) |k| sum += e.top[k] + e.left[k];
                        break :dc @divTrunc(sum + n, 2 * n);
                    } else if (e.has_left) {
                        for (0..N) |k| sum += e.left[k];
                        break :dc @divTrunc(sum + @divTrunc(n, 2), n);
                    } else if (e.has_top) {
                        for (0..N) |k| sum += e.top[k];
                        break :dc @divTrunc(sum + @divTrunc(n, 2), n);
                    }
                    break :dc @as(i32, 1) << (depth - 1);
                },
                3 => if (x == n - 1 and y == n - 1)
                    (T.top(e, 2 * n - 2) + 3 * T.top(e, 2 * n - 1) + 2) >> 2
                else
                    (T.top(e, x + y) + 2 * T.top(e, x + y + 1) + T.top(e, x + y + 2) + 2) >> 2,
                4 => if (x > y)
                    (T.top(e, x - y - 2) + 2 * T.top(e, x - y - 1) + T.top(e, x - y) + 2) >> 2
                else if (x < y)
                    (T.left(e, y - x - 2) + 2 * T.left(e, y - x - 1) + T.left(e, y - x) + 2) >> 2
                else
                    (T.top(e, 0) + 2 * e.corner + T.left(e, 0) + 2) >> 2,
                5 => vr: {
                    const z = 2 * x - y;
                    if (z >= 0 and z & 1 == 0) break :vr (T.top(e, x - (y >> 1) - 1) + T.top(e, x - (y >> 1)) + 1) >> 1;
                    if (z > 0) break :vr (T.top(e, x - (y >> 1) - 2) + 2 * T.top(e, x - (y >> 1) - 1) + T.top(e, x - (y >> 1)) + 2) >> 2;
                    if (z == -1) break :vr (T.left(e, 0) + 2 * e.corner + T.top(e, 0) + 2) >> 2;
                    break :vr (T.left(e, y - 2 * x - 1) + 2 * T.left(e, y - 2 * x - 2) + T.left(e, y - 2 * x - 3) + 2) >> 2;
                },
                6 => hd: {
                    const z = 2 * y - x;
                    if (z >= 0 and z & 1 == 0) break :hd (T.left(e, y - (x >> 1) - 1) + T.left(e, y - (x >> 1)) + 1) >> 1;
                    if (z > 0) break :hd (T.left(e, y - (x >> 1) - 2) + 2 * T.left(e, y - (x >> 1) - 1) + T.left(e, y - (x >> 1)) + 2) >> 2;
                    if (z == -1) break :hd (T.left(e, 0) + 2 * e.corner + T.top(e, 0) + 2) >> 2;
                    break :hd (T.top(e, x - 2 * y - 1) + 2 * T.top(e, x - 2 * y - 2) + T.top(e, x - 2 * y - 3) + 2) >> 2;
                },
                7 => if (y & 1 == 0)
                    (T.top(e, x + (y >> 1)) + T.top(e, x + (y >> 1) + 1) + 1) >> 1
                else
                    (T.top(e, x + (y >> 1)) + 2 * T.top(e, x + (y >> 1) + 1) + T.top(e, x + (y >> 1) + 2) + 2) >> 2,
                8 => hu: {
                    const z = x + 2 * y;
                    if (z < 2 * n - 3 and z & 1 == 0) break :hu (T.left(e, y + (x >> 1)) + T.left(e, y + (x >> 1) + 1) + 1) >> 1;
                    if (z < 2 * n - 3) break :hu (T.left(e, y + (x >> 1)) + 2 * T.left(e, y + (x >> 1) + 1) + T.left(e, y + (x >> 1) + 2) + 2) >> 2;
                    if (z == 2 * n - 3) break :hu (T.left(e, n - 2) + 3 * T.left(e, n - 1) + 2) >> 2;
                    break :hu T.left(e, n - 1);
                },
                else => @as(i32, 1) << (depth - 1),
            };
            dst[@as(usize, @intCast(y)) * stride + @as(usize, @intCast(x))] = @intCast(v);
        }
    }
}

/// Intra_8x8's reference samples filtered (8.3.2.2.1), in place.
pub fn filter8x8(comptime P: type, e: *Edge(P, 8)) void {
    var top: [16]i32 = undefined;
    var left: [8]i32 = undefined;
    var corner = e.corner;
    if (e.has_top) {
        top[0] = if (e.has_corner) (e.corner + 2 * e.top[0] + e.top[1] + 2) >> 2 else (3 * e.top[0] + e.top[1] + 2) >> 2;
        for (1..15) |x| top[x] = (e.top[x - 1] + 2 * e.top[x] + e.top[x + 1] + 2) >> 2;
        top[15] = (e.top[14] + 3 * e.top[15] + 2) >> 2;
    }
    if (e.has_corner) {
        if (e.has_top and e.has_left) {
            corner = (e.top[0] + 2 * e.corner + e.left[0] + 2) >> 2;
        } else if (e.has_top) {
            corner = (3 * e.corner + e.top[0] + 2) >> 2;
        } else if (e.has_left) {
            corner = (3 * e.corner + e.left[0] + 2) >> 2;
        }
    }
    if (e.has_left) {
        left[0] = if (e.has_corner) (e.corner + 2 * e.left[0] + e.left[1] + 2) >> 2 else (3 * e.left[0] + e.left[1] + 2) >> 2;
        for (1..7) |y| left[y] = (e.left[y - 1] + 2 * e.left[y] + e.left[y + 1] + 2) >> 2;
        left[7] = (e.left[6] + 3 * e.left[7] + 2) >> 2;
    }
    if (e.has_top) e.top = top;
    if (e.has_left) e.left = left;
    e.corner = corner;
}

/// Intra_16x16 (8.3.3) and chroma (8.3.4) with its block of `w` x `h`:
/// vertical, horizontal, DC and plane, with chroma's DC per 4x4 block.
/// `mode` is the luma numbering (0 V, 1 H, 2 DC, 3 plane).
pub fn predictBlock(comptime P: type, comptime W: usize, comptime H: usize, dst: [*]P, stride: usize, mode: u8, e: *const Edge(P, 16), chroma: bool, chroma_format: u2, depth: u5) void {
    const max: i32 = (@as(i32, 1) << depth) - 1;
    switch (mode) {
        0 => for (0..H) |y| {
            for (0..W) |x| dst[y * stride + x] = @intCast(e.top[x]);
        },
        1 => for (0..H) |y| {
            for (0..W) |x| dst[y * stride + x] = @intCast(e.left[y]);
        },
        2 => if (!chroma) {
            var sum: i32 = 0;
            var v: i32 = @as(i32, 1) << (depth - 1);
            if (e.has_top and e.has_left) {
                for (0..16) |k| sum += e.top[k] + e.left[k];
                v = (sum + 16) >> 5;
            } else if (e.has_left) {
                for (0..16) |k| sum += e.left[k];
                v = (sum + 8) >> 4;
            } else if (e.has_top) {
                for (0..16) |k| sum += e.top[k];
                v = (sum + 8) >> 4;
            }
            for (0..H) |y| {
                for (0..W) |x| dst[y * stride + x] = @intCast(v);
            }
        } else {
            var by: usize = 0;
            while (by < H) : (by += 4) {
                const has_left = e.has_left or (e.left4 >> @intCast(by / 4)) & 1 != 0;
                var bx: usize = 0;
                while (bx < W) : (bx += 4) {
                    var st: i32 = 0;
                    var sl: i32 = 0;
                    for (0..4) |k| {
                        st += e.top[bx + k];
                        sl += e.left[by + k];
                    }
                    var v: i32 = @as(i32, 1) << (depth - 1);
                    const both = (bx == 0 and by == 0) or (bx > 0 and by > 0);
                    if (both) {
                        if (e.has_top and has_left) v = (st + sl + 4) >> 3 else if (has_left) v = (sl + 2) >> 2 else if (e.has_top) v = (st + 2) >> 2;
                    } else if (bx > 0) {
                        if (e.has_top) v = (st + 2) >> 2 else if (has_left) v = (sl + 2) >> 2;
                    } else {
                        if (has_left) v = (sl + 2) >> 2 else if (e.has_top) v = (st + 2) >> 2;
                    }
                    for (0..4) |y| {
                        for (0..4) |x| dst[(by + y) * stride + bx + x] = @intCast(v);
                    }
                }
            }
        },
        3 => {
            const xcf: i32 = if (chroma and chroma_format == 3) 4 else if (chroma) 0 else 4;
            const ycf: i32 = if (chroma and chroma_format != 1) 4 else if (chroma) 0 else 4;
            const T = struct {
                fn top(ed: *const Edge(P, 16), x: i32) i32 {
                    return if (x < 0) ed.corner else ed.top[@intCast(x)];
                }
                fn left(ed: *const Edge(P, 16), y: i32) i32 {
                    return if (y < 0) ed.corner else ed.left[@intCast(y)];
                }
            };
            var hs: i32 = 0;
            var x1: i32 = 0;
            while (x1 <= 3 + xcf) : (x1 += 1) hs += (x1 + 1) * (T.top(e, 4 + xcf + x1) - T.top(e, 2 + xcf - x1));
            var vs: i32 = 0;
            var y1: i32 = 0;
            while (y1 <= 3 + ycf) : (y1 += 1) vs += (y1 + 1) * (T.left(e, 4 + ycf + y1) - T.left(e, 2 + ycf - y1));
            const a = 16 * (e.left[H - 1] + e.top[W - 1]);
            var b: i32 = undefined;
            var c: i32 = undefined;
            if (!chroma) {
                b = (5 * hs + 32) >> 6;
                c = (5 * vs + 32) >> 6;
            } else {
                b = ((34 - 29 * @as(i32, @intFromBool(chroma_format == 3))) * hs + 32) >> 6;
                c = ((34 - 29 * @as(i32, @intFromBool(chroma_format != 1))) * vs + 32) >> 6;
            }
            for (0..H) |y| {
                for (0..W) |x| {
                    const v = (a + b * (@as(i32, @intCast(x)) - 3 - xcf) + c * (@as(i32, @intCast(y)) - 3 - ycf) + 16) >> 5;
                    dst[y * stride + x] = @intCast(clip(v, max));
                }
            }
        },
        else => {},
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "4x4 DC and vertical; 16x16 plane of a flat edge is flat" {
    var e: Edge(u8, 4) = .{ .has_top = true, .has_left = true, .has_corner = true };
    for (0..8) |x| e.top[x] = 100;
    for (0..4) |y| e.left[y] = 50;
    e.corner = 75;
    var out: [16]u8 = undefined;
    predictNxN(u8, 4, &out, 4, 2, &e, 8);
    for (out) |p| try testing.expectEqual(@as(u8, 75), p);
    predictNxN(u8, 4, &out, 4, 0, &e, 8);
    for (out) |p| try testing.expectEqual(@as(u8, 100), p);
    var e16: Edge(u8, 16) = .{ .has_top = true, .has_left = true, .has_corner = true, .corner = 80 };
    for (0..16) |k| {
        e16.top[k] = 80;
        e16.left[k] = 80;
    }
    var big: [256]u8 = undefined;
    predictBlock(u8, 16, 16, &big, 16, 3, &e16, false, 1, 8);
    for (big) |p| try testing.expectEqual(@as(u8, 80), p);
}

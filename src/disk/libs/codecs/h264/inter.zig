// SPDX-License-Identifier: MIT
//! Inter prediction's samples (8.4.2.2): a block of a reference picture
//! at a quarter-sample position for luma - the six-tap filter and the
//! averages between - or an eighth for chroma, and the weighting of one
//! or two such blocks (8.4.2.3).
//!
//! A position outside the reference picture takes the nearest sample on
//! its edge.

/// A plane of a reference picture as a block sees it: a field's rows are
/// every other row of its frame.
pub fn Plane(comptime P: type) type {
    return struct {
        data: [*]const P,
        stride: usize,
        width: i32,
        height: i32,

        inline fn at(p: @This(), x: i32, y: i32) i32 {
            const cx: usize = @intCast(if (x < 0) 0 else if (x >= p.width) p.width - 1 else x);
            const cy: usize = @intCast(if (y < 0) 0 else if (y >= p.height) p.height - 1 else y);
            return p.data[cy * p.stride + cx];
        }
    };
}

/// The largest block: 16 x 16, with the filter's 5 more each way.
const win_w = 16 + 5;

/// What a block's prediction works in: the half samples on the way, and
/// the samples gathered for a block over the edge, of either size. Kept
/// by the decoder rather than on the stack, where a safe build would fill
/// them for every block.
pub const Work = struct {
    b_raw: [win_w * 16]i32 = undefined,
    h_raw: [16 * 17]i32 = undefined,
    win: [win_w * win_w]u16 = undefined,

    fn window(work: *Work, comptime P: type) [*]P {
        return @ptrCast(&work.win);
    }
};

inline fn clip(v: i32, max: i32) i32 {
    return if (v < 0) 0 else if (v > max) max else v;
}

inline fn tap6(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32) i32 {
    return a - 5 * b + 20 * c + 20 * d - 5 * e + f;
}

/// A `w` x `h` luma block at full-sample position (x, y) plus (fx, fy)
/// quarters, into `dst`, `dst_stride` apart.
pub fn luma(comptime P: type, work: *Work, ref: Plane(P), x: i32, y: i32, fx: u32, fy: u32, w: u32, h: u32, dst: [*]u16, dst_stride: usize, max: i32) void {
    // The samples the filter reaches: from (x - 2, y - 2), w + 5 by h + 5;
    // gathered first when some are past the edge.
    const inside = x - 2 >= 0 and y - 2 >= 0 and x + @as(i32, @intCast(w)) + 3 <= ref.width and y + @as(i32, @intCast(h)) + 3 <= ref.height;
    const win = work.window(P);
    var src: [*]const P = win;
    var stride: usize = win_w;
    if (inside) {
        src = ref.data + @as(usize, @intCast(y - 2)) * ref.stride + @as(usize, @intCast(x - 2));
        stride = ref.stride;
    } else {
        for (0..h + 5) |j| {
            const sy = y - 2 + @as(i32, @intCast(j));
            for (0..w + 5) |i| win[j * win_w + i] = @intCast(ref.at(x - 2 + @as(i32, @intCast(i)), sy));
        }
    }
    switch (fy * 4 + fx) {
        inline 0...15 => |pos| quarter(pos, P, work, src, stride, w, h, dst, dst_stride, max),
        else => unreachable,
    }
}

/// The samples at quarter position `pos` (fy * 4 + fx) from `src`, which
/// is at the block's (-2, -2), its rows `stride` apart: the half samples
/// the position takes worked out once each, by rows and columns, before
/// they are put together (8-243 to 8-261). The half sample across is b,
/// the one below it s; the one down h, the one right of it m; the middle
/// one j, from b's unrounded values down.
fn quarter(comptime pos: u32, comptime P: type, work: *Work, src: [*]const P, stride: usize, w: u32, h: u32, dst: [*]u16, dst_stride: usize, max: i32) void {
    const fx = pos & 3;
    const fy = pos >> 2;
    const need_j = fx == 2 and fy != 0 or fy == 2 and fx != 0;
    const need_b = fy == 0 and fx != 0 or fy == 1 and fx != 0;
    const need_s = fy == 3 and fx != 0 and fx != 1 or pos == 13;
    const need_h = fx == 0 and fy != 0 or fx == 1 and fy != 0 and fy != 3 or pos == 13;
    const need_m = fx == 3 and fy != 0;
    const g = src + 2 * stride + 2;
    if (pos == 0) {
        for (0..h) |j| {
            const row = g + j * stride;
            const out = dst + j * dst_stride;
            for (0..w) |i| out[i] = row[i];
        }
        return;
    }
    // b unrounded, a row for each row of `src`: row r is the block's r - 2.
    const b_raw = &work.b_raw;
    if (need_j or need_b or need_s) {
        const lo: usize = if (need_j) 0 else if (need_b) 2 else 3;
        const hi: usize = if (need_j) h + 5 else if (need_s) h + 3 else h + 2;
        for (lo..hi) |r| {
            const o = src + r * stride;
            for (0..w) |i| b_raw[r * 16 + i] = tap6(o[i], o[i + 1], o[i + 2], o[i + 3], o[i + 4], o[i + 5]);
        }
    }
    // h unrounded, a column more for m.
    const h_raw = &work.h_raw;
    if (need_h or need_m) {
        const lo: usize = if (need_h) 0 else 1;
        const hi: usize = if (need_m) w + 1 else w;
        for (0..h) |j| {
            const o = src + j * stride + 2;
            for (lo..hi) |i| h_raw[j * 17 + i] = tap6(o[i], o[i + stride], o[i + 2 * stride], o[i + 3 * stride], o[i + 4 * stride], o[i + 5 * stride]);
        }
    }
    for (0..h) |j| {
        const row = g + j * stride;
        const out = dst + j * dst_stride;
        for (0..w) |i| {
            const b = if (need_b) clip((b_raw[(j + 2) * 16 + i] + 16) >> 5, max) else 0;
            const s = if (need_s) clip((b_raw[(j + 3) * 16 + i] + 16) >> 5, max) else 0;
            const hh = if (need_h) clip((h_raw[j * 17 + i] + 16) >> 5, max) else 0;
            const m = if (need_m) clip((h_raw[j * 17 + i + 1] + 16) >> 5, max) else 0;
            const jj = if (need_j) blk: {
                const c = b_raw[j * 16 + i ..];
                break :blk clip((tap6(c[0], c[16], c[32], c[48], c[64], c[80]) + 512) >> 10, max);
            } else 0;
            const v: i32 = switch (pos) {
                1 => (row[i] + b + 1) >> 1, // a
                2 => b, // b
                3 => (row[i + 1] + b + 1) >> 1, // c
                4 => (row[i] + hh + 1) >> 1, // d
                5 => (b + hh + 1) >> 1, // e
                6 => (b + jj + 1) >> 1, // f
                7 => (b + m + 1) >> 1, // g
                8 => hh, // h
                9 => (hh + jj + 1) >> 1, // i
                10 => jj, // j
                11 => (jj + m + 1) >> 1, // k
                12 => (row[i + stride] + hh + 1) >> 1, // n
                13 => (hh + s + 1) >> 1, // p
                14 => (jj + s + 1) >> 1, // q
                else => (m + s + 1) >> 1, // r
            };
            out[i] = @intCast(v);
        }
    }
}

/// A `w` x `h` chroma block at (x, y) plus (fx, fy) eighths.
pub fn chroma(comptime P: type, work: *Work, ref: Plane(P), x: i32, y: i32, fx: u32, fy: u32, w: u32, h: u32, dst: [*]u16, dst_stride: usize) void {
    const weights: [4]i32 = .{
        @intCast((8 - fx) * (8 - fy)),
        @intCast(fx * (8 - fy)),
        @intCast((8 - fx) * fy),
        @intCast(fx * fy),
    };
    const inside = x >= 0 and y >= 0 and x + @as(i32, @intCast(w)) + 1 <= ref.width and y + @as(i32, @intCast(h)) + 1 <= ref.height;
    // Past the edge: the samples it reaches gathered first, w + 1 by h + 1.
    const win = work.window(P);
    var src: [*]const P = win;
    var stride: usize = 17;
    if (inside) {
        src = ref.data + @as(usize, @intCast(y)) * ref.stride + @as(usize, @intCast(x));
        stride = ref.stride;
    } else {
        for (0..h + 1) |j| {
            for (0..w + 1) |i| win[j * 17 + i] = @intCast(ref.at(x + @as(i32, @intCast(i)), y + @as(i32, @intCast(j))));
        }
    }
    // Which of the four samples count: those of a whole sample across or
    // down are left out.
    switch (@as(u2, @intFromBool(fx != 0)) | @as(u2, @intFromBool(fy != 0)) << 1) {
        inline else => |kind| blend(kind, P, src, stride, weights, w, h, dst, dst_stride),
    }
}

fn blend(comptime kind: u2, comptime P: type, s: [*]const P, stride: usize, k: [4]i32, w: u32, h: u32, dst: [*]u16, dst_stride: usize) void {
    for (0..h) |j| {
        const r0 = s + j * stride;
        const r1 = r0 + stride;
        const out = dst + j * dst_stride;
        for (0..w) |i| {
            out[i] = switch (kind) {
                0 => r0[i],
                1 => @intCast((k[0] * @as(i32, r0[i]) + k[1] * @as(i32, r0[i + 1]) + 32) >> 6),
                2 => @intCast((k[0] * @as(i32, r0[i]) + k[2] * @as(i32, r1[i]) + 32) >> 6),
                3 => @intCast((k[0] * @as(i32, r0[i]) + k[1] * @as(i32, r0[i + 1]) + k[2] * @as(i32, r1[i]) + k[3] * @as(i32, r1[i + 1]) + 32) >> 6),
            };
        }
    }
}

/// One list's block weighted (8.4.2.3.2) into the picture.
pub fn weight1(comptime P: type, dst: [*]P, stride: usize, src: [*]const u16, sstride: usize, w: u32, h: u32, log_wd: u32, wt: i32, off: i32, max: i32) void {
    // A denominator of 1 rounds nothing: 8-270's two cases in one.
    const round: i32 = (@as(i32, 1) << @intCast(log_wd)) >> 1;
    const shift: u5 = @intCast(log_wd);
    for (0..h) |j| {
        const in = src + j * sstride;
        const out = dst + j * stride;
        for (0..w) |i| out[i] = @intCast(clip(((@as(i32, in[i]) * wt + round) >> shift) + off, max));
    }
}

/// Two lists' blocks weighted together.
pub fn weight2(comptime P: type, dst: [*]P, stride: usize, s0: [*]const u16, s1: [*]const u16, sstride: usize, w: u32, h: u32, log_wd: u32, w0: i32, w1: i32, off: i32, max: i32) void {
    const round: i32 = @as(i32, 1) << @intCast(log_wd);
    const shift: u5 = @intCast(log_wd + 1);
    for (0..h) |j| {
        const a = s0 + j * sstride;
        const b = s1 + j * sstride;
        const out = dst + j * stride;
        for (0..w) |i| out[i] = @intCast(clip(((@as(i32, a[i]) * w0 + @as(i32, b[i]) * w1 + round) >> shift) + off, max));
    }
}

/// The default prediction: one block as it is, or two averaged.
pub fn put1(comptime P: type, dst: [*]P, stride: usize, src: [*]const u16, sstride: usize, w: u32, h: u32) void {
    for (0..h) |j| {
        for (0..w) |i| dst[j * stride + i] = @intCast(src[j * sstride + i]);
    }
}

pub fn put2(comptime P: type, dst: [*]P, stride: usize, s0: [*]const u16, s1: [*]const u16, sstride: usize, w: u32, h: u32) void {
    for (0..h) |j| {
        for (0..w) |i| dst[j * stride + i] = @intCast((@as(u32, s0[j * sstride + i]) + s1[j * sstride + i] + 1) >> 1);
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "a flat picture predicts flat at every quarter; a ramp's half sample is its middle" {
    var flat: [32 * 32]u8 = @splat(77);
    const pf: Plane(u8) = .{ .data = &flat, .stride = 32, .width = 32, .height = 32 };
    var out: [16 * 16]u16 = undefined;
    var work: Work = .{};
    for (0..4) |fy| {
        for (0..4) |fx| {
            luma(u8, &work, pf, -3, 30, @intCast(fx), @intCast(fy), 8, 8, &out, 16, 255);
            for (0..8) |j| {
                for (0..8) |i| try testing.expectEqual(@as(u16, 77), out[j * 16 + i]);
            }
        }
    }
    var ramp: [32 * 32]u8 = undefined;
    for (0..32) |j| {
        for (0..32) |i| ramp[j * 32 + i] = @intCast(i * 4);
    }
    const pr: Plane(u8) = .{ .data = &ramp, .stride = 32, .width = 32, .height = 32 };
    luma(u8, &work, pr, 8, 8, 2, 0, 4, 4, &out, 16, 255);
    try testing.expectEqual(@as(u16, 34), out[0]);
    chroma(u8, &work, pr, 8, 8, 4, 0, 2, 2, &out, 16);
    try testing.expectEqual(@as(u16, 34), out[0]);
}

/// 8-243 to 8-261 sample by sample, as the standard writes them.
fn lumaAsWritten(ref: Plane(u16), x: i32, y: i32, fx: u32, fy: u32, i: i32, j: i32, max: i32) i32 {
    const G = struct {
        fn b1(r: Plane(u16), xx: i32, yy: i32) i32 {
            return tap6(r.at(xx - 2, yy), r.at(xx - 1, yy), r.at(xx, yy), r.at(xx + 1, yy), r.at(xx + 2, yy), r.at(xx + 3, yy));
        }
        fn h1(r: Plane(u16), xx: i32, yy: i32) i32 {
            return tap6(r.at(xx, yy - 2), r.at(xx, yy - 1), r.at(xx, yy), r.at(xx, yy + 1), r.at(xx, yy + 2), r.at(xx, yy + 3));
        }
    };
    const xx = x + i;
    const yy = y + j;
    const g = ref.at(xx, yy);
    const b = clip((G.b1(ref, xx, yy) + 16) >> 5, max);
    const hh = clip((G.h1(ref, xx, yy) + 16) >> 5, max);
    const s = clip((G.b1(ref, xx, yy + 1) + 16) >> 5, max);
    const m = clip((G.h1(ref, xx + 1, yy) + 16) >> 5, max);
    const jj = clip((tap6(G.b1(ref, xx, yy - 2), G.b1(ref, xx, yy - 1), G.b1(ref, xx, yy), G.b1(ref, xx, yy + 1), G.b1(ref, xx, yy + 2), G.b1(ref, xx, yy + 3)) + 512) >> 10, max);
    return switch (fy * 4 + fx) {
        0 => g,
        1 => (g + b + 1) >> 1,
        2 => b,
        3 => (ref.at(xx + 1, yy) + b + 1) >> 1,
        4 => (g + hh + 1) >> 1,
        5 => (b + hh + 1) >> 1,
        6 => (b + jj + 1) >> 1,
        7 => (b + m + 1) >> 1,
        8 => hh,
        9 => (hh + jj + 1) >> 1,
        10 => jj,
        11 => (jj + m + 1) >> 1,
        12 => (ref.at(xx, yy + 1) + hh + 1) >> 1,
        13 => (hh + s + 1) >> 1,
        14 => (jj + s + 1) >> 1,
        else => (m + s + 1) >> 1,
    };
}

test "every quarter position as the standard writes it, inside the picture and over its edges, at 8 and 14 bits" {
    var noise: [40 * 36]u16 = undefined;
    var seed: u32 = 12345;
    for (&noise) |*v| {
        seed = seed *% 1103515245 +% 12345;
        v.* = @intCast((seed >> 8) & 0x3FFF);
    }
    for ([_]i32{ 255, 16383 }) |max| {
        var picture: [40 * 36]u16 = undefined;
        for (&picture, noise) |*v, n| v.* = @intCast(@as(i32, n) & max);
        const ref: Plane(u16) = .{ .data = &picture, .stride = 40, .width = 40, .height = 36 };
        var out: [16 * 16]u16 = undefined;
        var work: Work = .{};
        for ([_][2]i32{ .{ 10, 9 }, .{ -5, -4 }, .{ 30, 28 }, .{ -20, 40 } }) |at| {
            for ([_][2]u32{ .{ 16, 16 }, .{ 8, 4 }, .{ 4, 8 } }) |size| {
                for (0..16) |pos| {
                    const fx: u32 = @intCast(pos & 3);
                    const fy: u32 = @intCast(pos >> 2);
                    luma(u16, &work, ref, at[0], at[1], fx, fy, size[0], size[1], &out, 16, max);
                    for (0..size[1]) |j| {
                        for (0..size[0]) |i| {
                            const want = lumaAsWritten(ref, at[0], at[1], fx, fy, @intCast(i), @intCast(j), max);
                            try testing.expectEqual(want, out[j * 16 + i]);
                        }
                    }
                }
                // Chroma at every eighth, as 8-266 writes it.
                for (0..64) |e| {
                    const fx: u32 = @intCast(e & 7);
                    const fy: u32 = @intCast(e >> 3);
                    chroma(u16, &work, ref, at[0], at[1], fx, fy, size[0] / 2, size[1] / 2, &out, 16);
                    for (0..size[1] / 2) |j| {
                        for (0..size[0] / 2) |i| {
                            const xx = at[0] + @as(i32, @intCast(i));
                            const yy = at[1] + @as(i32, @intCast(j));
                            const want = (@as(i32, @intCast((8 - fx) * (8 - fy))) * ref.at(xx, yy) + @as(i32, @intCast(fx * (8 - fy))) * ref.at(xx + 1, yy) +
                                @as(i32, @intCast((8 - fx) * fy)) * ref.at(xx, yy + 1) + @as(i32, @intCast(fx * fy)) * ref.at(xx + 1, yy + 1) + 32) >> 6;
                            try testing.expectEqual(want, out[j * 16 + i]);
                        }
                    }
                }
            }
        }
    }
}

// SPDX-License-Identifier: MIT
//! Inter prediction's samples (8.5.3.3): a block of a reference picture
//! at a quarter-sample position for luma - the eight-tap filters - or an
//! eighth for chroma - the four-tap ones - at 14 bits, and the weighting
//! of one or two such blocks into the picture (8.5.3.3.4).
//!
//! A position outside the reference picture takes the nearest sample on
//! its edge (8-222, 8-239).

const tables = @import("tables.zig");

/// A plane of a reference picture.
pub fn Plane(comptime T: type) type {
    return struct {
        data: [*]const T,
        stride: usize,
        width: i32,
        height: i32,

        inline fn at(p: @This(), x: i32, y: i32) T {
            const cx: usize = @intCast(if (x < 0) 0 else if (x >= p.width) p.width - 1 else x);
            const cy: usize = @intCast(if (y < 0) 0 else if (y >= p.height) p.height - 1 else y);
            return p.data[cy * p.stride + cx];
        }
    };
}

/// The largest block, 64 x 64, with the luma filter's 7 more each way.
const win_w = 64 + 7;

/// What a block's prediction works in: the samples gathered for a block
/// over the edge, and the first pass of a filter both ways. Kept by the
/// decoder rather than on the stack.
pub const Work = struct {
    win: [win_w * win_w]u16 = undefined,
    tmp: [win_w * 64]i32 = undefined,
};

/// The `w + taps - 1` by `h + taps - 1` samples a filter of `taps` reaches
/// for a block at (x, y), from (x - before, y - before): where they are
/// in the picture, or gathered into `work` when some are past the edge.
fn window(comptime T: type, work: *Work, ref: Plane(T), x: i32, y: i32, w: u32, h: u32, comptime taps: u32) struct { src: [*]const T, stride: usize } {
    const before: i32 = taps / 2 - 1;
    const ww = w + taps - 1;
    const wh = h + taps - 1;
    const x0 = x - before;
    const y0 = y - before;
    if (x0 >= 0 and y0 >= 0 and x0 + @as(i32, @intCast(ww)) <= ref.width and y0 + @as(i32, @intCast(wh)) <= ref.height) {
        return .{ .src = ref.data + @as(usize, @intCast(y0)) * ref.stride + @as(usize, @intCast(x0)), .stride = ref.stride };
    }
    const win: [*]T = @ptrCast(&work.win);
    for (0..wh) |j| {
        const sy = y0 + @as(i32, @intCast(j));
        for (0..ww) |i| win[j * win_w + i] = ref.at(x0 + @as(i32, @intCast(i)), sy);
    }
    return .{ .src = win, .stride = win_w };
}

/// A `w` x `h` block at full-sample (x, y) plus (fx, fy) in 1 / (1 <<
/// `frac_bits`) of a sample, filtered with `filter`, into `dst` at 14
/// bits (8.5.3.3.3.2, 8.5.3.3.3.3).
fn block(comptime T: type, comptime taps: u32, comptime filter: anytype, work: *Work, ref: Plane(T), x: i32, y: i32, fx: u32, fy: u32, w: u32, h: u32, depth: u5, dst: [*]i32, dst_stride: usize) void {
    const shift1: u5 = @min(4, depth - 8);
    const shift3: u5 = if (depth >= 12) 2 else 14 - depth;
    const win = window(T, work, ref, x, y, w, h, taps);
    const before = taps / 2 - 1;
    const src = win.src;
    const stride = win.stride;
    if (fx == 0 and fy == 0) {
        for (0..h) |j| {
            const row = src + (j + before) * stride + before;
            const out = dst + j * dst_stride;
            for (0..w) |i| out[i] = @as(i32, row[i]) << shift3;
        }
        return;
    }
    if (fy == 0) {
        const f = filter[fx];
        for (0..h) |j| {
            const row = src + (j + before) * stride;
            const out = dst + j * dst_stride;
            for (0..w) |i| {
                var s: i32 = 0;
                inline for (0..taps) |k| s += @as(i32, f[k]) * row[i + k];
                out[i] = s >> shift1;
            }
        }
        return;
    }
    if (fx == 0) {
        const f = filter[fy];
        for (0..h) |j| {
            const col = src + j * stride + before;
            const out = dst + j * dst_stride;
            for (0..w) |i| {
                var s: i32 = 0;
                inline for (0..taps) |k| s += @as(i32, f[k]) * col[i + k * stride];
                out[i] = s >> shift1;
            }
        }
        return;
    }
    // Across first, the rows the filter down needs, then down.
    const fh = filter[fx];
    const fv = filter[fy];
    const t = &work.tmp;
    for (0..h + taps - 1) |j| {
        const row = src + j * stride;
        for (0..w) |i| {
            var s: i32 = 0;
            inline for (0..taps) |k| s += @as(i32, fh[k]) * row[i + k];
            t[j * 64 + i] = s >> shift1;
        }
    }
    for (0..h) |j| {
        const out = dst + j * dst_stride;
        for (0..w) |i| {
            var s: i32 = 0;
            inline for (0..taps) |k| s += @as(i32, fv[k]) * t[(j + k) * 64 + i];
            out[i] = s >> 6;
        }
    }
}

/// A luma block at (x, y) plus (fx, fy) quarters.
pub fn luma(comptime T: type, work: *Work, ref: Plane(T), x: i32, y: i32, fx: u32, fy: u32, w: u32, h: u32, depth: u5, dst: [*]i32, dst_stride: usize) void {
    block(T, 8, tables.luma_filter, work, ref, x, y, fx, fy, w, h, depth, dst, dst_stride);
}

/// A chroma block at (x, y) plus (fx, fy) eighths.
pub fn chroma(comptime T: type, work: *Work, ref: Plane(T), x: i32, y: i32, fx: u32, fy: u32, w: u32, h: u32, depth: u5, dst: [*]i32, dst_stride: usize) void {
    block(T, 4, tables.chroma_filter, work, ref, x, y, fx, fy, w, h, depth, dst, dst_stride);
}

inline fn clip(v: i32, max: i32) i32 {
    return if (v < 0) 0 else if (v > max) max else v;
}

/// One prediction into the picture, unweighted (8-262).
pub fn putUni(comptime T: type, src: [*]const i32, src_stride: usize, w: u32, h: u32, depth: u5, dst: [*]T, dst_stride: usize) void {
    const shift: u5 = if (depth >= 12) 2 else 14 - depth;
    const off: i32 = @as(i32, 1) << (shift - 1);
    const max: i32 = (@as(i32, 1) << depth) - 1;
    for (0..h) |j| {
        const s = src + j * src_stride;
        const d = dst + j * dst_stride;
        for (0..w) |i| d[i] = @intCast(clip((s[i] + off) >> shift, max));
    }
}

/// Two predictions averaged into the picture (8-264).
pub fn putBi(comptime T: type, a: [*]const i32, b: [*]const i32, src_stride: usize, w: u32, h: u32, depth: u5, dst: [*]T, dst_stride: usize) void {
    const shift: u5 = if (depth >= 12) 3 else 15 - depth;
    const off: i32 = @as(i32, 1) << (shift - 1);
    const max: i32 = (@as(i32, 1) << depth) - 1;
    for (0..h) |j| {
        const sa = a + j * src_stride;
        const sb = b + j * src_stride;
        const d = dst + j * dst_stride;
        for (0..w) |i| d[i] = @intCast(clip((sa[i] + sb[i] + off) >> shift, max));
    }
}

/// One prediction weighted (8-275): `log2wd` is the denominator's log2
/// plus the 14 bits' shift, `o` the offset at the sample depth.
pub fn putWeighted(comptime T: type, src: [*]const i32, src_stride: usize, w: u32, h: u32, depth: u5, weight: i32, o: i32, log2wd: u5, dst: [*]T, dst_stride: usize) void {
    const max: i32 = (@as(i32, 1) << depth) - 1;
    const rnd: i32 = @as(i32, 1) << (log2wd - 1);
    for (0..h) |j| {
        const s = src + j * src_stride;
        const d = dst + j * dst_stride;
        for (0..w) |i| d[i] = @intCast(clip(((s[i] * weight + rnd) >> log2wd) + o, max));
    }
}

/// Two predictions weighted (8-277).
pub fn putWeightedBi(comptime T: type, a: [*]const i32, b: [*]const i32, src_stride: usize, w: u32, h: u32, depth: u5, w0: i32, w1: i32, o0: i32, o1: i32, log2wd: u5, dst: [*]T, dst_stride: usize) void {
    const max: i32 = (@as(i32, 1) << depth) - 1;
    const sh: u5 = log2wd + 1;
    const add: i32 = (o0 + o1 + 1) << log2wd;
    for (0..h) |j| {
        const sa = a + j * src_stride;
        const sb = b + j * src_stride;
        const d = dst + j * dst_stride;
        for (0..w) |i| d[i] = @intCast(clip((sa[i] * w0 + sb[i] * w1 + add) >> sh, max));
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

/// The luma sample of Table 8-8 as the standard writes it.
fn lumaNaive(ref: Plane(u8), x: i32, y: i32, fx: u32, fy: u32) i32 {
    const f = tables.luma_filter;
    if (fy == 0) {
        if (fx == 0) return @as(i32, ref.at(x, y)) << 6;
        var s: i32 = 0;
        for (0..8) |k| s += @as(i32, f[fx][k]) * ref.at(x + @as(i32, @intCast(k)) - 3, y);
        return s;
    }
    if (fx == 0) {
        var s: i32 = 0;
        for (0..8) |k| s += @as(i32, f[fy][k]) * ref.at(x, y + @as(i32, @intCast(k)) - 3);
        return s;
    }
    var s: i32 = 0;
    for (0..8) |k| {
        var a: i32 = 0;
        for (0..8) |m| a += @as(i32, f[fx][m]) * ref.at(x + @as(i32, @intCast(m)) - 3, y + @as(i32, @intCast(k)) - 3);
        s += @as(i32, f[fy][k]) * a;
    }
    return s >> 6;
}

test "luma interpolation, inside and over the edge" {
    var prng = std.Random.DefaultPrng.init(11);
    const rnd = prng.random();
    var pic: [40 * 30]u8 = undefined;
    for (&pic) |*v| v.* = rnd.int(u8);
    const ref: Plane(u8) = .{ .data = &pic, .stride = 40, .width = 40, .height = 30 };
    var work: Work = .{};
    var out: [16 * 16]i32 = undefined;
    for (0..16) |pos| {
        const fx: u32 = @intCast(pos & 3);
        const fy: u32 = @intCast(pos >> 2);
        for ([_][2]i32{ .{ 10, 8 }, .{ -5, -3 }, .{ 30, 20 } }) |at| {
            luma(u8, &work, ref, at[0], at[1], fx, fy, 16, 8, 8, &out, 16);
            for (0..8) |j| {
                for (0..16) |i| try testing.expectEqual(lumaNaive(ref, at[0] + @as(i32, @intCast(i)), at[1] + @as(i32, @intCast(j)), fx, fy), out[j * 16 + i]);
            }
        }
    }
}

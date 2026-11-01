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
    // The columns before the picture's left edge, those in it and those
    // past its right edge.
    const left: u32 = @intCast(@min(@as(i32, @intCast(ww)), @max(0, -x0)));
    const inside_end: u32 = @intCast(@max(@as(i32, @intCast(left)), @min(@as(i32, @intCast(ww)), ref.width - x0)));
    for (0..wh) |j| {
        const sy = y0 + @as(i32, @intCast(j));
        const row = ref.data + @as(usize, @intCast(if (sy < 0) 0 else if (sy >= ref.height) ref.height - 1 else sy)) * ref.stride;
        const out = win + j * win_w;
        @memset(out[0..left], row[0]);
        if (inside_end > left) {
            const from: usize = @intCast(x0 + @as(i32, @intCast(left)));
            @memcpy(out[left..inside_end], row[from..][0 .. inside_end - left]);
        }
        @memset(out[inside_end..ww], row[@intCast(ref.width - 1)]);
    }
    return .{ .src = win, .stride = win_w };
}

/// Where a block's prediction goes (8.5.3.3.4.2): kept at 14 bits, for a
/// weighting or for the second of two, or put into the picture - alone,
/// or averaged with the first, kept before.
pub const Put = enum { keep, uni, bi };

pub fn Out(comptime T: type) type {
    return struct {
        /// keep: where the 14-bit samples go; bi: the first prediction.
        pred: [*]i32,
        pred_stride: usize,
        /// uni and bi: the block in the picture.
        pic: [*]T = undefined,
        pic_stride: usize = 0,
    };
}

/// The sample `i` of a row of the block, `v` at 14 bits, put as `put`
/// says with `shift` and `max` for it: `pred` and `pic` the row's.
inline fn emit(comptime T: type, comptime put: Put, pred: [*]i32, pic: [*]T, i: usize, v: i32, shift: u5, max: i32) void {
    switch (put) {
        .keep => pred[i] = v,
        .uni => pic[i] = @intCast(clip((v + (@as(i32, 1) << (shift - 1))) >> shift, max)),
        .bi => pic[i] = @intCast(clip((pred[i] + v + (@as(i32, 1) << (shift - 1))) >> shift, max)),
    }
}

/// The filter at `s`, its taps `step` apart: `fixed` when it is known as
/// the code is made - its taps then cost what their values do - else `f`.
inline fn filtered(comptime Src: type, comptime n: usize, comptime fixed: ?[n]i8, f: [n]i8, s: [*]const Src, step: usize) i32 {
    var sum: i32 = 0;
    inline for (0..n) |k| {
        if (fixed) |c| {
            if (c[k] != 0) sum += @as(i32, c[k]) * @as(i32, s[k * step]);
        } else sum += @as(i32, f[k]) * @as(i32, s[k * step]);
    }
    return sum;
}

/// `h` rows of `w` samples filtered, its taps `step` apart in `src`,
/// shifted down by `down` and put as `put` says.
fn pass(comptime T: type, comptime Src: type, comptime n: usize, comptime put: Put, comptime fixed: ?[n]i8, f: [n]i8, src: [*]const Src, src_stride: usize, step: usize, w: u32, h: u32, down: u5, out: Out(T), shift: u5, max: i32) void {
    for (0..h) |j| {
        const row = src + j * src_stride;
        const pred = out.pred + j * out.pred_stride;
        const pic = if (put == .keep) undefined else out.pic + j * out.pic_stride;
        for (0..w) |i| emit(T, put, pred, pic, i, filtered(Src, n, fixed, f, row + i, step) >> down, shift, max);
    }
}

/// `pass` with the filter of position `pos` of `filter`: a luma one made
/// for each position, a chroma one for any.
fn passAt(comptime T: type, comptime Src: type, comptime n: usize, comptime filter: anytype, comptime put: Put, pos: u32, src: [*]const Src, src_stride: usize, step: usize, w: u32, h: u32, down: u5, out: Out(T), shift: u5, max: i32) void {
    if (n == 8) {
        switch (pos) {
            inline 1...filter.len - 1 => |p| pass(T, Src, n, put, filter[p], filter[p], src, src_stride, step, w, h, down, out, shift, max),
            else => unreachable,
        }
    } else pass(T, Src, n, put, null, filter[pos], src, src_stride, step, w, h, down, out, shift, max);
}

/// A `w` x `h` block at full-sample (x, y) plus (fx, fy) in the parts of a
/// sample `filter` has positions for, filtered at 14 bits (8.5.3.3.3.2,
/// 8.5.3.3.3.3) and put as `put` says.
fn block(comptime T: type, comptime n: u32, comptime filter: anytype, comptime put: Put, work: *Work, ref: Plane(T), x: i32, y: i32, fx: u32, fy: u32, w: u32, h: u32, depth: u5, out: Out(T)) void {
    const shift1: u5 = @min(4, depth - 8);
    const shift3: u5 = if (depth >= 12) 2 else 14 - depth;
    // What a put into the picture shifts down by (8-262, 8-264).
    const shift: u5 = switch (put) {
        .keep => 0,
        .uni => shift3,
        .bi => if (depth >= 12) 3 else 15 - depth,
    };
    const max: i32 = (@as(i32, 1) << depth) - 1;
    const win = window(T, work, ref, x, y, w, h, n);
    const before = n / 2 - 1;
    const src = win.src;
    const stride = win.stride;
    if (fx == 0 and fy == 0) {
        for (0..h) |j| {
            const row = src + (j + before) * stride + before;
            if (put == .uni) {
                // Shifted up and down again: the samples as they are.
                @memcpy(out.pic[j * out.pic_stride ..][0..w], row[0..w]);
                continue;
            }
            const pred = out.pred + j * out.pred_stride;
            const pic = if (put == .keep) undefined else out.pic + j * out.pic_stride;
            for (0..w) |i| emit(T, put, pred, pic, i, @as(i32, row[i]) << shift3, shift, max);
        }
        return;
    }
    if (fy == 0) return passAt(T, T, n, filter, put, fx, src + before * stride, stride, 1, w, h, shift1, out, shift, max);
    if (fx == 0) return passAt(T, T, n, filter, put, fy, src + before, stride, stride, w, h, shift1, out, shift, max);
    // Across first, the rows the filter down needs, then down.
    const t: [*]i32 = &work.tmp;
    passAt(T, T, n, filter, .keep, fx, src, stride, 1, w, h + n - 1, shift1, .{ .pred = t, .pred_stride = 64 }, 0, 0);
    passAt(T, i32, n, filter, put, fy, t, 64, 64, w, h, 6, out, shift, max);
}

/// A luma block at (x, y) plus (fx, fy) quarters.
pub fn luma(comptime T: type, comptime put: Put, work: *Work, ref: Plane(T), x: i32, y: i32, fx: u32, fy: u32, w: u32, h: u32, depth: u5, out: Out(T)) void {
    block(T, 8, tables.luma_filter, put, work, ref, x, y, fx, fy, w, h, depth, out);
}

/// A chroma block at (x, y) plus (fx, fy) eighths.
pub fn chroma(comptime T: type, comptime put: Put, work: *Work, ref: Plane(T), x: i32, y: i32, fx: u32, fy: u32, w: u32, h: u32, depth: u5, out: Out(T)) void {
    block(T, 4, tables.chroma_filter, put, work, ref, x, y, fx, fy, w, h, depth, out);
}

inline fn clip(v: i32, max: i32) i32 {
    return if (v < 0) 0 else if (v > max) max else v;
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
            luma(u8, .keep, &work, ref, at[0], at[1], fx, fy, 16, 8, 8, .{ .pred = &out, .pred_stride = 16 });
            for (0..8) |j| {
                for (0..16) |i| try testing.expectEqual(lumaNaive(ref, at[0] + @as(i32, @intCast(i)), at[1] + @as(i32, @intCast(j)), fx, fy), out[j * 16 + i]);
            }
        }
    }
}

test "a prediction put into the picture as kept and weighted by default" {
    var prng = std.Random.DefaultPrng.init(12);
    const rnd = prng.random();
    var pic: [40 * 30]u8 = undefined;
    for (&pic) |*v| v.* = rnd.int(u8);
    const ref: Plane(u8) = .{ .data = &pic, .stride = 40, .width = 40, .height = 30 };
    var work: Work = .{};
    var first: [8 * 8]i32 = undefined;
    var second: [8 * 8]i32 = undefined;
    var got: [8 * 8]u8 = undefined;
    for (0..64) |pos| {
        const fx: u32 = @intCast(pos & 7);
        const fy: u32 = @intCast(pos >> 3);
        for ([_][2]i32{ .{ 10, 8 }, .{ -5, -3 }, .{ 36, 26 } }) |at| {
            const keep: Out(u8) = .{ .pred = &first, .pred_stride = 8 };
            chroma(u8, .keep, &work, ref, at[0], at[1], fx, fy, 8, 8, 8, keep);
            chroma(u8, .keep, &work, ref, at[1], at[0], fy, fx, 8, 8, 8, .{ .pred = &second, .pred_stride = 8 });
            // Alone (8-262).
            chroma(u8, .uni, &work, ref, at[0], at[1], fx, fy, 8, 8, 8, .{ .pred = &second, .pred_stride = 8, .pic = &got, .pic_stride = 8 });
            for (0..64) |i| try testing.expectEqual(clip((first[i] + 32) >> 6, 255), got[i]);
            // Averaged with the first (8-264).
            chroma(u8, .bi, &work, ref, at[1], at[0], fy, fx, 8, 8, 8, .{ .pred = &first, .pred_stride = 8, .pic = &got, .pic_stride = 8 });
            for (0..64) |i| try testing.expectEqual(clip((first[i] + second[i] + 64) >> 7, 255), got[i]);
        }
    }
}

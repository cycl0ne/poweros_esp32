// SPDX-License-Identifier: MIT
//! A macroblock put together (RFC 6386 12, 14, 18): its prediction -
//! from its neighbours in the frame or from a reference frame - and its
//! residue, the inverse transforms' output added. The intra prediction
//! reads its neighbours before the loop filter, as the RFC has it.

const common = @import("common.zig");
const tables = @import("tables.zig");
const tokens = @import("tokens.zig");
const Frame = common.Frame;
const MbInfo = common.MbInfo;
const Mv = common.Mv;

inline fn clamp255(v: i32) u8 {
    return @intCast(@max(0, @min(255, v)));
}

inline fn avg2(a: u8, b: u8) u8 {
    return @intCast((@as(u32, a) + b + 1) >> 1);
}

inline fn avg3(a: u8, b: u8, c: u8) u8 {
    return @intCast((@as(u32, a) + 2 * @as(u32, b) + c + 2) >> 2);
}

// The transforms (14.3, 14.4), as libvpx computes them: the first pass
// kept in 16 bits.

/// The inverse Walsh-Hadamard transform of the second-order block, its
/// outputs the brightness blocks' DC coefficients.
pub fn walsh(in: *const [16]i16, out: *tokens.Coeffs) void {
    var t: [16]i16 = undefined;
    for (0..4) |i| {
        const a1 = @as(i32, in[i]) + in[12 + i];
        const b1 = @as(i32, in[4 + i]) + in[8 + i];
        const c1 = @as(i32, in[4 + i]) - in[8 + i];
        const d1 = @as(i32, in[i]) - in[12 + i];
        t[i] = @truncate(a1 + b1);
        t[4 + i] = @truncate(c1 + d1);
        t[8 + i] = @truncate(a1 - b1);
        t[12 + i] = @truncate(d1 - c1);
    }
    for (0..4) |i| {
        const r = t[i * 4 ..][0..4];
        const a1 = @as(i32, r[0]) + r[3];
        const b1 = @as(i32, r[1]) + r[2];
        const c1 = @as(i32, r[1]) - r[2];
        const d1 = @as(i32, r[0]) - r[3];
        out[i * 4 + 0][0] = @truncate((a1 + b1 + 3) >> 3);
        out[i * 4 + 1][0] = @truncate((c1 + d1 + 3) >> 3);
        out[i * 4 + 2][0] = @truncate((a1 - b1 + 3) >> 3);
        out[i * 4 + 3][0] = @truncate((d1 - c1 + 3) >> 3);
    }
}

inline fn mul35468(v: i32) i32 {
    return (v * 35468) >> 16;
}

inline fn mul20091(v: i32) i32 {
    return v + ((v * 20091) >> 16);
}

/// The inverse DCT of `in` added to the 4x4 block at `dst`.
pub fn idctAdd(in: *const [16]i16, dst: [*]u8, stride: usize) void {
    var t: [16]i16 = undefined;
    for (0..4) |i| {
        const a1 = @as(i32, in[i]) + in[8 + i];
        const b1 = @as(i32, in[i]) - in[8 + i];
        const c1 = mul35468(in[4 + i]) - mul20091(in[12 + i]);
        const d1 = mul20091(in[4 + i]) + mul35468(in[12 + i]);
        t[i] = @truncate(a1 + d1);
        t[12 + i] = @truncate(a1 - d1);
        t[4 + i] = @truncate(b1 + c1);
        t[8 + i] = @truncate(b1 - c1);
    }
    for (0..4) |i| {
        const r = t[i * 4 ..][0..4];
        const a1 = @as(i32, r[0]) + r[2];
        const b1 = @as(i32, r[0]) - r[2];
        const c1 = mul35468(r[1]) - mul20091(r[3]);
        const d1 = mul20091(r[1]) + mul35468(r[3]);
        const row = dst + i * stride;
        const o = [4]i16{ @truncate((a1 + d1 + 4) >> 3), @truncate((b1 + c1 + 4) >> 3), @truncate((b1 - c1 + 4) >> 3), @truncate((a1 - d1 + 4) >> 3) };
        for (0..4) |x| row[x] = clamp255(@as(i32, row[x]) + o[x]);
    }
}

/// A block with only its DC coefficient: the same as `idctAdd`, faster.
fn dcAdd(dc: i16, dst: [*]u8, stride: usize) void {
    const d: i32 = (@as(i32, dc) + 4) >> 3;
    for (0..4) |y| {
        const row = dst + y * stride;
        for (0..4) |x| row[x] = clamp255(@as(i32, row[x]) + d);
    }
}

/// Block `blk`'s residue added at `dst`, when it has any; its
/// coefficients cleared for the next macroblock.
fn residue(coeffs: *tokens.Coeffs, blk: usize, dst: [*]u8, stride: usize) void {
    const c = &coeffs[blk];
    var ac = false;
    for (c[1..]) |v| ac = ac or v != 0;
    if (ac) {
        idctAdd(c, dst, stride);
        c.* = @splat(0);
    } else if (c[0] != 0) {
        dcAdd(c[0], dst, stride);
        c[0] = 0;
    }
}

// Intra prediction works in a little copy of the macroblock with its
// neighbours around it - a row above, with the pixel above-left and four
// above-right, and a column left - where the frame's edges have their
// values (127 above, 129 left) and the subblocks of the right column find
// the above-right pixels of the top one.

const ws_stride = 32;

pub const Workspace = struct {
    /// 17 rows: above, then the 16 of the macroblock; column 0 is left.
    y: [17 * ws_stride]u8 = undefined,
    /// Cb then Cr: 9 rows each.
    uv: [2][9 * ws_stride]u8 = undefined,
};

/// The neighbours of macroblock (`r`, `c`) of `cols` across into `ws`,
/// from frame `f` as decoded so far.
fn edges(ws: *Workspace, f: *const Frame, r: u32, c: u32, cols: u32) void {
    const y = &ws.y;
    const s = f.stride[0];
    const x0 = c * 16;
    const y0 = r * 16;
    if (r == 0) {
        @memset(y[0..21], 127);
    } else {
        const above = f.planes[0] + (y0 - 1) * s + x0;
        y[0] = if (c == 0) 129 else (above - 1)[0];
        @memcpy(y[1..17], above[0..16]);
        if (c + 1 == cols) {
            @memset(y[17..21], above[15]);
        } else @memcpy(y[17..21], above[16..20]);
    }
    for (0..16) |i| y[(i + 1) * ws_stride] = if (c == 0) 129 else f.planes[0][(y0 + i) * s + x0 - 1];
    // The right column's subblocks below the top one take its
    // above-right pixels.
    for ([_]usize{ 4, 8, 12 }) |row| @memcpy(y[row * ws_stride + 17 ..][0..4], y[17..21]);

    const cs = f.stride[1];
    for (0..2) |p| {
        const u = &ws.uv[p];
        const plane = f.planes[1 + p];
        if (r == 0) {
            @memset(u[0..9], 127);
        } else {
            const above = plane + (r * 8 - 1) * cs + c * 8;
            u[0] = if (c == 0) 129 else (above - 1)[0];
            @memcpy(u[1..9], above[0..8]);
        }
        for (0..8) |i| u[(i + 1) * ws_stride] = if (c == 0) 129 else plane[(r * 8 + i) * cs + c * 8 - 1];
    }
}

/// 16x16 or 8x8 prediction by `mode` at `p` (rows `ws_stride` apart),
/// the neighbours around it; DC by those inside the frame.
fn predictWhole(p: [*]u8, n: usize, mode: u8, r: u32, c: u32) void {
    const above = p - ws_stride;
    switch (mode) {
        common.V_PRED => for (0..n) |i| @memcpy(p[i * ws_stride ..][0..n], above[0..n]),
        common.H_PRED => for (0..n) |i| @memset(p[i * ws_stride ..][0..n], (p + i * ws_stride - 1)[0]),
        common.TM_PRED => {
            const corner: i32 = (above - 1)[0];
            for (0..n) |i| {
                const left: i32 = (p + i * ws_stride - 1)[0];
                for (0..n) |j| p[i * ws_stride + j] = clamp255(left + above[j] - corner);
            }
        },
        else => {
            const shift: u5 = if (n == 16) 3 else 2;
            var sum: u32 = 0;
            var count: u5 = 0;
            if (r > 0) {
                for (above[0..n]) |v| sum += v;
                count += 1;
            }
            if (c > 0) {
                for (0..n) |i| sum += (p + i * ws_stride - 1)[0];
                count += 1;
            }
            const dc: u8 = if (count == 0) 128 else @intCast((sum + (@as(u32, @intCast(n)) << (count - 1) >> 1)) >> (shift + count));
            for (0..n) |i| @memset(p[i * ws_stride ..][0..n], dc);
        },
    }
}

/// A 4x4 subblock's prediction by `mode` at `p`.
fn predictSub(p: [*]u8, mode: u8) void {
    const s = ws_stride;
    const a = p - s; // a[-1] above-left, a[0..8] above and above-right
    const l = [4]u8{ (p - 1)[0], (p + s - 1)[0], (p + 2 * s - 1)[0], (p + 3 * s - 1)[0] };
    const tl = (a - 1)[0];
    var o: [4][4]u8 = undefined;
    switch (mode) {
        common.B_DC_PRED => {
            var sum: u32 = 4;
            for (0..4) |i| sum += @as(u32, a[i]) + l[i];
            o = @splat(@splat(@intCast(sum >> 3)));
        },
        common.B_TM_PRED => for (0..4) |y| {
            for (0..4) |x| o[y][x] = clamp255(@as(i32, l[y]) + a[x] - tl);
        },
        common.B_VE_PRED => {
            const row = [4]u8{ avg3(tl, a[0], a[1]), avg3(a[0], a[1], a[2]), avg3(a[1], a[2], a[3]), avg3(a[2], a[3], a[4]) };
            o = @splat(row);
        },
        common.B_HE_PRED => {
            o[0] = @splat(avg3(tl, l[0], l[1]));
            o[1] = @splat(avg3(l[0], l[1], l[2]));
            o[2] = @splat(avg3(l[1], l[2], l[3]));
            o[3] = @splat(avg3(l[2], l[3], l[3]));
        },
        common.B_LD_PRED => for (0..4) |y| {
            for (0..4) |x| {
                const i = x + y;
                o[y][x] = if (i == 6) avg3(a[6], a[7], a[7]) else avg3(a[i], a[i + 1], a[i + 2]);
            }
        },
        common.B_RD_PRED => {
            // The edge from the bottom left round to the top right.
            const e = [9]u8{ l[3], l[2], l[1], l[0], tl, a[0], a[1], a[2], a[3] };
            for (0..4) |y| {
                for (0..4) |x| {
                    const i = 3 - y + x;
                    o[y][x] = avg3(e[i], e[i + 1], e[i + 2]);
                }
            }
        },
        common.B_VR_PRED => {
            o[0] = .{ avg2(tl, a[0]), avg2(a[0], a[1]), avg2(a[1], a[2]), avg2(a[2], a[3]) };
            o[1] = .{ avg3(l[0], tl, a[0]), avg3(tl, a[0], a[1]), avg3(a[0], a[1], a[2]), avg3(a[1], a[2], a[3]) };
            o[2] = .{ avg3(l[1], l[0], tl), o[0][0], o[0][1], o[0][2] };
            o[3] = .{ avg3(l[2], l[1], l[0]), o[1][0], o[1][1], o[1][2] };
        },
        common.B_VL_PRED => {
            o[0] = .{ avg2(a[0], a[1]), avg2(a[1], a[2]), avg2(a[2], a[3]), avg2(a[3], a[4]) };
            o[1] = .{ avg3(a[0], a[1], a[2]), avg3(a[1], a[2], a[3]), avg3(a[2], a[3], a[4]), avg3(a[3], a[4], a[5]) };
            o[2] = .{ o[0][1], o[0][2], o[0][3], avg3(a[4], a[5], a[6]) };
            o[3] = .{ o[1][1], o[1][2], o[1][3], avg3(a[5], a[6], a[7]) };
        },
        common.B_HD_PRED => {
            o[0] = .{ avg2(l[0], tl), avg3(l[0], tl, a[0]), avg3(tl, a[0], a[1]), avg3(a[0], a[1], a[2]) };
            o[1] = .{ avg2(l[1], l[0]), avg3(l[1], l[0], tl), o[0][0], o[0][1] };
            o[2] = .{ avg2(l[2], l[1]), avg3(l[2], l[1], l[0]), o[1][0], o[1][1] };
            o[3] = .{ avg2(l[3], l[2]), avg3(l[3], l[2], l[1]), o[2][0], o[2][1] };
        },
        else => { // B_HU_PRED
            o[0] = .{ avg2(l[0], l[1]), avg3(l[0], l[1], l[2]), avg2(l[1], l[2]), avg3(l[1], l[2], l[3]) };
            o[1] = .{ o[0][2], o[0][3], avg2(l[2], l[3]), avg3(l[2], l[3], l[3]) };
            o[2] = .{ o[1][2], o[1][3], l[3], l[3] };
            o[3] = @splat(l[3]);
        },
    }
    for (0..4) |y| @memcpy(p[y * s ..][0..4], &o[y]);
}

/// An intra macroblock (`r`, `c`) put together in frame `f`, with its
/// coefficients (`mask`: the blocks that have any; cleared after).
pub fn intra(mb: *const MbInfo, coeffs: *tokens.Coeffs, mask: u32, f: *Frame, r: u32, c: u32, cols: u32, ws: *Workspace) void {
    edges(ws, f, r, c, cols);
    const origin = ws.y[ws_stride + 1 ..].ptr;
    if (mb.y_mode == common.B_PRED) {
        for (0..16) |i| {
            const p = origin + (i >> 2) * 4 * ws_stride + (i & 3) * 4;
            predictSub(p, mb.b_modes[i]);
            if (mask >> @intCast(i) & 1 != 0) residue(coeffs, i, p, ws_stride);
        }
    } else {
        predictWhole(origin, 16, mb.y_mode, r, c);
        lumaResidue(coeffs, mask, origin, ws_stride);
    }
    for (0..2) |p| {
        const o = ws.uv[p][ws_stride + 1 ..].ptr;
        predictWhole(o, 8, mb.uv_mode, r, c);
        chromaResidue(coeffs, mask, p, o, ws_stride);
    }

    const s = f.stride[0];
    const y = f.planes[0] + r * 16 * s + c * 16;
    for (0..16) |i| @memcpy(y[i * s ..][0..16], origin[i * ws_stride ..][0..16]);
    const cs = f.stride[1];
    for (0..2) |p| {
        const dst = f.planes[1 + p] + r * 8 * cs + c * 8;
        const o = ws.uv[p][ws_stride + 1 ..].ptr;
        for (0..8) |i| @memcpy(dst[i * cs ..][0..8], o[i * ws_stride ..][0..8]);
    }
}

/// The brightness residue of a macroblock with a second-order block.
fn lumaResidue(coeffs: *tokens.Coeffs, mask: u32, dst: [*]u8, stride: usize) void {
    if (mask >> 24 & 1 != 0) {
        walsh(&coeffs[24], coeffs);
        coeffs[24] = @splat(0);
    } else if (mask & 0xFFFF == 0) return;
    for (0..16) |i| residue(coeffs, i, dst + (i >> 2) * 4 * stride + (i & 3) * 4, stride);
}

fn chromaResidue(coeffs: *tokens.Coeffs, mask: u32, p: usize, dst: [*]u8, stride: usize) void {
    for (0..4) |i| {
        const blk = 16 + p * 4 + i;
        if (mask >> @intCast(blk) & 1 != 0) residue(coeffs, blk, dst + (i >> 1) * 4 * stride + (i & 1) * 4, stride);
    }
}

// Inter prediction (18): a block of a reference frame at a vector,
// filtered between samples - six taps, or two in versions 1 to 3 - and
// beyond the frame's edges its edge samples repeated without end.

/// A reference plane.
pub const Plane = struct {
    data: [*]const u8,
    stride: usize,
    width: i32,
    height: i32,
};

/// Room for a block with what the filters reach past it.
pub const Scratch = struct {
    edge: [32 * 24]u8 = undefined,
    pass: [16 * 24]u8 = undefined,
};

inline fn tap6(s: [*]const u8, step: usize, f: *const [6]i16) u8 {
    const v = @as(i32, (s - 2 * step)[0]) * f[0] + @as(i32, (s - step)[0]) * f[1] + @as(i32, s[0]) * f[2] +
        @as(i32, s[step]) * f[3] + @as(i32, s[2 * step]) * f[4] + @as(i32, s[3 * step]) * f[5];
    return clamp255((v + 64) >> 7);
}

inline fn tap2(s: [*]const u8, step: usize, frac: u3) u8 {
    const f1: u32 = @as(u32, frac) * 16;
    return @intCast((@as(u32, s[0]) * (128 - f1) + @as(u32, s[step]) * f1 + 64) >> 7);
}

/// The `bw` x `bh` block at (`x`, `y`) of `ref`, `fx` and `fy` eighths of
/// a sample on, into `dst`.
pub fn predict(dst: [*]u8, ds: usize, ref: Plane, x: i32, y: i32, fx: u3, fy: u3, bw: u32, bh: u32, six: bool, sc: *Scratch) void {
    // What the filter reaches: two before and three after with six taps,
    // one after with two.
    const before: i32 = if (six) 2 else 0;
    const after: i32 = if (six) 3 else 1;
    const left: i32 = if (fx != 0) before else 0;
    const right: i32 = if (fx != 0) after else 0;
    const top: i32 = if (fy != 0) before else 0;
    const bottom: i32 = if (fy != 0) after else 0;
    const w: i32 = @intCast(bw);
    const h: i32 = @intCast(bh);

    var src: [*]const u8 = undefined;
    var ss: usize = undefined;
    if (x - left < 0 or y - top < 0 or x + w + right > ref.width or y + h + bottom > ref.height) {
        // Past the edge: the block and its reach copied, the edges'
        // samples standing for what is beyond.
        const ew: usize = @intCast(w + left + right);
        const eh: usize = @intCast(h + top + bottom);
        for (0..eh) |j| {
            const sy: usize = @intCast(@max(0, @min(ref.height - 1, y - top + @as(i32, @intCast(j)))));
            const row = ref.data + sy * ref.stride;
            for (0..ew) |i| {
                const sx: usize = @intCast(@max(0, @min(ref.width - 1, x - left + @as(i32, @intCast(i)))));
                sc.edge[j * 32 + i] = row[sx];
            }
        }
        src = sc.edge[@as(usize, @intCast(top)) * 32 + @as(usize, @intCast(left)) ..].ptr;
        ss = 32;
    } else {
        src = ref.data + @as(usize, @intCast(y)) * ref.stride + @as(usize, @intCast(x));
        ss = ref.stride;
    }

    if (fx == 0 and fy == 0) {
        for (0..bh) |j| @memcpy(dst[j * ds ..][0..bw], src[j * ss ..][0..bw]);
        return;
    }
    if (six) {
        const hf = &tables.sixtap[fx];
        const vf = &tables.sixtap[fy];
        if (fy == 0) {
            for (0..bh) |j| {
                for (0..bw) |i| dst[j * ds + i] = tap6(src + j * ss + i, 1, hf);
            }
        } else if (fx == 0) {
            for (0..bh) |j| {
                for (0..bw) |i| dst[j * ds + i] = tap6(src + j * ss + i, ss, vf);
            }
        } else {
            // Across first, two rows above and three below too, then down.
            const first = src - 2 * ss;
            for (0..bh + 5) |j| {
                for (0..bw) |i| sc.pass[j * 16 + i] = tap6(first + j * ss + i, 1, hf);
            }
            const mid = sc.pass[2 * 16 ..].ptr;
            for (0..bh) |j| {
                for (0..bw) |i| dst[j * ds + i] = tap6(mid + j * 16 + i, 16, vf);
            }
        }
        return;
    }
    if (fy == 0) {
        for (0..bh) |j| {
            for (0..bw) |i| dst[j * ds + i] = tap2(src + j * ss + i, 1, fx);
        }
    } else if (fx == 0) {
        for (0..bh) |j| {
            for (0..bw) |i| dst[j * ds + i] = tap2(src + j * ss + i, ss, fy);
        }
    } else {
        for (0..bh + 1) |j| {
            for (0..bw) |i| sc.pass[j * 16 + i] = tap2(src + j * ss + i, 1, fx);
        }
        for (0..bh) |j| {
            for (0..bw) |i| dst[j * ds + i] = tap2(sc.pass[j * 16 + i ..].ptr, 16, fy);
        }
    }
}

/// A colour vector of a split macroblock: the average of the four
/// brightness vectors of its 8x8 block, rounded away from zero (18.4).
fn chromaSplit(mvs: *const [16]Mv, b: usize, full_pixel: bool) Mv {
    var out: Mv = .{};
    inline for (.{ "x", "y" }) |axis| {
        const sum = @as(i32, @field(mvs[b], axis)) + @field(mvs[b + 1], axis) + @field(mvs[b + 4], axis) + @field(mvs[b + 5], axis);
        var v = @divTrunc(sum + (if (sum < 0) @as(i32, -2) else 2), 4);
        if (full_pixel) v &= ~@as(i32, 7);
        @field(out, axis) = @truncate(v);
    }
    return out;
}

/// An inter macroblock (`r`, `c`) predicted from `ref` into frame `f`,
/// its residue added.
pub fn inter(mb: *const MbInfo, coeffs: *tokens.Coeffs, mask: u32, f: *Frame, ref: *const Frame, r: u32, c: u32, version: u3, sc: *Scratch) void {
    const six = version == 0;
    const full_pixel = version == 3;
    const s = f.stride[0];
    const cs = f.stride[1];
    const x0: i32 = @intCast(c * 16);
    const y0: i32 = @intCast(r * 16);
    const y = f.planes[0] + r * 16 * s + c * 16;
    const luma: Plane = .{ .data = ref.planes[0], .stride = ref.stride[0], .width = @intCast(ref.width[0]), .height = @intCast(ref.height[0]) };
    var chroma: [2]Plane = undefined;
    for (&chroma, 0..) |*p, i| p.* = .{ .data = ref.planes[1 + i], .stride = ref.stride[1 + i], .width = @intCast(ref.width[1]), .height = @intCast(ref.height[1]) };

    if (mb.y_mode != common.SPLITMV) {
        const v = mb.mv;
        predict(y, s, luma, x0 + (v.x >> 2), y0 + (v.y >> 2), @intCast((v.x & 3) * 2), @intCast((v.y & 3) * 2), 16, 16, six, sc);
        // The brightness's quarters are the colour's eighths.
        var cv = v;
        if (full_pixel) {
            cv.x &= ~@as(i16, 7);
            cv.y &= ~@as(i16, 7);
        }
        for (0..2) |p| {
            const dst = f.planes[1 + p] + r * 8 * cs + c * 8;
            predict(dst, cs, chroma[p], @divExact(x0, 2) + (cv.x >> 3), @divExact(y0, 2) + (cv.y >> 3), @intCast(cv.x & 7), @intCast(cv.y & 7), 8, 8, six, sc);
        }
        lumaResidue(coeffs, mask, y, s);
    } else {
        for (0..16) |b| {
            const v = mb.mvs[b];
            const bx: i32 = @intCast((b & 3) * 4);
            const by: i32 = @intCast((b >> 2) * 4);
            predict(y + (b >> 2) * 4 * s + (b & 3) * 4, s, luma, x0 + bx + (v.x >> 2), y0 + by + (v.y >> 2), @intCast((v.x & 3) * 2), @intCast((v.y & 3) * 2), 4, 4, six, sc);
        }
        for (0..4) |i| {
            const b = (i >> 1) * 8 + (i & 1) * 2;
            const cv = chromaSplit(&mb.mvs, b, full_pixel);
            const bx: i32 = @intCast((i & 1) * 4);
            const by: i32 = @intCast((i >> 1) * 4);
            for (0..2) |p| {
                const dst = f.planes[1 + p] + (r * 8 + (i >> 1) * 4) * cs + c * 8 + (i & 1) * 4;
                predict(dst, cs, chroma[p], @divExact(x0, 2) + bx + (cv.x >> 3), @divExact(y0, 2) + by + (cv.y >> 3), @intCast(cv.x & 7), @intCast(cv.y & 7), 4, 4, six, sc);
            }
        }
        for (0..16) |b| {
            if (mask >> @intCast(b) & 1 != 0) residue(coeffs, b, y + (b >> 2) * 4 * s + (b & 3) * 4, s);
        }
    }
    for (0..2) |p| chromaResidue(coeffs, mask, p, f.planes[1 + p] + r * 8 * cs + c * 8, cs);
}

// SPDX-License-Identifier: MIT
//! The reconstruction (8.5, 8.6): each block predicted, from the frame
//! itself or from its references, and its residual added. Samples are u8
//! for 8 bits and u16 above; the code is the same for both.

const common = @import("common.zig");
const tables = @import("tables.zig");
const parse = @import("parse.zig");
const idct = @import("idct.zig");
const Block = common.Block;
const Frame = common.Frame;
const Mv = common.Mv;

/// A reference as a frame predicts from it: the frame and how much
/// bigger it is, in 1/16384ths (8.5.2.3).
pub const Ref = struct {
    frame: *const Frame = undefined,
    x_scale: i64 = 1 << 14,
    y_scale: i64 = 1 << 14,
    step_x: i32 = 16,
    step_y: i32 = 16,
    scaled: bool = false,

    pub fn init(f: *const Frame, width: u32, height: u32) Ref {
        var r: Ref = .{ .frame = f };
        r.x_scale = @divTrunc(@as(i64, f.width) << 14, width);
        r.y_scale = @divTrunc(@as(i64, f.height) << 14, height);
        r.step_x = @intCast((16 * r.x_scale) >> 14);
        r.step_y = @intCast((16 * r.y_scale) >> 14);
        r.scaled = r.x_scale != 1 << 14 or r.y_scale != 1 << 14;
        return r;
    }
};

/// The working memory of one reconstruction: a transform block's
/// coefficients, kept zero between blocks, and the motion compensation's.
pub const Scratch = struct {
    coef: [1024]i32 align(16) = @splat(0),
    /// A reference region with its edges copied out, and the
    /// horizontally filtered rows.
    edge: [136 * 136]u16 = undefined,
    mid: [136 * 64]u16 = undefined,
    pred: [64 * 64]u16 = undefined,
};

pub const Recon = struct {
    frame: *Frame,
    out: *const parse.Out,
    /// By reference, LAST_FRAME to ALTREF_FRAME; 0 unused.
    refs: [4]Ref = @splat(.{}),
    lossless: bool = false,

    /// Superblock row `row` reconstructed.
    pub fn sbRow(rc: *const Recon, comptime P: type, row: u32, s: *Scratch) void {
        const sb_cols = (rc.out.mi_cols + 7) >> 3;
        for (0..sb_cols) |c| {
            const i = row * sb_cols + c;
            const first = rc.out.sb_first[i];
            for (rc.out.blocks[first .. first + rc.out.sb_count[i]]) |*b| rc.block(P, b, s);
        }
    }

    fn block(rc: *const Recon, comptime P: type, b: *const Block, s: *Scratch) void {
        const out = rc.out;
        const f = rc.frame;
        const bsize = @max(b.size, common.BLOCK_8X8);
        const max: i32 = (@as(i32, 1) << @intCast(f.bit_depth)) - 1;
        var ci: usize = b.coeffs;
        if (b.is_inter) {
            for (0..3) |plane| rc.inter(P, b, plane, s);
        }
        for (0..3) |plane| {
            const sx: u5 = if (plane > 0) f.ss_x else 0;
            const sy: u5 = if (plane > 0) f.ss_y else 0;
            const tx: u8 = if (plane == 0) b.tx_size else parse.Parse.uvTxSize(b, f.ss_x, f.ss_y);
            const step = @as(u32, 1) << @intCast(tx);
            const plane_size = tables.ss_size_lookup[bsize][sx][sy];
            const w4: u32 = tables.num_4x4_wide[plane_size];
            const h4: u32 = tables.num_4x4_high[plane_size];
            const base_x = (@as(u32, b.col) * 8) >> sx;
            const base_y = (@as(u32, b.row) * 8) >> sy;
            const max_x = (out.mi_cols * 8) >> sx;
            const max_y = (out.mi_rows * 8) >> sy;
            if (b.is_inter and !b.coded) continue;
            const stride = f.stride[plane];
            const pl = f.plane(P, plane);
            const mode = if (plane > 0) b.uv_mode else b.y_mode;
            var k: usize = 0;
            var y: u32 = 0;
            while (y < h4) : (y += step) {
                var x: u32 = 0;
                while (x < w4) : (x += step) {
                    defer k += 1;
                    const px = base_x + 4 * x;
                    const py = base_y + 4 * y;
                    if (px >= max_x or py >= max_y) continue;
                    const dst = pl + py * stride + px;
                    if (!b.is_inter) {
                        const m = if (plane == 0 and b.size < common.BLOCK_8X8) b.sub_modes[k] else mode;
                        intra(P, dst, stride, m, tx, .{
                            .left = x > 0 or b.avail_l,
                            .above = y > 0 or b.row > 0,
                            .right = x + step < w4,
                            .max_x = max_x - 1 - px,
                            .max_y = max_y - 1 - py,
                        }, f.bit_depth);
                    }
                    if (!b.coded) continue;
                    const eob: u32 = @intCast(out.coef[ci]);
                    ci += 1;
                    if (eob == 0) continue;
                    const tx_type = parse.Parse.txType(b, plane, tx, k, rc.lossless);
                    const scan = parse.scanOf(tx, tx_type);
                    var rows: u32 = 0;
                    const shift: u5 = @intCast(tx + 2);
                    for (out.coef[ci .. ci + eob], scan[0..eob]) |v, pos| {
                        s.coef[pos] = v;
                        rows |= @as(u32, 1) << @intCast(@as(u32, pos) >> shift);
                    }
                    ci += eob;
                    switch (tx) {
                        0 => idct.add(P, 2, dst, stride, s.coef[0..16], rows, tx_type, rc.lossless, eob, max),
                        1 => idct.add(P, 3, dst, stride, s.coef[0..64], rows, tx_type, false, eob, max),
                        2 => idct.add(P, 4, dst, stride, s.coef[0..256], rows, tx_type, false, eob, max),
                        else => idct.add(P, 5, dst, stride, s.coef[0..1024], rows, tx_type, false, eob, max),
                    }
                }
            }
        }
    }

    /// The inter prediction of a block's plane (8.5.2).
    fn inter(rc: *const Recon, comptime P: type, b: *const Block, plane: usize, s: *Scratch) void {
        const f = rc.frame;
        const out = rc.out;
        const sx: u5 = if (plane > 0) f.ss_x else 0;
        const sy: u5 = if (plane > 0) f.ss_y else 0;
        const bsize = @max(b.size, common.BLOCK_8X8);
        const plane_size = tables.ss_size_lookup[bsize][sx][sy];
        const w4: u32 = tables.num_4x4_wide[plane_size];
        const h4: u32 = tables.num_4x4_high[plane_size];
        const base_x = (@as(u32, b.col) * 8) >> sx;
        const base_y = (@as(u32, b.row) * 8) >> sy;
        const max_x = (out.mi_cols * 8) >> sx;
        const max_y = (out.mi_rows * 8) >> sy;
        const compound = b.ref_frame[1] > common.INTRA_FRAME;
        if (b.size < common.BLOCK_8X8) {
            for (0..h4) |y| {
                for (0..w4) |x| {
                    const px = base_x + 4 * @as(u32, @intCast(x));
                    const py = base_y + 4 * @as(u32, @intCast(y));
                    if (px >= max_x or py >= max_y) continue;
                    const k = y * w4 + x;
                    for (0..@as(usize, if (compound) 2 else 1)) |j| {
                        const mv = subMv(b, j, k, plane, f.ss_x, f.ss_y);
                        rc.predict(P, b, plane, j, px, py, 4, 4, mv, s);
                    }
                }
            }
        } else {
            const w = @min(w4 * 4, max_x - base_x);
            const h = @min(h4 * 4, max_y - base_y);
            for (0..@as(usize, if (compound) 2 else 1)) |j| rc.predict(P, b, plane, j, base_x, base_y, w, h, b.mvs[j][0], s);
        }
    }

    /// The chroma vector of a 4x4 of a block under 8x8: the average of
    /// the brightness 4x4s it covers (8.5.2.1).
    fn subMv(b: *const Block, j: usize, k: usize, plane: usize, ss_x: u1, ss_y: u1) Mv {
        const m = &b.mvs[j];
        if (plane == 0 or (ss_x == 0 and ss_y == 0)) return m[k];
        if (ss_x == 0) return .{ .row = q2(m[k].row, m[k + 2].row), .col = q2(m[k].col, m[k + 2].col) };
        if (ss_y == 0) return .{ .row = q2(m[k].row, m[k + 1].row), .col = q2(m[k].col, m[k + 1].col) };
        return .{
            .row = q4(@as(i32, m[0].row) + m[1].row + m[2].row + m[3].row),
            .col = q4(@as(i32, m[0].col) + m[1].col + m[2].col + m[3].col),
        };
    }

    fn q2(a: i16, b: i16) i16 {
        const v: i32 = @as(i32, a) + b;
        return @intCast(@divTrunc(if (v < 0) v - 1 else v + 1, 2));
    }

    fn q4(v: i32) i16 {
        return @intCast(@divTrunc(if (v < 0) v - 2 else v + 2, 4));
    }

    /// One reference's prediction of a `w` x `h` region at `px`, `py` of
    /// a plane, averaged into what the first left when it is the second.
    fn predict(rc: *const Recon, comptime P: type, b: *const Block, plane: usize, j: usize, px: u32, py: u32, w: u32, h: u32, mv: Mv, s: *Scratch) void {
        const f = rc.frame;
        const out = rc.out;
        const ref = &rc.refs[@intCast(b.ref_frame[j])];
        const rf = ref.frame;
        const sx: u5 = if (plane > 0) f.ss_x else 0;
        const sy: u5 = if (plane > 0) f.ss_y else 0;

        // The vector clamped (8.5.2.2), in 1/16 samples of the plane.
        const bh: i32 = tables.num_8x8_high[b.size];
        const bw: i32 = tables.num_8x8_wide[b.size];
        const row: i32 = b.row;
        const col: i32 = b.col;
        const to_top = -((row * 8) * 16) >> sy;
        const to_bottom = (((@as(i32, @intCast(out.mi_rows)) - bh - row) * 8) * 16) >> sy;
        const to_left = -((col * 8) * 16) >> sx;
        const to_right = (((@as(i32, @intCast(out.mi_cols)) - bw - col) * 8) * 16) >> sx;
        const spel_left = (4 + ((bw * 8) >> sx)) << 4;
        const spel_top = (4 + ((bh * 8) >> sy)) << 4;
        const mv_row = clamp((2 * @as(i32, mv.row)) >> sy, to_top - spel_top, to_bottom + spel_top - 16);
        const mv_col = clamp((2 * @as(i32, mv.col)) >> sx, to_left - spel_left, to_right + spel_left - 16);

        // Where in the reference (8.5.2.3).
        var x16: i64 = undefined;
        var y16: i64 = undefined;
        if (ref.scaled) {
            const base_x = (@as(i64, px) * ref.x_scale) >> 14;
            const base_y = (@as(i64, py) * ref.y_scale) >> 14;
            const luma_x: i64 = @as(i64, px) << sx;
            const luma_y: i64 = @as(i64, py) << sy;
            const frac_x = ((16 * luma_x * ref.x_scale) >> 14) & 15;
            const frac_y = ((16 * luma_y * ref.y_scale) >> 14) & 15;
            x16 = (base_x << 4) + ((mv_col * ref.x_scale) >> 14) + frac_x;
            y16 = (base_y << 4) + ((mv_row * ref.y_scale) >> 14) + frac_y;
        } else {
            x16 = (@as(i64, px) << 4) + mv_col;
            y16 = (@as(i64, py) << 4) + mv_row;
        }
        const last_x: i32 = @intCast(((rf.width + (@as(u32, 1) << sx) - 1) >> sx) - 1);
        const last_y: i32 = @intCast(((rf.height + (@as(u32, 1) << sy) - 1) >> sy) - 1);
        const stride = f.stride[plane];
        const dst = f.plane(P, plane) + py * stride + px;
        const max: i32 = (@as(i32, 1) << @intCast(f.bit_depth)) - 1;
        mc(P, s, dst, stride, rf.plane(P, plane), rf.stride[plane], last_x, last_y, @intCast(x16), @intCast(y16), ref.step_x, ref.step_y, w, h, &tables.subpel_filters[b.interp_filter], max, j == 1);
    }
};

fn clamp(v: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(hi, v));
}

/// A block predicted from `ref` at `x16`, `y16` in 1/16 samples, stepping
/// `xs`, `ys` (8.5.2.4); averaged into `dst` when `avg`.
fn mc(comptime P: type, s: *Scratch, dst: [*]P, dst_stride: usize, ref: [*]const P, ref_stride: usize, last_x: i32, last_y: i32, x16: i32, y16: i32, xs: i32, ys: i32, w: u32, h: u32, kernel: *const [16][8]i16, max: i32, avg: bool) void {
    const iw: i32 = @intCast(w);
    const ih: i32 = @intCast(h);
    // The region the filters read.
    const x0 = (x16 >> 4) - 3;
    const y0 = (y16 >> 4) - 3;
    const x1 = ((x16 + xs * (iw - 1)) >> 4) + 4;
    const y1 = ((y16 + ys * (ih - 1)) >> 4) + 4;
    var src: [*]const P = undefined;
    var sstride: usize = undefined;
    if (x0 >= 0 and y0 >= 0 and x1 <= last_x and y1 <= last_y) {
        src = ref + @as(usize, @intCast(y0)) * ref_stride + @as(usize, @intCast(x0));
        sstride = ref_stride;
    } else {
        // Its samples out of the frame are the nearest edge's.
        const ew: usize = @intCast(x1 - x0 + 1);
        const eh: usize = @intCast(y1 - y0 + 1);
        const e: [*]P = @ptrCast(&s.edge);
        for (0..eh) |r| {
            const ry: usize = @intCast(clamp(y0 + @as(i32, @intCast(r)), 0, last_y));
            const line = ref + ry * ref_stride;
            for (0..ew) |c| e[r * ew + c] = line[@intCast(clamp(x0 + @as(i32, @intCast(c)), 0, last_x))];
        }
        src = e;
        sstride = ew;
    }
    const fx: usize = @intCast(x16 & 15);
    const fy: usize = @intCast(y16 & 15);
    const out: [*]P = if (avg) @ptrCast(&s.pred) else dst;
    const out_stride: usize = if (avg) w else dst_stride;
    // Rows of the intermediate the vertical filter reads.
    const mid_rows: usize = @intCast((((ih - 1) * ys + @as(i32, @intCast(fy))) >> 4) + 8);
    const mid: [*]u16 = &s.mid;
    if (xs == 16 and ys == 16) {
        if (fx == 0 and fy == 0) {
            for (0..h) |r| {
                const sp = src + (r + 3) * sstride + 3;
                for (0..w) |c| out[r * out_stride + c] = sp[c];
            }
        } else if (fy == 0) {
            const k = &kernel[fx];
            for (0..h) |r| {
                const sp = src + (r + 3) * sstride;
                for (0..w) |c| out[r * out_stride + c] = @intCast(tap(P, sp + c, 1, k, max));
            }
        } else if (fx == 0) {
            const k = &kernel[fy];
            for (0..h) |r| {
                const sp = src + r * sstride + 3;
                for (0..w) |c| out[r * out_stride + c] = @intCast(tap(P, sp + c, sstride, k, max));
            }
        } else {
            const kx = &kernel[fx];
            const ky = &kernel[fy];
            for (0..h + 7) |r| {
                const sp = src + r * sstride;
                for (0..w) |c| mid[r * w + c] = @intCast(tap(P, sp + c, 1, kx, max));
            }
            for (0..h) |r| {
                for (0..w) |c| out[r * out_stride + c] = @intCast(tap(u16, mid + r * w + c, w, ky, max));
            }
        }
    } else {
        // Scaled: each sample at its own phase.
        for (0..mid_rows) |r| {
            const sp = src + r * sstride;
            var p: usize = fx;
            for (0..w) |c| {
                mid[r * w + c] = @intCast(tap(P, sp + (p >> 4), 1, &kernel[p & 15], max));
                p += @intCast(xs);
            }
        }
        var p: usize = fy;
        for (0..h) |r| {
            const k = &kernel[p & 15];
            const mp = mid + (p >> 4) * w;
            for (0..w) |c| out[r * out_stride + c] = @intCast(tap(u16, mp + c, w, k, max));
            p += @intCast(ys);
        }
    }
    if (avg) {
        for (0..h) |r| {
            for (0..w) |c| {
                const d = &dst[r * dst_stride + c];
                d.* = @intCast((@as(u32, d.*) + out[r * out_stride + c] + 1) >> 1);
            }
        }
    }
}

inline fn tap(comptime P: type, p: [*]const P, step: usize, k: *const [8]i16, max: i32) i32 {
    var sum: i32 = 0;
    inline for (0..8) |t| sum += @as(i32, p[t * step]) * k[t];
    return @max(0, @min(max, (sum + 64) >> 7));
}

/// What an intra prediction may read around its block (8.5.1): whether
/// there is a left and an above, whether the above right belongs to the
/// block, and how far right and down the frame's samples go.
pub const Edges = struct {
    left: bool,
    above: bool,
    right: bool,
    max_x: u32,
    max_y: u32,
};

fn avg2(a: i32, b: i32) i32 {
    return (a + b + 1) >> 1;
}

fn avg3(a: i32, b: i32, c: i32) i32 {
    return (a + 2 * b + c + 2) >> 2;
}

/// The intra prediction of a transform block at `dst` (8.5.1).
pub fn intra(comptime P: type, dst: [*]P, stride: usize, mode: u8, tx: u8, e: Edges, bit_depth: u8) void {
    const log2: u5 = @intCast(tx + 2);
    const size: usize = @as(usize, 1) << log2;
    const base: i32 = @as(i32, 1) << @intCast(bit_depth - 1);
    const max: i32 = (base << 1) - 1;
    // above[0] is the above left, above[1 + i] aboveRow[i].
    var above: [65]i32 = undefined;
    var left: [32]i32 = undefined;
    if (e.above) {
        const row = dst - stride;
        for (0..size) |i| above[1 + i] = row[@min(e.max_x, i)];
        if (e.right and tx == 0) {
            for (size..2 * size) |i| above[1 + i] = row[@min(e.max_x, i)];
        } else {
            for (size..2 * size) |i| above[1 + i] = above[size];
        }
        above[0] = if (e.left) (dst - stride - 1)[0] else base + 1;
    } else {
        for (1..2 * size + 1) |i| above[i] = base - 1;
        above[0] = base - 1;
    }
    if (e.left) {
        for (0..size) |i| left[i] = (dst + @min(e.max_y, i) * stride - 1)[0];
    } else {
        for (0..size) |i| left[i] = base + 1;
    }
    const a = above[1..];
    const tl = above[0];
    switch (mode) {
        common.V_PRED => {
            for (0..size) |i| {
                for (0..size) |j| dst[i * stride + j] = @intCast(a[j]);
            }
        },
        common.H_PRED => {
            for (0..size) |i| {
                for (0..size) |j| dst[i * stride + j] = @intCast(left[i]);
            }
        },
        common.D207_PRED => {
            var pred: [32][32]i32 = undefined;
            for (0..size) |j| pred[size - 1][j] = left[size - 1];
            for (0..size - 1) |i| pred[i][0] = avg2(left[i], left[i + 1]);
            if (size >= 3) {
                for (0..size - 2) |i| pred[i][1] = avg3(left[i], left[i + 1], left[i + 2]);
            }
            pred[size - 2][1] = (left[size - 2] + 3 * left[size - 1] + 2) >> 2;
            var i: usize = size - 1;
            while (i > 0) {
                i -= 1;
                for (2..size) |j| pred[i][j] = pred[i + 1][j - 2];
            }
            store(P, dst, stride, size, &pred);
        },
        common.D45_PRED => {
            for (0..size) |i| {
                for (0..size) |j| {
                    const v = if (i + j + 2 < size * 2) avg3(a[i + j], a[i + j + 1], a[i + j + 2]) else a[2 * size - 1];
                    dst[i * stride + j] = @intCast(v);
                }
            }
        },
        common.D63_PRED => {
            for (0..size) |i| {
                for (0..size) |j| {
                    const h2 = i / 2;
                    const v = if (i & 1 != 0) avg3(a[h2 + j], a[h2 + j + 1], a[h2 + j + 2]) else avg2(a[h2 + j], a[h2 + j + 1]);
                    dst[i * stride + j] = @intCast(v);
                }
            }
        },
        common.D117_PRED => {
            var pred: [32][32]i32 = undefined;
            for (0..size) |j| pred[0][j] = avg2(above[j], a[j]);
            pred[1][0] = avg3(left[0], tl, a[0]);
            for (1..size) |j| pred[1][j] = avg3(above[j - 1], above[j], a[j]);
            pred[2][0] = avg3(tl, left[0], left[1]);
            for (3..size) |i| pred[i][0] = avg3(left[i - 3], left[i - 2], left[i - 1]);
            for (2..size) |i| {
                for (1..size) |j| pred[i][j] = pred[i - 2][j - 1];
            }
            store(P, dst, stride, size, &pred);
        },
        common.D135_PRED => {
            var pred: [32][32]i32 = undefined;
            pred[0][0] = avg3(left[0], tl, a[0]);
            for (1..size) |j| pred[0][j] = avg3(above[j - 1], above[j], a[j]);
            pred[1][0] = avg3(tl, left[0], left[1]);
            for (2..size) |i| pred[i][0] = avg3(left[i - 2], left[i - 1], left[i]);
            for (1..size) |i| {
                for (1..size) |j| pred[i][j] = pred[i - 1][j - 1];
            }
            store(P, dst, stride, size, &pred);
        },
        common.D153_PRED => {
            var pred: [32][32]i32 = undefined;
            pred[0][0] = avg2(left[0], tl);
            for (1..size) |i| pred[i][0] = avg2(left[i - 1], left[i]);
            pred[0][1] = avg3(left[0], tl, a[0]);
            pred[1][1] = avg3(tl, left[0], left[1]);
            for (2..size) |i| pred[i][1] = avg3(left[i - 2], left[i - 1], left[i]);
            for (2..size) |j| pred[0][j] = avg3(above[j - 2], above[j - 1], above[j]);
            for (1..size) |i| {
                for (2..size) |j| pred[i][j] = pred[i - 1][j - 2];
            }
            store(P, dst, stride, size, &pred);
        },
        common.TM_PRED => {
            for (0..size) |i| {
                for (0..size) |j| dst[i * stride + j] = @intCast(@max(0, @min(max, a[j] + left[i] - tl)));
            }
        },
        else => {
            var sum: i32 = 0;
            var v: i32 = base;
            if (e.left and e.above) {
                for (0..size) |k| sum += left[k] + a[k];
                v = (sum + @as(i32, @intCast(size))) >> (log2 + 1);
            } else if (e.left) {
                for (0..size) |k| sum += left[k];
                v = (sum + (@as(i32, 1) << (log2 - 1))) >> log2;
            } else if (e.above) {
                for (0..size) |k| sum += a[k];
                v = (sum + (@as(i32, 1) << (log2 - 1))) >> log2;
            }
            for (0..size) |i| {
                for (0..size) |j| dst[i * stride + j] = @intCast(v);
            }
        },
    }
}

fn store(comptime P: type, dst: [*]P, stride: usize, size: usize, pred: *const [32][32]i32) void {
    for (0..size) |i| {
        for (0..size) |j| dst[i * stride + j] = @intCast(pred[i][j]);
    }
}

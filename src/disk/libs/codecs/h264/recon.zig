// SPDX-License-Identifier: MIT
//! A macroblock's samples: its prediction - intra from the samples
//! around it as they were decoded, before any filtering, or inter from
//! its reference pictures - and its residual added (8.3 to 8.5).

const common = @import("common.zig");
const Store = common.Store;
const RefPic = common.RefPic;
const mbm = @import("mb.zig");
const Dec = mbm.Dec;
const Mb = mbm.Mb;
const mvpred = @import("mvpred.zig");
const intra = @import("intra.zig");
const inter = @import("inter.zig");
const transform = @import("transform.zig");
const slice_mod = @import("slice.zig");

/// What inter prediction works in, the decoder's: the blocks of each list
/// and plane before they are weighted together, and the filters' work.
pub const Scratch = struct {
    pred: [2][3][16 * 16]u16 = undefined,
    inter: inter.Work = .{},
};

/// What a slice's macroblocks are put together with.
pub const Rc = struct {
    store: *Store,
    scratch: *Scratch,
    mv: *const mvpred.Ctx,
    hdr: *const slice_mod.Header,
    depth_y: u5,
    depth_c: u5,
    /// The weighting: explicit (the slice's tables), implicit (B), or none.
    weighting: enum { none, explicit, implicit } = .none,
    /// With separate colour planes, the plane the slice codes: its samples
    /// and its references' are that plane's.
    colour: u2 = 0,
    /// A picture decoded on a worker: how it waits for its references'
    /// rows.
    sync: ?*const common.Sync = null,
};

/// Where the current macroblock's samples of a plane are.
const Place = struct {
    /// Index of its top left sample, and the distance between its rows.
    origin: usize,
    row: usize,
    stride: usize,
    /// Its first row in the frame, and the step from row to row (2 for a
    /// field macroblock).
    y0: i32,
    step: i32,
    x0: i32,
};

fn place(d: *const Dec, s: *const Store, p: usize, mbw: u32, mbh: u32) Place {
    const stride = s.stride[p];
    const x0: i32 = @intCast(d.mb_x * mbw);
    var y0: i32 = undefined;
    var step: i32 = 1;
    if (d.field) {
        y0 = @intCast(mbh * (d.mb_y & ~@as(u32, 1)) + (d.mb_y & 1));
        step = 2;
    } else y0 = @intCast(mbh * d.mb_y);
    return .{
        .origin = @as(usize, @intCast(y0)) * stride + @as(usize, @intCast(x0)),
        .row = stride * @as(usize, @intCast(step)),
        .stride = stride,
        .y0 = y0,
        .step = step,
        .x0 = x0,
    };
}

/// Whether the samples of a neighbouring macroblock may be used for
/// intra prediction (8.3.1.2): there, and not inter when the picture
/// says constrained_intra_pred.
fn usable(d: *const Dec, m: *const Mb, xy: ?u32) bool {
    const n = d.info(xy orelse return false);
    if (!d.pps.constrained_intra_pred) return true;
    if (n.flags & common.F_INTRA == 0) return false;
    if (n.kind == .si and m.kind != .si) return false;
    return true;
}

/// Which of the samples around the macroblock are there, for a plane
/// whose macroblocks are `mbh` high.
const Avail = struct {
    top: bool = false,
    topright: bool = false,
    corner: bool = false,
    left: [16]bool = @splat(false),

    fn of(d: *const Dec, m: *const Mb, mbh: u32) Avail {
        var a: Avail = .{};
        a.top = usable(d, m, if (d.owner(0, -1, mbh)) |o| o.xy else null);
        a.topright = usable(d, m, if (d.owner(1, -1, mbh)) |o| o.xy else null);
        a.corner = usable(d, m, if (d.owner(-1, -1, mbh)) |o| o.xy else null);
        if (!d.mbaff) {
            const l = usable(d, m, if (d.owner(-1, 0, mbh)) |o| o.xy else null);
            a.left = @splat(l);
        } else {
            for (0..mbh) |y| a.left[y] = usable(d, m, if (d.owner(-1, @intCast(y), mbh)) |o| o.xy else null);
        }
        return a;
    }

    fn allLeft(a: *const Avail, y: usize, n: usize) bool {
        for (y..y + n) |k| {
            if (!a.left[k]) return false;
        }
        return true;
    }
};

pub fn Recon(comptime P: type) type {
    return struct {
        const Self = @This();

        fn planeOf(rc: *const Rc, s: *const Store, p: usize) [*]P {
            return @ptrCast(@alignCast(s.planes[p + rc.colour]));
        }

        /// Sample at row `y` (of the macroblock, -1 above) and column `x`
        /// (-1 left) of a plane.
        inline fn at(base: [*]P, pl: *const Place, x: i32, y: i32) i32 {
            const fy = pl.y0 + pl.step * y;
            const idx = @as(usize, @intCast(fy)) * pl.stride + @as(usize, @intCast(pl.x0 + x));
            return base[idx];
        }

        inline fn ptr(base: [*]P, pl: *const Place, x: u32, y: u32) [*]P {
            return base + pl.origin + @as(usize, y) * pl.row + x;
        }

        /// The whole macroblock.
        pub fn mb(rc: *const Rc, d: *const Dec, m: *const Mb, mv: *const mvpred.Out) void {
            if (m.kind == .ipcm) return pcm(rc, d, m);
            if (m.kind == .inter) {
                predictInter(rc, d, mv);
                if (rc.hdr.kind == .sp) return spInter(rc, d, m);
                for (0..planeCount(d)) |p| addResidualPlane(rc, d, m, p);
                if (d.cat == 1 or d.cat == 2) addResidualChroma(rc, d, m);
                return;
            }
            for (0..planeCount(d)) |p| intraPlane(rc, d, m, p);
            if (d.cat == 1 or d.cat == 2) intraChroma(rc, d, m);
        }

        /// The planes coded as luma: 1, or 3 with 4:4:4.
        fn planeCount(d: *const Dec) usize {
            return if (d.cat == 3) 3 else 1;
        }

        fn depthOf(rc: *const Rc, p: usize) u5 {
            return if (p == 0) rc.depth_y else rc.depth_c;
        }

        fn pcm(rc: *const Rc, d: *const Dec, m: *const Mb) void {
            const s = rc.store;
            const pl = place(d, s, 0, 16, 16);
            const base = planeOf(rc, s, 0);
            for (0..16) |y| {
                const row = ptr(base, &pl, 0, @intCast(y));
                for (0..16) |x| row[x] = @intCast(m.pcm[y * 16 + x]);
            }
            if (d.mbh_c == 0) return;
            const mbw: u32 = if (d.cat == 3) 16 else 8;
            var k: usize = 256;
            for (1..3) |p| {
                const pc = place(d, s, p, mbw, d.mbh_c);
                const bc = planeOf(rc, s, p);
                for (0..d.mbh_c) |y| {
                    const row = ptr(bc, &pc, 0, @intCast(y));
                    for (0..mbw) |x| {
                        row[x] = @intCast(m.pcm[k]);
                        k += 1;
                    }
                }
            }
        }

        // --- intra ---------------------------------------------------------

        fn intraPlane(rc: *const Rc, d: *const Dec, m: *const Mb, p: usize) void {
            const s = rc.store;
            const pl = place(d, s, p, 16, 16);
            const base = planeOf(rc, s, p);
            const av = Avail.of(d, m, 16);
            const depth = depthOf(rc, p);
            const max: i32 = (@as(i32, 1) << depth) - 1;
            switch (m.kind) {
                .i4x4, .si => {
                    for (0..16) |k| {
                        const r: u32 = common.blk_raster[k];
                        const bx = r & 3;
                        const by = r >> 2;
                        var e: intra.Edge(P, 4) = .{};
                        gather(4, base, &pl, &av, bx * 4, by * 4, topRight4(&av, bx, by), &e);
                        const dst = ptr(base, &pl, bx * 4, by * 4);
                        const mode = m.i_modes[r];
                        intra.predictNxN(P, 4, dst, pl.row, mode, &e, depth);
                        if (m.kind == .si) {
                            spBlock(rc, d, m, dst, pl.row, p, r, max);
                        } else if (m.mask4[p] >> @intCast(r) & 1 != 0) {
                            if (m.lossless) {
                                transform.bypassAdd(P, dst, pl.row, &m.coef[p][r], 4, dpcmOf(mode), max);
                            } else transform.idct4Add(P, dst, pl.row, &m.coef[p][r], max);
                        }
                    }
                },
                .i8x8 => {
                    for (0..4) |b8| {
                        const bx: u32 = @intCast((b8 & 1) * 8);
                        const by: u32 = @intCast((b8 >> 1) * 8);
                        var e: intra.Edge(P, 8) = .{};
                        const tr = switch (b8) {
                            0 => av.top,
                            1 => av.topright,
                            2 => true,
                            else => false,
                        };
                        gather(8, base, &pl, &av, bx, by, tr, &e);
                        intra.filter8x8(P, &e);
                        const dst = ptr(base, &pl, bx, by);
                        const mode = m.i_modes[(by / 4) * 4 + bx / 4];
                        intra.predictNxN(P, 8, dst, pl.row, mode, &e, depth);
                        if (m.mask8[p] >> @intCast(b8) & 1 != 0) {
                            if (m.lossless) {
                                transform.bypassAdd(P, dst, pl.row, &m.coef8[p][b8], 8, dpcmOf(mode), max);
                            } else transform.idct8Add(P, dst, pl.row, &m.coef8[p][b8], max);
                        }
                    }
                },
                .i16x16 => {
                    var e: intra.Edge(P, 16) = .{};
                    gather(16, base, &pl, &av, 0, 0, false, &e);
                    const dst = ptr(base, &pl, 0, 0);
                    intra.predictBlock(P, 16, 16, dst, pl.row, m.i16_mode, &e, false, 1, depth);
                    if (m.lossless and m.i16_mode < 2) {
                        losslessWhole(dst, pl.row, m, p, 4, 4, dpcmOf(m.i16_mode), max);
                    } else addBlocks4(dst, pl.row, m, p, 4, 4, max);
                },
                else => {},
            }
        }

        /// A lossless block's residual after a vertical (0) or horizontal
        /// (1) prediction is coded as differences (8.5.15).
        fn dpcmOf(mode: u8) transform.Dpcm {
            return switch (mode) {
                0 => .vertical,
                1 => .horizontal,
                else => .none,
            };
        }

        /// Whether the samples above right of 4x4 block (bx, by) are
        /// there: decoded before it (6.4.11.4).
        fn topRight4(av: *const Avail, bx: u32, by: u32) bool {
            if (by == 0) return if (bx < 3) av.top else av.topright;
            if (bx == 3) return false;
            // blk_raster is its own inverse: raster index to block index.
            const blk = common.blk_raster[by * 4 + bx];
            const tr = common.blk_raster[(by - 1) * 4 + bx + 1];
            return tr < blk;
        }

        /// The samples around an n x n block at (bx, by) of the plane.
        fn gather(comptime n: usize, base: [*]P, pl: *const Place, av: *const Avail, bx: u32, by: u32, topright: bool, e: anytype) void {
            const x: i32 = @intCast(bx);
            const y: i32 = @intCast(by);
            e.has_top = by > 0 or av.top;
            e.has_left = bx > 0 or av.allLeft(by, n);
            e.has_corner = if (bx > 0 and by > 0) true else if (by == 0 and bx > 0) av.top else if (bx == 0 and by > 0) av.left[by - 1] else av.corner;
            e.has_topright = e.has_top and topright;
            if (e.has_top) {
                for (0..n) |i| e.top[i] = at(base, pl, x + @as(i32, @intCast(i)), y - 1);
                if (e.has_topright) {
                    for (n..2 * n) |i| e.top[i] = at(base, pl, x + @as(i32, @intCast(i)), y - 1);
                } else {
                    for (n..2 * n) |i| e.top[i] = e.top[n - 1];
                }
            }
            if (e.has_left) {
                for (0..n) |i| e.left[i] = at(base, pl, x - 1, y + @as(i32, @intCast(i)));
            }
            if (e.has_corner) e.corner = at(base, pl, x - 1, y - 1);
        }

        fn addBlocks4(dst: [*]P, stride: usize, m: *const Mb, p: usize, bw: u32, bh: u32, max: i32) void {
            for (0..bh) |by| {
                for (0..bw) |bx| {
                    const r = by * 4 + bx;
                    if (m.mask4[p] >> @intCast(r) & 1 == 0) continue;
                    const o = dst + by * 4 * stride + bx * 4;
                    if (m.lossless) {
                        transform.bypassAdd(P, o, stride, &m.coef[p][r], 4, .none, max);
                    } else transform.idct4Add(P, o, stride, &m.coef[p][r], max);
                }
            }
        }

        /// A lossless block after a vertical or horizontal prediction: the
        /// residual summed over the whole of it (8.5.15).
        fn losslessWhole(dst: [*]P, stride: usize, m: *const Mb, p: usize, bw: u32, bh: u32, dir: transform.Dpcm, max: i32) void {
            const w = bw * 4;
            const h = bh * 4;
            var r: [16 * 16]i32 = @splat(0);
            for (0..bh) |by| {
                for (0..bw) |bx| {
                    const k = by * 4 + bx;
                    if (m.mask4[p] >> @intCast(k) & 1 == 0) continue;
                    for (0..4) |j| {
                        for (0..4) |i| r[(by * 4 + j) * 16 + bx * 4 + i] = m.coef[p][k][j * 4 + i];
                    }
                }
            }
            if (dir == .vertical) {
                for (1..h) |j| {
                    for (0..w) |i| r[j * 16 + i] += r[(j - 1) * 16 + i];
                }
            } else if (dir == .horizontal) {
                for (0..h) |j| {
                    for (1..w) |i| r[j * 16 + i] += r[j * 16 + i - 1];
                }
            }
            for (0..h) |j| {
                for (0..w) |i| {
                    const q = &dst[j * stride + i];
                    const v = @as(i32, q.*) + r[j * 16 + i];
                    q.* = @intCast(if (v < 0) 0 else if (v > max) max else v);
                }
            }
        }

        fn intraChroma(rc: *const Rc, d: *const Dec, m: *const Mb) void {
            const s = rc.store;
            const mbh = d.mbh_c;
            const av = Avail.of(d, m, mbh);
            const max: i32 = (@as(i32, 1) << rc.depth_c) - 1;
            // intra_chroma_pred_mode 0 DC, 1 horizontal, 2 vertical, 3 plane,
            // into the luma numbering predictBlock takes.
            const mode: u8 = switch (m.chroma_mode) {
                0 => 2,
                1 => 1,
                2 => 0,
                else => 3,
            };
            for (1..3) |p| {
                const pl = place(d, s, p, 8, mbh);
                const base = planeOf(rc, s, p);
                const dst = ptr(base, &pl, 0, 0);
                predictChroma(rc, d, &av, &pl, base, mode);
                if (m.kind == .si) {
                    spChroma(rc, d, m, p);
                } else if (m.lossless and (mode == 0 or mode == 1)) {
                    losslessWhole(dst, pl.row, m, p, 2, mbh / 4, dpcmOf(mode), max);
                } else addBlocks4(dst, pl.row, m, p, 2, mbh / 4, max);
            }
        }

        /// A chroma plane's intra prediction, `mode` numbered as luma's.
        fn predictChroma(rc: *const Rc, d: *const Dec, av: *const Avail, pl: *const Place, base: [*]P, mode: u8) void {
            const mbh = d.mbh_c;
            var e: intra.Edge(P, 16) = .{};
            e.has_top = av.top;
            e.has_left = av.allLeft(0, mbh);
            e.has_corner = av.corner;
            if (e.has_top) {
                for (0..8) |i| e.top[i] = at(base, pl, @intCast(i), -1);
            }
            if (e.has_left) {
                for (0..mbh) |i| e.left[i] = at(base, pl, -1, @intCast(i));
            } else {
                for (0..mbh / 4) |g| {
                    if (!av.allLeft(g * 4, 4)) continue;
                    e.left4 |= @as(u4, 1) << @intCast(g);
                    for (g * 4..g * 4 + 4) |i| e.left[i] = at(base, pl, -1, @intCast(i));
                }
            }
            if (e.has_corner) e.corner = at(base, pl, -1, -1);
            const dst = ptr(base, pl, 0, 0);
            if (mbh == 8) {
                intra.predictBlock(P, 8, 8, dst, pl.row, mode, &e, true, d.sps.chroma_format_idc, rc.depth_c);
            } else {
                intra.predictBlock(P, 8, 16, dst, pl.row, mode, &e, true, d.sps.chroma_format_idc, rc.depth_c);
            }
        }

        // --- residual of inter macroblocks ---------------------------------

        fn addResidualPlane(rc: *const Rc, d: *const Dec, m: *const Mb, p: usize) void {
            const s = rc.store;
            const pl = place(d, s, p, 16, 16);
            const base = planeOf(rc, s, p);
            const max: i32 = (@as(i32, 1) << depthOf(rc, p)) - 1;
            const dst = ptr(base, &pl, 0, 0);
            if (m.t8x8) {
                for (0..4) |b8| {
                    if (m.mask8[p] >> @intCast(b8) & 1 == 0) continue;
                    const o = dst + (b8 >> 1) * 8 * pl.row + (b8 & 1) * 8;
                    if (m.lossless) {
                        transform.bypassAdd(P, o, pl.row, &m.coef8[p][b8], 8, .none, max);
                    } else transform.idct8Add(P, o, pl.row, &m.coef8[p][b8], max);
                }
            } else addBlocks4(dst, pl.row, m, p, 4, 4, max);
        }

        fn addResidualChroma(rc: *const Rc, d: *const Dec, m: *const Mb) void {
            const s = rc.store;
            const max: i32 = (@as(i32, 1) << rc.depth_c) - 1;
            for (1..3) |p| {
                const pl = place(d, s, p, 8, d.mbh_c);
                addBlocks4(ptr(planeOf(rc, s, p), &pl, 0, 0), pl.row, m, p, 2, d.mbh_c / 4, max);
            }
        }

        // --- SP and SI (8.6) -------------------------------------------------

        /// A P macroblock of an SP slice, its prediction in place: each
        /// block's put together with its levels.
        fn spInter(rc: *const Rc, d: *const Dec, m: *const Mb) void {
            const s = rc.store;
            const pl = place(d, s, 0, 16, 16);
            const base = planeOf(rc, s, 0);
            const max: i32 = (@as(i32, 1) << rc.depth_y) - 1;
            for (0..16) |r| {
                const bx: u32 = @intCast(r & 3);
                const by: u32 = @intCast(r >> 2);
                spBlock(rc, d, m, ptr(base, &pl, bx * 4, by * 4), pl.row, 0, r, max);
            }
            for (1..3) |p| spChroma(rc, d, m, p);
        }

        /// QP (to scale the levels with) and QS (to quantize with) of a
        /// plane of an SP or SI macroblock, 8 bits deep as the Extended
        /// profile is.
        fn spQp(rc: *const Rc, d: *const Dec, m: *const Mb, p: usize) [2]i32 {
            if (p == 0) return .{ m.qp, rc.hdr.qs };
            const off = d.pps.chroma_qp_offset[p - 1];
            return .{ mbm.chromaQp(m.qp, off, 0), mbm.chromaQp(rc.hdr.qs, off, 0) };
        }

        /// Whether the prediction is quantized before the levels are added
        /// (8.6.2: SI, and SP with sp_for_switch_flag) or the levels are
        /// scaled into the prediction's coefficients (8.6.1).
        fn spSwitch(rc: *const Rc, m: *const Mb) bool {
            return m.kind == .si or rc.hdr.sp_for_switch;
        }

        const zero16: [16]i32 = @splat(0);

        fn levelsOf(m: *const Mb, p: usize, r: usize) *const [16]i32 {
            return if (m.mask4[p] >> @intCast(r) & 1 != 0) &m.coef[p][r] else &zero16;
        }

        /// A luma block of an SP or SI macroblock, its prediction at `dst`
        /// (8.6.1.1, 8.6.2.1).
        fn spBlock(rc: *const Rc, d: *const Dec, m: *const Mb, dst: [*]P, stride: usize, p: usize, r: usize, max: i32) void {
            const q = spQp(rc, d, m, p);
            const list = mbm.list4(d, m, p);
            var cp: [16]i32 = undefined;
            forward4(dst, stride, &cp);
            var c: [16]i32 = undefined;
            spCoefs(&cp, levelsOf(m, p, r), q, &d.scales.s4[list][@intCast(@mod(q[0], 6))], spSwitch(rc, m), 0, &c);
            spPut(dst, stride, &c, &d.scales.s4[list][@intCast(@mod(q[1], 6))], q[1], false, max);
        }

        /// A chroma plane of an SP or SI macroblock, its prediction in
        /// place (8.6.1.2, 8.6.2.2): the four blocks' DCs go through a 2x2
        /// transform of their own. Blocks and DCs by row * 2 + column.
        fn spChroma(rc: *const Rc, d: *const Dec, m: *const Mb, p: usize) void {
            const s = rc.store;
            const pl = place(d, s, p, 8, 8);
            const base = planeOf(rc, s, p);
            const max: i32 = (@as(i32, 1) << rc.depth_c) - 1;
            const q = spQp(rc, d, m, p);
            const list = mbm.list4(d, m, p);
            const ls_qp = &d.scales.s4[list][@intCast(@mod(q[0], 6))];
            const ls_qs = &d.scales.s4[list][@intCast(@mod(q[1], 6))];
            const ls2 = level2[@intCast(@mod(q[1], 6))][0];
            const qp6: u6 = @intCast(@divTrunc(q[0], 6));
            const qs6: u6 = @intCast(@divTrunc(q[1], 6));
            const sw = spSwitch(rc, m);
            var cp: [4][16]i32 = undefined;
            for (0..4) |k| forward4(ptr(base, &pl, @intCast((k & 1) * 4), @intCast((k >> 1) * 4)), pl.row, &cp[k]);
            const dcp = hadamard2(.{ cp[0][0], cp[1][0], cp[2][0], cp[3][0] });
            var dcr: [4]i32 = undefined;
            for (0..4) |k| {
                const level = levelsOf(m, p, (k >> 1) * 4 + (k & 1))[0];
                if (sw) {
                    dcr[k] = quantize(dcp[k], ls2, q[1], 1) + level;
                } else {
                    const scaled = ((@as(i64, level) * ls_qp[0] * level_a[0]) << qp6) >> 9;
                    dcr[k] = quantize(dcp[k] + scaled, ls2, q[1], 1);
                }
            }
            const f = hadamard2(dcr);
            for (0..4) |k| {
                const r = (k >> 1) * 4 + (k & 1);
                var c: [16]i32 = undefined;
                // 8-431; 8.6.2.2 takes f as it is (8-441), which would leave
                // the DC unscaled, as no other step scales it.
                c[0] = @truncate(((@as(i64, f[k]) * ls_qs[0]) << qs6) >> 5);
                spCoefs(&cp[k], levelsOf(m, p, r), q, ls_qp, sw, 1, &c);
                spPut(ptr(base, &pl, @intCast((k & 1) * 4), @intCast((k >> 1) * 4)), pl.row, &c, ls_qs, q[1], true, max);
            }
        }

        /// The forward core transform of the 4x4 samples at `src` (8-415).
        fn forward4(src: [*]const P, stride: usize, out: *[16]i32) void {
            var t: [16]i32 = undefined;
            for (0..4) |i| {
                const row = src + i * stride;
                const s03 = @as(i32, row[0]) + row[3];
                const d03 = @as(i32, row[0]) - row[3];
                const s12 = @as(i32, row[1]) + row[2];
                const d12 = @as(i32, row[1]) - row[2];
                t[i * 4 + 0] = s03 + s12;
                t[i * 4 + 1] = 2 * d03 + d12;
                t[i * 4 + 2] = s03 - s12;
                t[i * 4 + 3] = d03 - 2 * d12;
            }
            for (0..4) |j| {
                const s03 = t[0 * 4 + j] + t[3 * 4 + j];
                const d03 = t[0 * 4 + j] - t[3 * 4 + j];
                const s12 = t[1 * 4 + j] + t[2 * 4 + j];
                const d12 = t[1 * 4 + j] - t[2 * 4 + j];
                out[0 * 4 + j] = s03 + s12;
                out[1 * 4 + j] = 2 * d03 + d12;
                out[2 * 4 + j] = s03 - s12;
                out[3 * 4 + j] = d03 - 2 * d12;
            }
        }

        /// 8.5.12 with QS; the samples are the residual alone.
        fn spPut(dst: [*]P, stride: usize, c: *[16]i32, ls: *const [16]u32, qs: i32, chroma: bool, max: i32) void {
            transform.scale4(c, ls, qs, chroma);
            for (0..4) |y| @memset(dst[y * stride .. y * stride + 4], 0);
            transform.idct4Add(P, dst, stride, c, max);
        }

        // --- inter -----------------------------------------------------------

        fn sameMotion(mv: *const mvpred.Out, a: usize, b: usize) bool {
            for (0..2) |l| {
                const ba = (a >> 3) * 2 + ((a & 3) >> 1);
                const bb = (b >> 3) * 2 + ((b & 3) >> 1);
                if (mv.ref[l][ba] != mv.ref[l][bb]) return false;
                if (mv.ref[l][ba] >= 0 and (mv.mv[l][a][0] != mv.mv[l][b][0] or mv.mv[l][a][1] != mv.mv[l][b][1])) return false;
            }
            return true;
        }

        fn predictInter(rc: *const Rc, d: *const Dec, mv: *const mvpred.Out) void {
            // The largest blocks of one motion: the whole, each 8x8, or 4x4s.
            var whole = true;
            for (1..16) |i| {
                if (!sameMotion(mv, 0, i)) {
                    whole = false;
                    break;
                }
            }
            if (whole) return block(rc, d, mv, 0, 0, 4, 4);
            for (0..4) |b8| {
                const x: u32 = @intCast((b8 & 1) * 2);
                const y: u32 = @intCast((b8 >> 1) * 2);
                const c0 = y * 4 + x;
                if (sameMotion(mv, c0, c0 + 1) and sameMotion(mv, c0, c0 + 4) and sameMotion(mv, c0, c0 + 5)) {
                    block(rc, d, mv, x, y, 2, 2);
                } else {
                    for ([4]u32{ 0, 1, 4, 5 }) |o| {
                        const c = c0 + o;
                        block(rc, d, mv, c & 3, c >> 2, 1, 1);
                    }
                }
            }
        }

        /// The reference plane `p` of a picture, as fields or a frame.
        fn refPlane(rc: *const Rc, r: RefPic, p: usize) inter.Plane(P) {
            const s = r.store.?;
            const base = planeOf(rc, s, p);
            if (r.structure == 3) {
                return .{ .data = base, .stride = s.stride[p], .width = @intCast(s.width[p]), .height = @intCast(s.height[p]) };
            }
            const off: usize = if (r.structure == 2) s.stride[p] else 0;
            return .{ .data = base + off, .stride = 2 * s.stride[p], .width = @intCast(s.width[p]), .height = @intCast(s.height[p] / 2) };
        }

        /// The prediction of the 4x4 blocks (x, y) to (x + w, y + h), one motion.
        fn block(rc: *const Rc, d: *const Dec, mv: *const mvpred.Out, x: u32, y: u32, w: u32, h: u32) void {
            const s = rc.store;
            const cell = y * 4 + x;
            const b8 = (y >> 1) * 2 + (x >> 1);
            var refs: [2]RefPic = .{ .{}, .{} };
            var used: [2]bool = .{ false, false };
            for (0..2) |l| {
                const r = mv.ref[l][b8];
                if (r < 0) continue;
                refs[l] = mvpred.refPic(rc.mv, d, l, r);
                used[l] = refs[l].store != null;
            }
            if (!used[0] and !used[1]) return; // a missing reference: left as it is
            // The block's place in the picture its references are: a field's
            // rows for a field macroblock.
            const fy_mb: u32 = if (d.field) d.mb_y >> 1 else d.mb_y;
            const lx: i32 = @intCast(16 * d.mb_x + 4 * x);
            const ly: i32 = @intCast(16 * fy_mb + 4 * y);
            const buf = &rc.scratch.pred;
            const work = &rc.scratch.inter;
            const planes: usize = if (d.cat == 3) 3 else 1;
            for (0..2) |l| {
                if (!used[l]) continue;
                const v = mv.mv[l][cell];
                if (rc.sync) |sy| {
                    // The rows the block reads, the filter's taps too.
                    const rs = refs[l].store.?;
                    var last: i32 = ly + (v[1] >> 2) + @as(i32, @intCast(4 * h)) + 5;
                    if (refs[l].structure != 3) last = 2 * last + 1;
                    sy.rows(rs, if (last < 0) 1 else @min(@as(u32, @intCast(last >> 4)) + 1, rs.height[0] >> 4));
                }
                for (0..planes) |p| {
                    inter.luma(P, work, refPlane(rc, refs[l], p), lx + (v[0] >> 2), ly + (v[1] >> 2), @intCast(v[0] & 3), @intCast(v[1] & 3), w * 4, h * 4, &buf[l][p], 16, (@as(i32, 1) << (if (p == 0) rc.depth_y else rc.depth_c)) - 1);
                }
                if (d.cat == 1 or d.cat == 2) {
                    const cw = w * 2;
                    const chh = if (d.cat == 1) h * 2 else h * 4;
                    const cx: i32 = @divTrunc(lx, 2);
                    const cy: i32 = if (d.cat == 1) @divTrunc(ly, 2) else ly;
                    var mvy = v[1];
                    if (d.cat == 1 and d.field) {
                        // A field's chroma rows sit a quarter row apart from
                        // the other field's (Table 8-9).
                        const cur_par: i32 = @intCast(d.mb_y & 1);
                        const ref_par: i32 = if (refs[l].structure == 2) 1 else 0;
                        mvy += 2 * (cur_par - ref_par);
                    }
                    for (1..3) |p| {
                        if (d.cat == 1) {
                            inter.chroma(P, work, refPlane(rc, refs[l], p), cx + (v[0] >> 3), cy + (mvy >> 3), @intCast(v[0] & 7), @intCast(mvy & 7), cw, chh, &buf[l][p], 16);
                        } else {
                            inter.chroma(P, work, refPlane(rc, refs[l], p), cx + (v[0] >> 3), cy + (v[1] >> 2), @intCast(v[0] & 7), @intCast((v[1] & 3) << 1), cw, chh, &buf[l][p], 16);
                        }
                    }
                }
            }
            // Weighted into the picture.
            for (0..3) |p| {
                if (p > 0 and d.mbh_c == 0) break;
                const chroma_plane = p > 0 and d.cat != 3;
                const bw: u32 = if (chroma_plane) w * 2 else w * 4;
                const bh: u32 = if (!chroma_plane) h * 4 else if (d.cat == 1) h * 2 else h * 4;
                const mbw: u32 = if (chroma_plane) 8 else 16;
                const mbh: u32 = if (chroma_plane) d.mbh_c else 16;
                const pl = place(d, s, p, mbw, mbh);
                const ox: u32 = x * mbw / 4;
                const oy: u32 = y * mbh / 4;
                const dst = ptr(planeOf(rc, s, p), &pl, ox, oy);
                const depth: u5 = if (p == 0) rc.depth_y else rc.depth_c;
                const max: i32 = (@as(i32, 1) << depth) - 1;
                weighted(rc, d, mv, b8, p, used, dst, pl.row, &buf[0][p], &buf[1][p], bw, bh, depth, max);
            }
        }

        /// The blocks of the lists weighted into the picture: weights that
        /// come to the default prediction's - the same for both, and no
        /// offset - take its shorter way.
        fn weighted(rc: *const Rc, d: *const Dec, mv: *const mvpred.Out, b8: u32, p: usize, used: [2]bool, dst: [*]P, stride: usize, s0: [*]const u16, s1: [*]const u16, w: u32, h: u32, depth: u5, max: i32) void {
            const both = used[0] and used[1];
            switch (rc.weighting) {
                .none => {
                    if (both) return inter.put2(P, dst, stride, s0, s1, 16, w, h);
                    return inter.put1(P, dst, stride, if (used[0]) s0 else s1, 16, w, h);
                },
                .implicit => {
                    if (!both) return inter.put1(P, dst, stride, if (used[0]) s0 else s1, 16, w, h);
                    const ws = mvpred.implicitWeights(rc.mv, d, mv.ref[0][b8], mv.ref[1][b8]);
                    if (ws[0] == 32 and ws[1] == 32) return inter.put2(P, dst, stride, s0, s1, 16, w, h);
                    return inter.weight2(P, dst, stride, s0, s1, 16, w, h, 5, ws[0], ws[1], 0, max);
                },
                .explicit => {
                    var lw: [2]i32 = .{ 0, 0 };
                    var lo: [2]i32 = .{ 0, 0 };
                    var log_wd: u32 = 0;
                    for (0..2) |l| {
                        if (!used[l]) continue;
                        var idx: usize = @intCast(mv.ref[l][b8]);
                        if (d.mbaff and d.field) idx >>= 1;
                        const wt = &rc.hdr.weights[l];
                        if (p == 0) {
                            log_wd = wt.luma_denom;
                            lw[l] = wt.luma[idx][0];
                            lo[l] = @as(i32, wt.luma[idx][1]) << @intCast(depth - 8);
                        } else {
                            log_wd = wt.chroma_denom;
                            lw[l] = wt.chroma[idx][p - 1][0];
                            lo[l] = @as(i32, wt.chroma[idx][p - 1][1]) << @intCast(depth - 8);
                        }
                    }
                    const unit = @as(i32, 1) << @intCast(log_wd);
                    if (both) {
                        if (lw[0] == unit and lw[1] == unit and lo[0] == 0 and lo[1] == 0) return inter.put2(P, dst, stride, s0, s1, 16, w, h);
                        return inter.weight2(P, dst, stride, s0, s1, 16, w, h, log_wd, lw[0], lw[1], (lo[0] + lo[1] + 1) >> 1, max);
                    }
                    const l: usize = if (used[0]) 0 else 1;
                    if (lw[l] == unit and lo[l] == 0) return inter.put1(P, dst, stride, if (l == 0) s0 else s1, 16, w, h);
                    return inter.weight1(P, dst, stride, if (l == 0) s0 else s1, 16, w, h, log_wd, lw[l], lo[l], max);
                },
            }
        }
    };
}

/// LevelScale2 (8-418, 8-419) by QS % 6 and the kind of place.
const level2 = [6][3]i32{
    .{ 13107, 5243, 8066 }, .{ 11916, 4660, 7490 }, .{ 10082, 4194, 6554 },
    .{ 9362, 3647, 5825 },  .{ 8192, 3355, 5243 },  .{ 7282, 2893, 4559 },
};
/// A (8-417) by the kind of place.
const level_a = [3]i32{ 16, 25, 20 };

/// The kind of place (i, j) of a 4x4 block: both even 0, both odd 1,
/// else 2.
fn kindOf(r: usize) usize {
    const i = r >> 2;
    const j = r & 3;
    if (i & 1 == 0 and j & 1 == 0) return 0;
    if (i & 1 == 1 and j & 1 == 1) return 1;
    return 2;
}

/// A coefficient quantized with QS (8-420); `extra` 1 for a chroma DC
/// (8-429). The sign is taken off and put back, as in 8-420.
fn quantize(v: i64, ls2: i32, qs: i32, extra: u6) i32 {
    const shift: u6 = @intCast(15 + extra + @divTrunc(qs, 6));
    const mag: i64 = (@as(i64, @intCast(@abs(v))) * ls2 + (@as(i64, 1) << (shift - 1))) >> shift;
    return @truncate(if (v < 0) -mag else mag);
}

/// A block's coefficients from its prediction's `cp` and its levels `cr`
/// (raster), from place `first` on: the levels scaled with QP and added,
/// then quantized with QS (8-416, 8-420), or when switching the
/// prediction quantized and the levels added (8-432, 8-433).
fn spCoefs(cp: *const [16]i32, cr: *const [16]i32, q: [2]i32, ls_qp: *const [16]u32, sw: bool, first: usize, c: *[16]i32) void {
    const qp6: u6 = @intCast(@divTrunc(q[0], 6));
    const ls2 = &level2[@intCast(@mod(q[1], 6))];
    for (first..16) |r| {
        const kind = kindOf(r);
        if (sw) {
            c[r] = cr[r] +% quantize(cp[r], ls2[kind], q[1], 0);
        } else {
            const scaled = ((@as(i64, cr[r]) * ls_qp[r] * level_a[kind]) << qp6) >> 10;
            c[r] = quantize(cp[r] + scaled, ls2[kind], q[1], 0);
        }
    }
}

/// The 2x2 transform of the chroma DCs (8-427, 8-430), by row * 2 +
/// column.
fn hadamard2(v: [4]i32) [4]i32 {
    return .{
        v[0] + v[1] + v[2] + v[3],
        v[0] - v[1] + v[2] - v[3],
        v[0] + v[1] - v[2] - v[3],
        v[0] - v[1] - v[2] + v[3],
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

test "both sample sizes compile" {
    _ = &Recon(u8).mb;
    _ = &Recon(u16).mb;
}

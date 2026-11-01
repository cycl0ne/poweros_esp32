// SPDX-License-Identifier: MIT
//! The in-loop filters (8.7): the deblocking filter on the edges the CTU
//! decoder gave a strength, then the sample adaptive offset, a CTB row
//! at a time behind the decoding.
//!
//! A row is deblocked once the row below it is decoded - the intra
//! prediction of that row needs its last line as it was - and its SAO
//! runs once the row below is deblocked too, from a copy of the row so
//! that each sample sees its neighbours as the deblocking left them. The
//! line above a row is kept from before its SAO for the same reason.

const common = @import("common.zig");
const params = @import("params.zig");
const tables = @import("tables.zig");
const picture = @import("picture.zig");

/// The filters' state for one picture.
pub const Filter = struct {
    sps: *const params.Sps = undefined,
    pps: *const params.Pps = undefined,
    info: *const picture.Info = undefined,
    store: *common.Store = undefined,
    /// The CTB rows deblocked, and those with their SAO done.
    deblocked: u32 = 0,
    finished: u32 = 0,
    /// What the SAO works in: each component's band of a CTB row with a
    /// line above and below, and the last line of the band before.
    band: []u8 = &.{},
    saved: [3][]u8 = .{ &.{}, &.{}, &.{} },

    pub fn alloc(f: *Filter, env: common.Env, sps: *const params.Sps) bool {
        f.free(env);
        const bytes: usize = if (sps.bit_depth_luma > 8 or sps.bit_depth_chroma > 8) 2 else 1;
        const w = sps.width;
        f.band = env.slice(u8, (sps.ctbSize() + 2) * w * bytes) orelse return false;
        for (&f.saved) |*s| {
            s.* = env.slice(u8, w * bytes) orelse {
                f.free(env);
                return false;
            };
        }
        return true;
    }

    pub fn free(f: *Filter, env: common.Env) void {
        env.freeSlice(u8, f.band);
        for (&f.saved) |*s| env.freeSlice(u8, s.*);
        f.band = &.{};
        f.saved = .{ &.{}, &.{}, &.{} };
    }

    pub fn begin(f: *Filter, sps: *const params.Sps, pps: *const params.Pps, info: *const picture.Info, store: *common.Store) void {
        f.sps = sps;
        f.pps = pps;
        f.info = info;
        f.store = store;
        f.deblocked = 0;
        f.finished = 0;
    }
};

inline fn clip3(lo: i32, hi: i32, v: i32) i32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}

pub fn Loop(comptime T: type) type {
    return struct {
        inline fn plane(f: *const Filter, c: usize) [*]T {
            return @ptrCast(@alignCast(f.store.planes[c]));
        }

        /// The filters as far as `decoded` CTB rows allow, all of them when
        /// the picture is `complete`; the store's progress set to the luma
        /// rows that are final.
        pub fn advance(f: *Filter, decoded: u32, complete: bool) void {
            const rows = f.info.hctb;
            while (f.deblocked < rows and (f.deblocked + 1 < decoded or (complete and f.deblocked < decoded))) {
                deblockRow(f, f.deblocked);
                f.deblocked += 1;
            }
            const all = complete and f.deblocked == rows;
            var moved = false;
            while (f.finished < f.deblocked and (f.finished + 2 <= f.deblocked or all)) {
                saoRow(f, f.finished);
                f.finished += 1;
                moved = true;
            }
            if (moved) {
                const done = if (f.finished == rows) f.sps.height else @min(f.sps.height, f.finished << f.info.log2_ctb);
                @atomicStore(u32, &f.store.progress, done, .release);
            }
        }

        // --- deblocking ----------------------------------------------------

        fn deblockRow(f: *Filter, r: u32) void {
            const sps = f.sps;
            const info = f.info;
            const y0 = r << info.log2_ctb;
            const y1 = @min(sps.height, y0 + (@as(u32, 1) << info.log2_ctb));
            const width = sps.width;
            const cat = sps.chromaArrayType();
            // Vertical edges.
            var y = y0;
            while (y < y1) : (y += 4) {
                var x: u32 = 8;
                while (x < width) : (x += 8) {
                    const b = info.bs[info.at4(x, y)] & 3;
                    if (b != 0) lumaEdge(f, x, y, b, true);
                }
            }
            if (cat != 0) chromaEdges(f, y0, y1, true);
            // Horizontal edges.
            y = if (y0 == 0) 8 else y0;
            while (y < y1) : (y += 8) {
                var x: u32 = 0;
                while (x < width) : (x += 4) {
                    const b = (info.bs[info.at4(x, y)] >> 2) & 3;
                    if (b != 0) lumaEdge(f, x, y, b, false);
                }
            }
            if (cat != 0) chromaEdges(f, y0, y1, false);
        }

        /// The chroma edges with bS 2 on the chroma 8x8 grid among the luma
        /// rows y0 to y1 (8.7.2.5.1, 8.7.2.5.2).
        fn chromaEdges(f: *Filter, y0: u32, y1: u32, vertical: bool) void {
            const sps = f.sps;
            const info = f.info;
            const sw: u5 = sps.shiftW();
            const sh: u5 = sps.shiftH();
            const cw = sps.width >> sw;
            const cy0 = y0 >> sh;
            const cy1 = y1 >> sh;
            if (vertical) {
                var yc = cy0;
                while (yc < cy1) : (yc += 4) {
                    var xc: u32 = 8;
                    while (xc < cw) : (xc += 8) {
                        if (info.bs[info.at4(xc << sw, yc << sh)] & 3 == 2) {
                            chromaEdge(f, 1, xc, yc, true);
                            chromaEdge(f, 2, xc, yc, true);
                        }
                    }
                }
            } else {
                var yc = if (cy0 == 0) 8 else (cy0 + 7) & ~@as(u32, 7);
                while (yc < cy1) : (yc += 8) {
                    var xc: u32 = 0;
                    while (xc < cw) : (xc += 4) {
                        if ((info.bs[info.at4(xc << sw, yc << sh)] >> 2) & 3 == 2) {
                            chromaEdge(f, 1, xc, yc, false);
                            chromaEdge(f, 2, xc, yc, false);
                        }
                    }
                }
            }
        }

        /// The slice offsets of the slice the luma sample (x, y) lies in.
        fn sliceOf(info: *const picture.Info, x: u32, y: u32) *const picture.SliceInfo {
            return &info.slices[info.ctb_slice[info.ctbOf(x, y)]];
        }

        /// A luma edge of four lines (8.7.2.5.3, 8.7.2.5.4), at (x, y) the
        /// first sample on its q side.
        fn lumaEdge(f: *Filter, x: u32, y: u32, bs: u8, vertical: bool) void {
            const sps = f.sps;
            const info = f.info;
            const depth = sps.bit_depth_luma;
            const xp = if (vertical) x - 1 else x;
            const yp = if (vertical) y else y - 1;
            const cp = info.cu(xp, yp);
            const cq = info.cu(x, y);
            const qpl = (@as(i32, cp.qp) + cq.qp + 1) >> 1;
            const sl = sliceOf(info, x, y);
            const bq = clip3(0, 51, qpl + sl.beta);
            const beta: i32 = @as(i32, tables.beta_table[@intCast(bq)]) << (depth - 8);
            const tq = clip3(0, 53, qpl + 2 * (@as(i32, bs) - 1) + sl.tc);
            const tc: i32 = @as(i32, tables.tc_table[@intCast(tq)]) << (depth - 8);
            if (tc == 0 or beta == 0) return;
            const no_p = info.any_nofilter and cp.flags & picture.cu_nofilter != 0;
            const no_q = info.any_nofilter and cq.flags & picture.cu_nofilter != 0;
            const stride = f.store.stride[0];
            // The first p sample, p3, of line 0; across the edge and along it.
            const across: usize = if (vertical) 1 else stride;
            const along: usize = if (vertical) stride else 1;
            const base = plane(f, 0) + (if (vertical) y * stride + x - 4 else (y - 4) * stride + x);
            const S = struct {
                inline fn at(b: [*]T, line: usize, i: usize, ac: usize, al: usize) i32 {
                    return b[line * al + i * ac];
                }
            };
            // p_i is sample 3 - i, q_i sample 4 + i.
            const dp0 = @abs(S.at(base, 0, 1, across, along) - 2 * S.at(base, 0, 2, across, along) + S.at(base, 0, 3, across, along));
            const dp3 = @abs(S.at(base, 3, 1, across, along) - 2 * S.at(base, 3, 2, across, along) + S.at(base, 3, 3, across, along));
            const dq0 = @abs(S.at(base, 0, 6, across, along) - 2 * S.at(base, 0, 5, across, along) + S.at(base, 0, 4, across, along));
            const dq3 = @abs(S.at(base, 3, 6, across, along) - 2 * S.at(base, 3, 5, across, along) + S.at(base, 3, 4, across, along));
            const dpq0: i32 = @intCast(dp0 + dq0);
            const dpq3: i32 = @intCast(dp3 + dq3);
            const dp: i32 = @intCast(dp0 + dp3);
            const dq: i32 = @intCast(dq0 + dq3);
            if (dpq0 + dpq3 >= beta) return;
            const sam = struct {
                fn sample(b: [*]T, line: usize, ac: usize, al: usize, dpq: i32, be: i32, t: i32) bool {
                    const p0 = S.at(b, line, 3, ac, al);
                    const p3 = S.at(b, line, 0, ac, al);
                    const q0 = S.at(b, line, 4, ac, al);
                    const q3 = S.at(b, line, 7, ac, al);
                    return 2 * dpq < (be >> 2) and @abs(p3 - p0) + @abs(q0 - q3) < (be >> 3) and @abs(p0 - q0) < ((5 * t + 1) >> 1);
                }
            }.sample;
            const strong = sam(base, 0, across, along, dpq0, beta, tc) and sam(base, 3, across, along, dpq3, beta, tc);
            const side = (beta + (beta >> 1)) >> 3;
            const dep = dp < side;
            const deq = dq < side;
            const max: i32 = (@as(i32, 1) << depth) - 1;
            for (0..4) |k| {
                const l = base + k * along;
                const p3 = S.at(l, 0, 0, across, along);
                const p2 = S.at(l, 0, 1, across, along);
                const p1 = S.at(l, 0, 2, across, along);
                const p0 = S.at(l, 0, 3, across, along);
                const q0 = S.at(l, 0, 4, across, along);
                const q1 = S.at(l, 0, 5, across, along);
                const q2 = S.at(l, 0, 6, across, along);
                const q3 = S.at(l, 0, 7, across, along);
                if (strong) {
                    const t2 = 2 * tc;
                    if (!no_p) {
                        l[3 * across] = @intCast(clip3(p0 - t2, p0 + t2, (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3));
                        l[2 * across] = @intCast(clip3(p1 - t2, p1 + t2, (p2 + p1 + p0 + q0 + 2) >> 2));
                        l[1 * across] = @intCast(clip3(p2 - t2, p2 + t2, (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3));
                    }
                    if (!no_q) {
                        l[4 * across] = @intCast(clip3(q0 - t2, q0 + t2, (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3));
                        l[5 * across] = @intCast(clip3(q1 - t2, q1 + t2, (p0 + q0 + q1 + q2 + 2) >> 2));
                        l[6 * across] = @intCast(clip3(q2 - t2, q2 + t2, (p0 + q0 + q1 + 3 * q2 + 2 * q3 + 4) >> 3));
                    }
                    continue;
                }
                var delta = (9 * (q0 - p0) - 3 * (q1 - p1) + 8) >> 4;
                if (@abs(delta) >= tc * 10) continue;
                delta = clip3(-tc, tc, delta);
                const ht = tc >> 1;
                if (!no_p) {
                    l[3 * across] = @intCast(clip3(0, max, p0 + delta));
                    if (dep) l[2 * across] = @intCast(clip3(0, max, p1 + clip3(-ht, ht, (((p2 + p0 + 1) >> 1) - p1 + delta) >> 1)));
                }
                if (!no_q) {
                    l[4 * across] = @intCast(clip3(0, max, q0 - delta));
                    if (deq) l[5 * across] = @intCast(clip3(0, max, q1 + clip3(-ht, ht, (((q2 + q0 + 1) >> 1) - q1 - delta) >> 1)));
                }
            }
        }

        /// A chroma edge of four lines of component `c` (8.7.2.5.5), at
        /// (xc, yc) of its plane the first sample on its q side.
        fn chromaEdge(f: *Filter, c: usize, xc: u32, yc: u32, vertical: bool) void {
            const sps = f.sps;
            const pps = f.pps;
            const info = f.info;
            const sw: u5 = sps.shiftW();
            const sh: u5 = sps.shiftH();
            const depth = sps.bit_depth_chroma;
            const xq = xc << sw;
            const yq = yc << sh;
            const xp = if (vertical) (xc - 1) << sw else xq;
            const yp = if (vertical) yq else (yc - 1) << sh;
            const cp = info.cu(xp, yp);
            const cq = info.cu(xq, yq);
            const off: i32 = if (c == 1) pps.cb_qp_offset else pps.cr_qp_offset;
            const qpi = ((@as(i32, cp.qp) + cq.qp + 1) >> 1) + off;
            const qpc = if (sps.chromaArrayType() == 1) tables.qpc420(qpi) else @min(qpi, 51);
            const sl = sliceOf(info, xq, yq);
            const tq = clip3(0, 53, qpc + 2 + sl.tc);
            const tc: i32 = @as(i32, tables.tc_table[@intCast(tq)]) << (depth - 8);
            if (tc == 0) return;
            const no_p = info.any_nofilter and cp.flags & picture.cu_nofilter != 0;
            const no_q = info.any_nofilter and cq.flags & picture.cu_nofilter != 0;
            const stride = f.store.stride[c];
            const across: usize = if (vertical) 1 else stride;
            const along: usize = if (vertical) stride else 1;
            // p1 of line 0.
            const base = plane(f, c) + (if (vertical) yc * stride + xc - 2 else (yc - 2) * stride + xc);
            const max: i32 = (@as(i32, 1) << depth) - 1;
            const ch = sps.height >> sh;
            const cw = sps.width >> sw;
            for (0..4) |k| {
                // The last segment may stop at the picture's edge.
                if (vertical and yc + k >= ch) break;
                if (!vertical and xc + k >= cw) break;
                const l = base + k * along;
                const p1: i32 = l[0];
                const p0: i32 = l[across];
                const q0: i32 = l[2 * across];
                const q1: i32 = l[3 * across];
                const delta = clip3(-tc, tc, ((((q0 - p0) << 2) + p1 - q1 + 4) >> 3));
                if (!no_p) l[across] = @intCast(clip3(0, max, p0 + delta));
                if (!no_q) l[2 * across] = @intCast(clip3(0, max, q0 - delta));
            }
        }

        // --- sample adaptive offset ----------------------------------------

        fn saoRow(f: *Filter, r: u32) void {
            const sps = f.sps;
            if (!sps.sao) return;
            const info = f.info;
            const ncomp: usize = if (sps.chromaArrayType() != 0) 3 else 1;
            for (0..ncomp) |c| {
                // Whether any CTB of the row has SAO on this component.
                var any = false;
                for (0..info.wctb) |rx| {
                    const rs = r * info.wctb + @as(u32, @intCast(rx));
                    const si = info.ctb_slice[rs];
                    if (si == picture.Info.no_slice) continue;
                    const s = &info.slices[si];
                    if ((if (c == 0) s.sao_luma else s.sao_chroma) and info.sao[rs].kind[c] != 0) any = true;
                }
                const sw: u5 = if (c == 0) 0 else sps.shiftW();
                const sh: u5 = if (c == 0) 0 else sps.shiftH();
                const cw = sps.width >> sw;
                const ch = sps.height >> sh;
                const csize = (@as(u32, 1) << info.log2_ctb) >> sh;
                const y0 = r * csize;
                const y1 = @min(ch, y0 + csize);
                const stride = f.store.stride[c];
                const p = plane(f, c);
                const saved: [*]T = @ptrCast(@alignCast(f.saved[c].ptr));
                if (!any) {
                    @memcpy(saved[0..cw], p[(y1 - 1) * stride ..][0..cw]);
                    continue;
                }
                // The band: the line above, the rows, the line below.
                const band: [*]T = @ptrCast(@alignCast(f.band.ptr));
                if (r > 0) @memcpy(band[0..cw], saved[0..cw]);
                var y = y0;
                while (y < @min(ch, y1 + 1)) : (y += 1) @memcpy(band[(y - y0 + 1) * cw ..][0..cw], p[y * stride ..][0..cw]);
                @memcpy(saved[0..cw], p[(y1 - 1) * stride ..][0..cw]);
                for (0..info.wctb) |rx| {
                    const rs = r * info.wctb + @as(u32, @intCast(rx));
                    const si = info.ctb_slice[rs];
                    if (si == picture.Info.no_slice) continue;
                    const s = &info.slices[si];
                    if (!(if (c == 0) s.sao_luma else s.sao_chroma)) continue;
                    const prm = &info.sao[rs];
                    if (prm.kind[c] == 0) continue;
                    const x0 = @as(u32, @intCast(rx)) * ((@as(u32, 1) << info.log2_ctb) >> sw);
                    const x1 = @min(cw, x0 + ((@as(u32, 1) << info.log2_ctb) >> sw));
                    ctbSao(f, c, rs, prm, band, cw, ch, x0, x1, y0, y1);
                }
            }
        }

        /// The SAO of one CTB of component `c` (8.7.3.2), from the band.
        fn ctbSao(f: *Filter, c: usize, rs: u32, prm: *const picture.Sao, band: [*]const T, cw: u32, ch: u32, x0: u32, x1: u32, y0: u32, y1: u32) void {
            const sps = f.sps;
            const info = f.info;
            const sw: u5 = if (c == 0) 0 else sps.shiftW();
            const sh: u5 = if (c == 0) 0 else sps.shiftH();
            const depth: u5 = if (c == 0) sps.bit_depth_luma else sps.bit_depth_chroma;
            const max: i32 = (@as(i32, 1) << depth) - 1;
            const stride = f.store.stride[c];
            const p = plane(f, c);
            const offs = prm.offsets[c];
            // The band row of picture row y.
            const B = struct {
                inline fn at(b: [*]const T, w: u32, top: u32, x: u32, y: u32) i32 {
                    return b[(y + 1 - top) * w + x];
                }
            };
            const skip = info.any_nofilter;
            if (prm.kind[c] == 1) {
                var table: [32]u8 = @splat(0);
                for (0..4) |k| table[(k + prm.class[c]) & 31] = @intCast(k + 1);
                const shift: u5 = depth - 5;
                for (y0..y1) |yy| {
                    const y: u32 = @intCast(yy);
                    for (x0..x1) |xx| {
                        const x: u32 = @intCast(xx);
                        if (skip and info.cu(x << sw, y << sh).flags & picture.cu_nofilter != 0) continue;
                        const v = B.at(band, cw, y0, x, y);
                        // A sample is in range: the mask only keeps one
                        // that is not inside the table.
                        const bi = table[@intCast((v >> shift) & 31)];
                        if (bi != 0) p[y * stride + x] = @intCast(clip3(0, max, v + offs[bi - 1]));
                    }
                }
                return;
            }
            const pos = [4][2][2]i32{
                .{ .{ -1, 0 }, .{ 1, 0 } },
                .{ .{ 0, -1 }, .{ 0, 1 } },
                .{ .{ -1, -1 }, .{ 1, 1 } },
                .{ .{ 1, -1 }, .{ -1, 1 } },
            };
            const hv = pos[prm.class[c]];
            // Which of the neighbouring CTBs may be looked at.
            var ok: [3][3]bool = undefined;
            const rx: i32 = @intCast(rs % info.wctb);
            const ry: i32 = @intCast(rs / info.wctb);
            for (0..3) |j| {
                for (0..3) |i| ok[j][i] = neighbourOk(f, rs, rx + @as(i32, @intCast(i)) - 1, ry + @as(i32, @intCast(j)) - 1);
            }
            const remap = [5]u8{ 1, 2, 0, 3, 4 };
            for (y0..y1) |yy| {
                const y: u32 = @intCast(yy);
                for (x0..x1) |xx| {
                    const x: u32 = @intCast(xx);
                    if (skip and info.cu(x << sw, y << sh).flags & picture.cu_nofilter != 0) continue;
                    var good = true;
                    for (hv) |d| {
                        const nx = @as(i32, @intCast(x)) + d[0];
                        const ny = @as(i32, @intCast(y)) + d[1];
                        if (nx < 0 or ny < 0 or nx >= cw or ny >= ch) {
                            good = false;
                            break;
                        }
                        const dx: usize = if (nx < x0) 0 else if (nx >= x1) 2 else 1;
                        const dy: usize = if (ny < y0) 0 else if (ny >= y1) 2 else 1;
                        if (!ok[dy][dx]) {
                            good = false;
                            break;
                        }
                    }
                    if (!good) continue;
                    const v = B.at(band, cw, y0, x, y);
                    const a = B.at(band, cw, y0, @intCast(@as(i32, @intCast(x)) + hv[0][0]), @intCast(@as(i32, @intCast(y)) + hv[0][1]));
                    const b = B.at(band, cw, y0, @intCast(@as(i32, @intCast(x)) + hv[1][0]), @intCast(@as(i32, @intCast(y)) + hv[1][1]));
                    const raw: usize = @intCast(2 + sign(v - a) + sign(v - b));
                    const ei = remap[raw];
                    if (ei != 0) p[y * stride + x] = @intCast(clip3(0, max, v + offs[ei - 1]));
                }
            }
        }

        fn sign(v: i32) i32 {
            return if (v > 0) 1 else if (v < 0) -1 else 0;
        }

        /// Whether the SAO of CTB `rs` may look into the CTB at (nx, ny).
        fn neighbourOk(f: *const Filter, rs: u32, nx: i32, ny: i32) bool {
            const info = f.info;
            if (nx < 0 or ny < 0 or nx >= info.wctb or ny >= info.hctb) return false;
            const nb: u32 = @intCast(@as(i32, @intCast(info.wctb)) * ny + nx);
            if (nb == rs) return true;
            const sn = info.ctb_slice[nb];
            if (sn == picture.Info.no_slice) return false;
            const sc = info.ctb_slice[rs];
            const cur = &info.slices[sc];
            const other = &info.slices[sn];
            if (cur.addr != other.addr) {
                const earlier = info.tiles.rs2ts[nb] < info.tiles.rs2ts[rs];
                if (earlier and !cur.across) return false;
                if (!earlier and !other.across) return false;
            }
            if (!f.pps.loop_filter_across_tiles and info.tiles.tile[nb] != info.tiles.tile[rs]) return false;
            return true;
        }
    };
}

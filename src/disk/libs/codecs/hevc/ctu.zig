// SPDX-License-Identifier: MIT
//! The slice segment data (7.3.8): its CTUs parsed - the SAO parameters,
//! the coding quadtree, coding, prediction and transform units and their
//! residuals - and reconstructed as they come: intra and inter prediction
//! (8.4, 8.5), the residual scaled, transformed and added (8.6). What the
//! loop filters and the later parts of the picture need is kept in its
//! `Info`, the motion later pictures need in its store.
//!
//! The arithmetic decoding runs through the substreams of tiles and
//! wavefront rows one after another; the entry points are not needed.

const bits = @import("bits.zig");
const Error = bits.Error;
const cabac = @import("cabac.zig");
const Ctx = cabac.Ctx;
const common = @import("common.zig");
const params = @import("params.zig");
const slice = @import("slice.zig");
const tables = @import("tables.zig");
const transform = @import("transform.zig");
const intra = @import("intra.zig");
const inter = @import("inter.zig");
const picture = @import("picture.zig");
const mvpred = @import("mvpred.zig");
const MvField = picture.MvField;
const Part = mvpred.Part;

/// A coding unit as it is decoded.
const Cu = struct {
    x: u32,
    y: u32,
    log2: u3,
    depth: u8,
    intra: bool = false,
    bypass: bool = false,
    skip: bool = false,
    pcm: bool = false,
    part: Part = .p2Nx2N,
    /// IntraSplitFlag.
    split: bool = false,
    max_trafo_depth: u32 = 0,
    /// merge_flag of the first prediction unit.
    merge: bool = false,
    /// IntraPredModeY and IntraPredModeC of each prediction block, and
    /// whether the latter is the former (intra_chroma_pred_mode 4).
    luma_modes: [4]u8 = .{ 1, 1, 1, 1 },
    chroma_modes: [4]u8 = .{ 1, 1, 1, 1 },
    chroma_dm: [4]bool = .{ false, false, false, false },
};

/// The coefficients of a block as they were parsed.
const Res = struct {
    ts: bool = false,
    rdpcm: bool = false,
    rdpcm_dir: u1 = 0,
    max_x: u32 = 0,
    max_y: u32 = 0,
};

/// Edges of the 4x4s of a coding unit, for the deblocking.
const edge_tu_v: u8 = 1;
const edge_tu_h: u8 = 2;
const edge_pu_v: u8 = 4;
const edge_pu_h: u8 = 8;

/// What decodes the CTUs of one picture.
pub const State = struct {
    sps: *const params.Sps = undefined,
    pps: *const params.Pps = undefined,
    info: *picture.Info = undefined,
    store: *common.Store = undefined,
    scales: *const transform.Scales = undefined,
    /// How references are waited for, when other cores decode them.
    sync: ?*const common.Sync = null,
    /// Called when a CTB row of the picture is whole.
    on_row: *const fn (st: *State) void = undefined,

    // The slice segment.
    hdr: *const slice.Header = undefined,
    lists: *const picture.Lists = undefined,
    slice_idx: u16 = 0,

    e: cabac.Engine = undefined,
    ctx: cabac.Contexts = undefined,
    stat: [4]u8 = .{ 0, 0, 0, 0 },
    wpp_ctx: cabac.Contexts = undefined,
    wpp_stat: [4]u8 = .{ 0, 0, 0, 0 },
    ds_ctx: cabac.Contexts = undefined,
    ds_stat: [4]u8 = .{ 0, 0, 0, 0 },

    // The quantization parameters (8.6.1).
    /// QpY of the last coding unit: qPY_PREV of the next group.
    qp_prev: i32 = 0,
    qp_pred: i32 = 0,
    qp_y: i32 = 0,
    delta_coded: bool = false,
    delta_val: i32 = 0,
    chroma_offset_coded: bool = false,
    cu_off_cb: i32 = 0,
    cu_off_cr: i32 = 0,

    edges: [16 * 16]u8 = undefined,
    coeff: [32 * 32]i32 = @splat(0),
    res: [32 * 32]i32 = undefined,
    res_y: [32 * 32]i32 = undefined,
    line: intra.Line = undefined,
    tw: transform.Work = .{},
    iw: inter.Work = .{},
    pred: [2][64 * 64]i32 = undefined,
};

inline fn clip3(lo: i32, hi: i32, v: i32) i32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}

/// The CTUs of a slice segment, with samples of type T.
pub fn Decode(comptime T: type) type {
    return struct {
        inline fn plane(st: *State, c: usize) [*]T {
            return @ptrCast(@alignCast(st.store.planes[c]));
        }

        /// The slice segment data `data` of the segment `st.hdr`.
        pub fn segment(st: *State, data: []const u8) Error!void {
            const h = st.hdr;
            const pps = st.pps;
            const info = st.info;
            const w = info.wctb;
            const ctbs = w * info.hctb;
            var rs = h.segment_address;
            var ts = info.tiles.rs2ts[rs];
            st.cu_off_cb = 0;
            st.cu_off_cr = 0;
            if (!h.dependent) st.qp_prev = h.qp;
            if (!st.e.init(data, 0)) return error.Corrupt;
            info.ctb_slice[rs] = st.slice_idx;
            if (startContexts(st, rs, ts, true)) st.qp_prev = h.qp;
            while (true) {
                info.ctb_slice[rs] = st.slice_idx;
                ctu(st, rs) catch |failure| {
                    info.broken[rs] = true;
                    return failure;
                };
                if (pps.entropy_coding_sync and (rs % w == 1 or (rs > 1 and info.tiles.tile[rs] != info.tiles.tile[rs - 2]))) {
                    st.wpp_ctx = st.ctx;
                    st.wpp_stat = st.stat;
                }
                const end = st.e.terminate() == 1;
                if (st.e.overrun()) return error.Corrupt;
                const row = rs / w;
                info.row_done[row] += 1;
                if (info.row_done[row] == w) st.on_row(st);
                ts += 1;
                if (end) {
                    if (pps.dependent_slice_segments) {
                        st.ds_ctx = st.ctx;
                        st.ds_stat = st.stat;
                    }
                    return;
                }
                if (ts >= ctbs) return error.Corrupt;
                const prev = rs;
                rs = info.tiles.ts2rs[ts];
                const tiles = info.tiles.tile;
                if ((pps.tiles and tiles[rs] != tiles[prev]) or
                    (pps.entropy_coding_sync and (rs % w == 0 or tiles[rs] != tiles[rs - 1])))
                {
                    // end_of_subset_one_bit, then the next substream.
                    if (st.e.terminate() != 1) return error.Corrupt;
                    if (!st.e.init(data, st.e.bytePosition())) return error.Corrupt;
                    info.ctb_slice[rs] = st.slice_idx;
                    _ = startContexts(st, rs, ts, false);
                    st.qp_prev = h.qp;
                }
            }
        }

        /// The contexts at the start of a substream or segment (9.3.2.1);
        /// true when a tile or a wavefront row begins.
        fn startContexts(st: *State, rs: u32, ts: u32, at_segment: bool) bool {
            const info = st.info;
            const h = st.hdr;
            const w = info.wctb;
            const tiles = info.tiles.tile;
            if (ts == 0 or tiles[rs] != tiles[info.tiles.ts2rs[ts - 1]]) {
                cabac.initContexts(&st.ctx, h.initType(), h.qp);
                st.stat = .{ 0, 0, 0, 0 };
                return true;
            }
            if (st.pps.entropy_coding_sync and (rs % w == 0 or tiles[rs] != tiles[rs - 1])) {
                const x0: u32 = (rs % w) << info.log2_ctb;
                const y0: u32 = (rs / w) << info.log2_ctb;
                const size: i32 = @as(i32, 1) << info.log2_ctb;
                if (info.available(x0, y0, @as(i32, @intCast(x0)) + size, @as(i32, @intCast(y0)) - size)) {
                    st.ctx = st.wpp_ctx;
                    st.stat = st.wpp_stat;
                } else {
                    cabac.initContexts(&st.ctx, h.initType(), h.qp);
                    st.stat = .{ 0, 0, 0, 0 };
                }
                return true;
            }
            if (at_segment and h.dependent) {
                st.ctx = st.ds_ctx;
                st.stat = st.ds_stat;
                return false;
            }
            cabac.initContexts(&st.ctx, h.initType(), h.qp);
            st.stat = .{ 0, 0, 0, 0 };
            return false;
        }

        fn ctu(st: *State, rs: u32) Error!void {
            const info = st.info;
            const rx = rs % info.wctb;
            const ry = rs / info.wctb;
            // The collocated picture's motion of this CTB row, when another
            // core decodes it.
            if (st.sync) |sy| {
                if (st.lists.col) |col| {
                    if (col != st.store) sy.rows(col, @min(st.sps.height, (ry + 1) << info.log2_ctb));
                }
            }
            if (st.hdr.sao_luma or st.hdr.sao_chroma) {
                sao(st, rs, rx, ry);
            } else info.sao[rs] = .{};
            try quadtree(st, rx << info.log2_ctb, ry << info.log2_ctb, info.log2_ctb, 0);
        }

        // --- SAO syntax --------------------------------------------------

        /// sao( rx, ry ) (7.3.8.3) into the CTB's parameters.
        fn sao(st: *State, rs: u32, rx: u32, ry: u32) void {
            const info = st.info;
            const h = st.hdr;
            const e = &st.e;
            const tiles = info.tiles.tile;
            const w = info.wctb;
            if (rx > 0 and rs > h.slice_addr and tiles[rs] == tiles[rs - 1]) {
                if (e.decision(&st.ctx[Ctx.sao_merge]) == 1) {
                    info.sao[rs] = info.sao[rs - 1];
                    return;
                }
            }
            if (ry > 0 and rs - w >= h.slice_addr and tiles[rs] == tiles[rs - w]) {
                if (e.decision(&st.ctx[Ctx.sao_merge]) == 1) {
                    info.sao[rs] = info.sao[rs - w];
                    return;
                }
            }
            var p: picture.Sao = .{};
            const sps = st.sps;
            const ncomp: usize = if (sps.chromaArrayType() != 0) 3 else 1;
            for (0..ncomp) |c| {
                if (!((h.sao_luma and c == 0) or (h.sao_chroma and c > 0))) continue;
                if (c == 2) {
                    p.kind[2] = p.kind[1];
                    p.class[2] = p.class[1];
                } else {
                    p.kind[c] = 0;
                    if (e.decision(&st.ctx[Ctx.sao_type]) == 1) p.kind[c] = if (e.bypass() == 1) 2 else 1;
                }
                if (p.kind[c] == 0) continue;
                const depth = if (c == 0) sps.bit_depth_luma else sps.bit_depth_chroma;
                const cmax: u32 = (@as(u32, 1) << (@min(depth, 10) - 5)) - 1;
                var abs: [4]i16 = undefined;
                for (&abs) |*a| {
                    var v: u32 = 0;
                    while (v < cmax and e.bypass() == 1) v += 1;
                    a.* = @intCast(v);
                }
                const scale: u4 = if (c == 0) st.pps.log2_sao_offset_scale_luma else st.pps.log2_sao_offset_scale_chroma;
                if (p.kind[c] == 1) {
                    for (&abs) |*a| {
                        if (a.* != 0 and e.bypass() == 1) a.* = -a.*;
                    }
                    p.class[c] = @intCast(e.bypassBits(5));
                } else {
                    abs[2] = -abs[2];
                    abs[3] = -abs[3];
                    if (c == 0 or c == 1) p.class[c] = @intCast(e.bypassBits(2));
                    if (c == 2) p.class[2] = p.class[1];
                }
                for (0..4) |i| p.offsets[c][i] = abs[i] << scale;
            }
            info.sao[rs] = p;
        }

        // --- coding quadtree and coding unit -----------------------------

        fn quadtree(st: *State, x0: u32, y0: u32, log2: u3, depth: u8) Error!void {
            const sps = st.sps;
            const pps = st.pps;
            const info = st.info;
            const size = @as(u32, 1) << log2;
            var split = log2 > sps.log2_min_cb;
            if (x0 + size <= sps.width and y0 + size <= sps.height and log2 > sps.log2_min_cb) {
                var inc: usize = 0;
                const xi: i32 = @intCast(x0);
                const yi: i32 = @intCast(y0);
                if (info.available(x0, y0, xi - 1, yi) and info.cu(x0 - 1, y0).depth > depth) inc += 1;
                if (info.available(x0, y0, xi, yi - 1) and info.cu(x0, y0 - 1).depth > depth) inc += 1;
                split = st.e.decision(&st.ctx[Ctx.split_cu + inc]) == 1;
            }
            if (log2 >= sps.log2_ctb - pps.diff_cu_qp_delta_depth) groupStart(st, x0, y0);
            if (st.hdr.cu_chroma_qp_offset and log2 >= sps.log2_ctb - pps.diff_cu_chroma_qp_offset_depth)
                st.chroma_offset_coded = false;
            if (split) {
                const half = size >> 1;
                const x1 = x0 + half;
                const y1 = y0 + half;
                try quadtree(st, x0, y0, log2 - 1, depth + 1);
                if (x1 < sps.width) try quadtree(st, x1, y0, log2 - 1, depth + 1);
                if (y1 < sps.height) try quadtree(st, x0, y1, log2 - 1, depth + 1);
                if (x1 < sps.width and y1 < sps.height) try quadtree(st, x1, y1, log2 - 1, depth + 1);
            } else try codingUnit(st, x0, y0, log2, depth);
        }

        /// The start of a quantization group: qPY_PRED (8.6.1).
        fn groupStart(st: *State, x0: u32, y0: u32) void {
            st.delta_coded = false;
            st.delta_val = 0;
            const info = st.info;
            const mask = (@as(u32, 1) << info.log2_ctb) - 1;
            const prev = st.qp_prev;
            const qa: i32 = if (x0 & mask != 0) info.cu(x0 - 1, y0).qp else prev;
            const qb: i32 = if (y0 & mask != 0) info.cu(x0, y0 - 1).qp else prev;
            st.qp_pred = (qa + qb + 1) >> 1;
        }

        /// QpY of a qPY_PRED and CuQpDeltaVal (8-283).
        fn lumaQp(st: *const State, delta: i32) i32 {
            const off: i32 = 6 * @as(i32, st.sps.bit_depth_luma - 8);
            return @mod(st.qp_pred + delta + 52 + 2 * off, 52 + off) - off;
        }

        fn fillCu(st: *State, x0: u32, y0: u32, n: u32, v: picture.Cu) void {
            const info = st.info;
            var y = y0;
            while (y < y0 + n) : (y += 8) {
                const row = info.cus[(y >> 3) * info.w8 + (x0 >> 3) ..][0 .. n >> 3];
                @memset(row, v);
            }
        }

        fn fillModes(st: *State, x0: u32, y0: u32, w: u32, h: u32, v: u8) void {
            const info = st.info;
            var y = y0;
            while (y < y0 + h) : (y += 4) @memset(info.modes[info.at4(x0, y)..][0 .. w >> 2], v);
        }

        fn codingUnit(st: *State, x0: u32, y0: u32, log2: u3, depth: u8) Error!void {
            const sps = st.sps;
            const pps = st.pps;
            const h = st.hdr;
            const info = st.info;
            const e = &st.e;
            const n = @as(u32, 1) << log2;
            var cu: Cu = .{ .x = x0, .y = y0, .log2 = log2, .depth = depth };
            if (pps.transquant_bypass) cu.bypass = e.decision(&st.ctx[Ctx.transquant_bypass]) == 1;
            const xi: i32 = @intCast(x0);
            const yi: i32 = @intCast(y0);
            if (h.slice_type != .i) {
                var inc: usize = 0;
                if (info.available(x0, y0, xi - 1, yi) and info.cu(x0 - 1, y0).flags & picture.cu_skip != 0) inc += 1;
                if (info.available(x0, y0, xi, yi - 1) and info.cu(x0, y0 - 1).flags & picture.cu_skip != 0) inc += 1;
                cu.skip = e.decision(&st.ctx[Ctx.cu_skip + inc]) == 1;
            }
            if (!cu.skip) {
                cu.intra = if (h.slice_type != .i) e.decision(&st.ctx[Ctx.pred_mode]) == 1 else true;
            }
            st.qp_y = lumaQp(st, st.delta_val);
            var flags: u8 = 0;
            if (cu.skip) flags |= picture.cu_skip;
            if (cu.intra) flags |= picture.cu_intra;
            if (cu.bypass) {
                flags |= picture.cu_nofilter;
                info.any_nofilter = true;
            }
            fillCu(st, x0, y0, n, .{ .depth = depth, .flags = flags, .qp = @intCast(st.qp_y) });
            fillModes(st, x0, y0, n, n, 1);
            @memset(st.edges[0..], 0);

            var has_residual = false;
            if (cu.skip) {
                try predictionUnit(st, &cu, x0, y0, n, n, 0);
            } else {
                if (!cu.intra or log2 == sps.log2_min_cb) cu.part = try partMode(st, &cu);
                if (cu.intra) {
                    cu.split = cu.part == .pNxN;
                    if (cu.part == .p2Nx2N and sps.pcm and log2 >= sps.log2_min_pcm and log2 <= sps.log2_max_pcm)
                        cu.pcm = e.terminate() == 1;
                    if (cu.pcm) {
                        if (sps.pcm_loop_filter_disabled) {
                            info.any_nofilter = true;
                            fillCu(st, x0, y0, n, .{ .depth = depth, .flags = flags | picture.cu_nofilter, .qp = @intCast(st.qp_y) });
                        }
                        try pcmSamples(st, &cu);
                    } else intraModes(st, &cu);
                } else {
                    const q = n >> 2;
                    const half = n >> 1;
                    switch (cu.part) {
                        .p2Nx2N => try predictionUnit(st, &cu, x0, y0, n, n, 0),
                        .p2NxN => {
                            try predictionUnit(st, &cu, x0, y0, n, half, 0);
                            try predictionUnit(st, &cu, x0, y0 + half, n, half, 1);
                        },
                        .pNx2N => {
                            try predictionUnit(st, &cu, x0, y0, half, n, 0);
                            try predictionUnit(st, &cu, x0 + half, y0, half, n, 1);
                        },
                        .p2NxnU => {
                            try predictionUnit(st, &cu, x0, y0, n, q, 0);
                            try predictionUnit(st, &cu, x0, y0 + q, n, n - q, 1);
                        },
                        .p2NxnD => {
                            try predictionUnit(st, &cu, x0, y0, n, n - q, 0);
                            try predictionUnit(st, &cu, x0, y0 + n - q, n, q, 1);
                        },
                        .pnLx2N => {
                            try predictionUnit(st, &cu, x0, y0, q, n, 0);
                            try predictionUnit(st, &cu, x0 + q, y0, n - q, n, 1);
                        },
                        .pnRx2N => {
                            try predictionUnit(st, &cu, x0, y0, n - q, n, 0);
                            try predictionUnit(st, &cu, x0 + n - q, y0, q, n, 1);
                        },
                        .pNxN => {
                            try predictionUnit(st, &cu, x0, y0, half, half, 0);
                            try predictionUnit(st, &cu, x0 + half, y0, half, half, 1);
                            try predictionUnit(st, &cu, x0, y0 + half, half, half, 2);
                            try predictionUnit(st, &cu, x0 + half, y0 + half, half, half, 3);
                        },
                    }
                }
                if (!cu.pcm) {
                    has_residual = true;
                    if (!cu.intra and !(cu.part == .p2Nx2N and cu.merge))
                        has_residual = e.decision(&st.ctx[Ctx.rqt_root_cbf]) == 1;
                    if (has_residual) {
                        cu.max_trafo_depth = if (cu.intra) @as(u32, sps.max_th_depth_intra) + @intFromBool(cu.split) else sps.max_th_depth_inter;
                        try transformTree(st, &cu, x0, y0, x0, y0, log2, 0, 0, 0, 0);
                    }
                }
            }
            if (!has_residual) markTu(st, &cu, x0, y0, n);
            // The coding unit's QpY, for the deblocking and the next group.
            if (st.qp_y != @as(i32, info.cu(x0, y0).qp)) {
                var v = info.cu(x0, y0).*;
                v.qp = @intCast(st.qp_y);
                fillCu(st, x0, y0, n, v);
            }
            st.qp_prev = st.qp_y;
            if (cu.intra) noMotion(st, x0, y0, n);
            if (!h.deblocking_disabled) strengths(st, &cu);
            if (e.overrun()) return error.Corrupt;
        }

        fn partMode(st: *State, cu: *const Cu) Error!Part {
            const e = &st.e;
            const c = st.ctx[Ctx.part_mode..];
            if (e.decision(&c[0]) == 1) return .p2Nx2N;
            if (cu.intra) return .pNxN;
            const sps = st.sps;
            if (cu.log2 == sps.log2_min_cb) {
                if (e.decision(&c[1]) == 1) return .p2NxN;
                if (cu.log2 == 3) return .pNx2N;
                if (e.decision(&c[2]) == 1) return .pNx2N;
                return .pNxN;
            }
            const vertical = e.decision(&c[1]) == 0;
            if (!sps.amp) return if (vertical) .pNx2N else .p2NxN;
            if (e.decision(&c[3]) == 1) return if (vertical) .pNx2N else .p2NxN;
            const second = e.bypass() == 1;
            if (vertical) return if (second) .pnRx2N else .pnLx2N;
            return if (second) .p2NxnD else .p2NxnU;
        }

        // --- intra modes -------------------------------------------------

        /// candModeList of the block at (x, y) (8.4.2).
        fn mpm(st: *State, x: u32, y: u32) [3]u8 {
            const info = st.info;
            const xi: i32 = @intCast(x);
            const yi: i32 = @intCast(y);
            var a: u8 = 1;
            if (info.available(x, y, xi - 1, yi) and info.cu(x - 1, y).flags & picture.cu_intra != 0)
                a = info.modes[info.at4(x - 1, y)] & 0x3f;
            var b: u8 = 1;
            const ctb_top = (y >> info.log2_ctb) << info.log2_ctb;
            if (y > ctb_top and info.available(x, y, xi, yi - 1) and info.cu(x, y - 1).flags & picture.cu_intra != 0)
                b = info.modes[info.at4(x, y - 1)] & 0x3f;
            if (a == b) {
                if (a < 2) return .{ 0, 1, 26 };
                return .{ a, 2 + ((a + 29) % 32), 2 + ((a - 2 + 1) % 32) };
            }
            const c: u8 = if (a != 0 and b != 0) 0 else if (a != 1 and b != 1) 1 else 26;
            return .{ a, b, c };
        }

        fn intraModes(st: *State, cu: *Cu) void {
            const e = &st.e;
            const n = @as(u32, 1) << cu.log2;
            const count: usize = if (cu.split) 4 else 1;
            const pb = if (cu.split) n >> 1 else n;
            var prev: [4]bool = undefined;
            for (0..count) |i| prev[i] = e.decision(&st.ctx[Ctx.prev_intra_luma_pred]) == 1;
            for (0..count) |i| {
                const x = cu.x + @as(u32, @intCast(i & 1)) * pb;
                const y = cu.y + @as(u32, @intCast(i >> 1)) * pb;
                var cand = mpm(st, x, y);
                var mode: u8 = undefined;
                if (prev[i]) {
                    var idx: usize = 0;
                    if (e.bypass() == 1) idx = 1 + @as(usize, e.bypass());
                    mode = cand[idx];
                } else {
                    mode = @intCast(e.bypassBits(5));
                    if (cand[0] > cand[1]) swap(&cand[0], &cand[1]);
                    if (cand[0] > cand[2]) swap(&cand[0], &cand[2]);
                    if (cand[1] > cand[2]) swap(&cand[1], &cand[2]);
                    for (cand) |m| {
                        if (mode >= m) mode += 1;
                    }
                }
                cu.luma_modes[i] = mode;
                fillModes(st, x, y, pb, pb, mode);
            }
            const cat = st.sps.chromaArrayType();
            if (cat == 3) {
                for (0..count) |i| chromaMode(st, cu, i, i);
            } else if (cat != 0) {
                chromaMode(st, cu, 0, 0);
                for (1..4) |i| {
                    cu.chroma_modes[i] = cu.chroma_modes[0];
                    cu.chroma_dm[i] = cu.chroma_dm[0];
                }
            }
        }

        fn swap(a: *u8, b: *u8) void {
            const t = a.*;
            a.* = b.*;
            b.* = t;
        }

        /// intra_chroma_pred_mode of block `i`, and IntraPredModeC from it
        /// and the luma mode of block `l` (8.4.3).
        fn chromaMode(st: *State, cu: *Cu, i: usize, l: usize) void {
            const e = &st.e;
            const luma = cu.luma_modes[l];
            var v: u32 = 4;
            if (e.decision(&st.ctx[Ctx.intra_chroma_pred_mode]) == 1) v = e.bypassBits(2);
            const fixed = [4]u8{ 0, 26, 10, 1 };
            var mode: u8 = luma;
            if (v < 4) mode = if (fixed[v] == luma) 34 else fixed[v];
            if (st.sps.chromaArrayType() == 2) mode = tables.chroma422[mode];
            cu.chroma_modes[i] = mode;
            cu.chroma_dm[i] = v == 4;
        }

        /// pcm_sample( ) (7.3.8.7), the samples put in the picture, and the
        /// arithmetic decoder started again after them.
        fn pcmSamples(st: *State, cu: *const Cu) Error!void {
            const sps = st.sps;
            const data = st.e.data;
            const at = st.e.bytePosition();
            if (at > data.len) return error.Corrupt;
            var b = bits.Bits.init(data[at..]);
            const n = @as(u32, 1) << cu.log2;
            const ncomp: usize = if (sps.chromaArrayType() != 0) 3 else 1;
            for (0..ncomp) |c| {
                const w = if (c == 0) n else n >> sps.shiftW();
                const hh = if (c == 0) n else n >> sps.shiftH();
                const x = if (c == 0) cu.x else cu.x >> sps.shiftW();
                const y = if (c == 0) cu.y else cu.y >> sps.shiftH();
                const pd: u5 = if (c == 0) sps.pcm_depth_luma else sps.pcm_depth_chroma;
                const depth: u5 = if (c == 0) sps.bit_depth_luma else sps.bit_depth_chroma;
                const stride = st.store.stride[c];
                const dst = plane(st, c) + y * stride + x;
                for (0..hh) |j| {
                    for (0..w) |i| dst[j * stride + i] = @intCast(b.u(pd) << (depth - pd));
                }
            }
            if (b.overrun()) return error.Corrupt;
            if (!st.e.init(data, at + (b.pos >> 3))) return error.Corrupt;
        }

        // --- prediction units --------------------------------------------

        fn mvContext(st: *const State) mvpred.Ctx {
            const h = st.hdr;
            return .{
                .info = st.info,
                .lists = st.lists,
                .poc = st.store.poc,
                .par_mrg = st.pps.log2_parallel_merge_level,
                .max_merge = h.max_num_merge_cand,
                .b_slice = h.slice_type == .b,
                .tmvp = h.temporal_mvp,
                .col_from_l0 = h.collocated_from_l0,
            };
        }

        fn predictionUnit(st: *State, cu: *Cu, x: u32, y: u32, w: u32, hh: u32, part_idx: u32) Error!void {
            const e = &st.e;
            const h = st.hdr;
            const pu: mvpred.Pu = .{
                .xcb = cu.x,
                .ycb = cu.y,
                .ncbs = @as(u32, 1) << cu.log2,
                .x = x,
                .y = y,
                .w = w,
                .h = hh,
                .part_idx = part_idx,
                .part = cu.part,
            };
            const mc = mvContext(st);
            var f: MvField = .{};
            var merge = cu.skip;
            if (!merge) merge = e.decision(&st.ctx[Ctx.merge_flag]) == 1;
            if (part_idx == 0) cu.merge = merge;
            if (merge) {
                var idx: u32 = 0;
                if (h.max_num_merge_cand > 1) {
                    if (e.decision(&st.ctx[Ctx.merge_idx]) == 1) {
                        idx = 1;
                        while (idx < h.max_num_merge_cand - 1 and e.bypass() == 1) idx += 1;
                    }
                }
                f = mvpred.merge(&mc, &pu, idx);
            } else {
                // inter_pred_idc: 0 L0, 1 L1, 2 both.
                var idc: u32 = 0;
                if (h.slice_type == .b) {
                    if (w + hh != 12 and e.decision(&st.ctx[Ctx.inter_pred_idc + cu.depth]) == 1) {
                        idc = 2;
                    } else idc = e.decision(&st.ctx[Ctx.inter_pred_idc + 4]);
                }
                var mvd: [2][2]i32 = .{ .{ 0, 0 }, .{ 0, 0 } };
                var flag: [2]u1 = .{ 0, 0 };
                for (0..2) |l| {
                    if (idc == 1 - l) continue;
                    var r: u32 = 0;
                    const count = h.num_ref_idx[l];
                    if (count > 1) {
                        while (r < count - 1) {
                            const bin = if (r < 2) e.decision(&st.ctx[Ctx.ref_idx + r]) else e.bypass();
                            if (bin == 0) break;
                            r += 1;
                        }
                    }
                    f.ref_idx[l] = @intCast(r);
                    if (l == 1 and h.mvd_l1_zero and idc == 2) {
                        mvd[1] = .{ 0, 0 };
                    } else mvd[l] = mvdCoding(st);
                    flag[l] = e.decision(&st.ctx[Ctx.mvp_flag]);
                }
                for (0..2) |l| {
                    if (!f.uses(l)) continue;
                    const p = mvpred.amvp(&mc, &pu, l, @intCast(f.ref_idx[l]), flag[l]);
                    for (0..2) |k| f.mv[l][k] = @truncate(@as(i32, p[k]) + mvd[l][k]);
                }
            }
            for (0..2) |l| {
                if (f.uses(l)) {
                    if (f.ref_idx[l] >= st.lists.count[l]) return error.Corrupt;
                    f.ref_id[l] = st.lists.refs[l][@intCast(f.ref_idx[l])].id;
                }
            }
            const info = st.info;
            var yy = y;
            while (yy < y + hh) : (yy += 4) @memset(info.mvf[info.at4(x, yy)..][0 .. w >> 2], f);
            storeMotion(st, f, x, y, w, hh);
            motion(st, f, x, y, w, hh);
        }

        fn mvdCoding(st: *State) [2]i32 {
            const e = &st.e;
            var g0: [2]bool = undefined;
            var g1: [2]bool = .{ false, false };
            for (0..2) |k| g0[k] = e.decision(&st.ctx[Ctx.mvd_greater0]) == 1;
            for (0..2) |k| {
                if (g0[k]) g1[k] = e.decision(&st.ctx[Ctx.mvd_greater1]) == 1;
            }
            var out: [2]i32 = .{ 0, 0 };
            for (0..2) |k| {
                if (!g0[k]) continue;
                var v: i32 = 1;
                if (g1[k]) v = 2 + @as(i32, @intCast(@min(egk(e, 1), 1 << 16)));
                out[k] = if (e.bypass() == 1) -v else v;
            }
            return out;
        }

        /// A k-th order Exp-Golomb value of bypass bins (9.3.3.3).
        fn egk(e: *cabac.Engine, k0: u32) u32 {
            var k = k0;
            var v: u32 = 0;
            while (e.bypass() == 1) {
                if (k >= 31) return v;
                v +%= @as(u32, 1) << @intCast(k);
                k += 1;
            }
            return v +% e.bypassBits(k);
        }

        /// The motion of a prediction block kept for later pictures.
        fn storeMotion(st: *State, f: MvField, x: u32, y: u32, w: u32, hh: u32) void {
            const s = st.store;
            if (s.motion.len == 0) return;
            const w16 = (s.width[0] + 15) >> 4;
            var m: common.Motion = .{};
            for (0..2) |l| {
                if (!f.uses(l)) continue;
                const r = st.lists.refs[l][@intCast(f.ref_idx[l])];
                m.mv[l] = f.mv[l];
                m.poc[l] = r.poc;
                m.flags |= @as(u8, 1) << @intCast(l);
                if (r.long) m.flags |= @as(u8, 4) << @intCast(l);
            }
            var yy = (y + 15) & ~@as(u32, 15);
            while (yy < y + hh) : (yy += 16) {
                var xx = (x + 15) & ~@as(u32, 15);
                while (xx < x + w) : (xx += 16) s.motion[(yy >> 4) * w16 + (xx >> 4)] = m;
            }
        }

        fn noMotion(st: *State, x: u32, y: u32, n: u32) void {
            const s = st.store;
            if (s.motion.len == 0) return;
            const w16 = (s.width[0] + 15) >> 4;
            var yy = (y + 15) & ~@as(u32, 15);
            while (yy < y + n) : (yy += 16) {
                var xx = (x + 15) & ~@as(u32, 15);
                while (xx < x + n) : (xx += 16) s.motion[(yy >> 4) * w16 + (xx >> 4)] = .{};
            }
        }

        /// The samples of a prediction block from its references (8.5.3.3).
        fn motion(st: *State, f: MvField, x: u32, y: u32, w: u32, hh: u32) void {
            const sps = st.sps;
            const pps = st.pps;
            const h = st.hdr;
            const weighted = if (h.slice_type == .p) pps.weighted_pred else pps.weighted_bipred;
            const ncomp: usize = if (sps.chromaArrayType() != 0) 3 else 1;
            var refs: [2]?*common.Store = .{ null, null };
            for (0..2) |l| {
                if (!f.uses(l)) continue;
                const r = st.lists.refs[l][@intCast(f.ref_idx[l])];
                // A missing reference: the picture itself, what there is of it.
                refs[l] = r.store orelse st.store;
                if (st.sync) |sy| {
                    if (refs[l] != st.store) {
                        const bottom = @as(i32, @intCast(y + hh)) + (f.mv[l][1] >> 2) + 8;
                        sy.rows(refs[l].?, @intCast(clip3(1, @intCast(sps.height), bottom)));
                    }
                }
            }
            for (0..ncomp) |c| {
                const sw: u5 = if (c == 0) 0 else sps.shiftW();
                const sh: u5 = if (c == 0) 0 else sps.shiftH();
                const bx = x >> sw;
                const by = y >> sh;
                const bw = w >> sw;
                const bh = hh >> sh;
                const depth: u5 = if (c == 0) sps.bit_depth_luma else sps.bit_depth_chroma;
                const stride = st.store.stride[c];
                const dst = plane(st, c) + by * stride + bx;
                for (0..2) |l| {
                    const s = refs[l] orelse continue;
                    const ref: inter.Plane(T) = .{
                        .data = @ptrCast(@alignCast(s.planes[c])),
                        .stride = s.stride[c],
                        .width = @intCast(st.store.width[c]),
                        .height = @intCast(st.store.height[c]),
                    };
                    const mv = f.mv[l];
                    const out: [*]i32 = &st.pred[l];
                    if (c == 0) {
                        inter.luma(T, &st.iw, ref, @as(i32, @intCast(bx)) + (mv[0] >> 2), @as(i32, @intCast(by)) + (mv[1] >> 2), @intCast(mv[0] & 3), @intCast(mv[1] & 3), bw, bh, depth, out, 64);
                    } else {
                        const mx: i32 = @divTrunc(@as(i32, mv[0]) * 2, @as(i32, 1) << sw);
                        const my: i32 = @divTrunc(@as(i32, mv[1]) * 2, @as(i32, 1) << sh);
                        inter.chroma(T, &st.iw, ref, @as(i32, @intCast(bx)) + (mx >> 3), @as(i32, @intCast(by)) + (my >> 3), @intCast(mx & 7), @intCast(my & 7), bw, bh, depth, out, 64);
                    }
                }
                const both = refs[0] != null and refs[1] != null;
                const one: usize = if (refs[0] != null) 0 else 1;
                if (!weighted) {
                    if (both) inter.putBi(T, &st.pred[0], &st.pred[1], 64, bw, bh, depth, dst, stride) else inter.putUni(T, &st.pred[one], 64, bw, bh, depth, dst, stride);
                    continue;
                }
                const wt = &h.weights;
                const shift1: u5 = if (depth >= 12) 2 else 14 - depth;
                const ws: u5 = if (sps.high_precision_offsets) 0 else depth - 8;
                var wv: [2]i32 = .{ 0, 0 };
                var ov: [2]i32 = .{ 0, 0 };
                for (0..2) |l| {
                    if (refs[l] == null) continue;
                    const r: usize = @intCast(f.ref_idx[l]);
                    if (c == 0) {
                        wv[l] = wt.luma_weight[l][r];
                        ov[l] = @as(i32, wt.luma_offset[l][r]) << ws;
                    } else {
                        wv[l] = wt.chroma_weight[l][r][c - 1];
                        ov[l] = @as(i32, wt.chroma_offset[l][r][c - 1]) << ws;
                    }
                }
                const log2wd: u5 = (if (c == 0) wt.luma_log2_denom else wt.chroma_log2_denom) + shift1;
                if (both) {
                    inter.putWeightedBi(T, &st.pred[0], &st.pred[1], 64, bw, bh, depth, wv[0], wv[1], ov[0], ov[1], log2wd, dst, stride);
                } else inter.putWeighted(T, &st.pred[one], 64, bw, bh, depth, wv[one], ov[one], log2wd, dst, stride);
            }
        }

        // --- transform tree ----------------------------------------------

        fn transformTree(st: *State, cu: *const Cu, x0: u32, y0: u32, xb: u32, yb: u32, log2: u3, depth: u32, blk: u32, pcb: u2, pcr: u2) Error!void {
            const sps = st.sps;
            const e = &st.e;
            const cat = sps.chromaArrayType();
            var split: bool = undefined;
            if (log2 <= sps.log2_max_tb and log2 > sps.log2_min_tb and depth < cu.max_trafo_depth and !(cu.split and depth == 0)) {
                split = e.decision(&st.ctx[Ctx.split_transform + 5 - @as(usize, log2)]) == 1;
            } else {
                const inter_split = sps.max_th_depth_inter == 0 and !cu.intra and cu.part != .p2Nx2N and depth == 0;
                split = log2 > sps.log2_max_tb or (cu.split and depth == 0) or inter_split;
            }
            var cb: u2 = 0;
            var cr: u2 = 0;
            if ((log2 > 2 and cat != 0) or cat == 3) {
                const second = cat == 2 and (!split or log2 == 3);
                const ci = Ctx.cbf_chroma + depth;
                if (depth == 0 or pcb != 0) {
                    cb = e.decision(&st.ctx[ci]);
                    if (second) cb |= @as(u2, e.decision(&st.ctx[ci])) << 1;
                }
                if (depth == 0 or pcr != 0) {
                    cr = e.decision(&st.ctx[ci]);
                    if (second) cr |= @as(u2, e.decision(&st.ctx[ci])) << 1;
                }
            }
            if (split) {
                const half = @as(u32, 1) << (log2 - 1);
                try transformTree(st, cu, x0, y0, x0, y0, log2 - 1, depth + 1, 0, cb, cr);
                try transformTree(st, cu, x0 + half, y0, x0, y0, log2 - 1, depth + 1, 1, cb, cr);
                try transformTree(st, cu, x0, y0 + half, x0, y0, log2 - 1, depth + 1, 2, cb, cr);
                try transformTree(st, cu, x0 + half, y0 + half, x0, y0, log2 - 1, depth + 1, 3, cb, cr);
                return;
            }
            var cbf_luma = true;
            if (cu.intra or depth != 0 or cb != 0 or cr != 0)
                cbf_luma = e.decision(&st.ctx[Ctx.cbf_luma + @as(usize, @intFromBool(depth == 0))]) == 1;
            try transformUnit(st, cu, x0, y0, xb, yb, log2, blk, cbf_luma, cb, cr, pcb, pcr);
        }

        /// The edges of a transform block marked for the deblocking.
        fn markTu(st: *State, cu: *const Cu, x0: u32, y0: u32, n: u32) void {
            const c0 = (x0 - cu.x) >> 2;
            const v0 = (y0 - cu.y) >> 2;
            const k = n >> 2;
            for (0..k) |i| {
                st.edges[(v0 + i) * 16 + c0] |= edge_tu_v;
                st.edges[v0 * 16 + c0 + i] |= edge_tu_h;
            }
        }

        /// The prediction block a transform block lies in.
        fn blockOf(cu: *const Cu, x: u32, y: u32) usize {
            if (!cu.split) return 0;
            const half = @as(u32, 1) << (cu.log2 - 1);
            return @as(usize, @intFromBool(x >= cu.x + half)) | @as(usize, @intFromBool(y >= cu.y + half)) << 1;
        }

        fn transformUnit(st: *State, cu: *const Cu, x0: u32, y0: u32, xb: u32, yb: u32, log2: u3, blk: u32, cbf_luma: bool, cb: u2, cr: u2, pcb: u2, pcr: u2) Error!void {
            const sps = st.sps;
            const pps = st.pps;
            const e = &st.e;
            const cat = sps.chromaArrayType();
            const log2c: u3 = if (cat == 3) log2 else @max(2, log2 - 1);
            const small = cat != 3 and log2 == 2;
            const ccb = if (small) pcb else cb;
            const ccr = if (small) pcr else cr;
            const cbf_chroma = cat != 0 and (ccb | ccr) != 0;
            const n = @as(u32, 1) << log2;
            markTu(st, cu, x0, y0, n);
            if (cbf_luma) {
                const info = st.info;
                var y = y0;
                while (y < y0 + n) : (y += 4) {
                    for (info.modes[info.at4(x0, y)..][0 .. n >> 2]) |*m| m.* |= 0x80;
                }
            }
            if (cbf_luma or cbf_chroma) {
                if (pps.cu_qp_delta_enabled and !st.delta_coded) {
                    var v: u32 = 0;
                    if (e.decision(&st.ctx[Ctx.cu_qp_delta_abs]) == 1) {
                        v = 1;
                        while (v < 5 and e.decision(&st.ctx[Ctx.cu_qp_delta_abs + 1]) == 1) v += 1;
                        if (v == 5) v += @min(egk(e, 0), 1 << 16);
                    }
                    var d: i32 = @intCast(v);
                    if (v != 0 and e.bypass() == 1) d = -d;
                    st.delta_coded = true;
                    st.delta_val = d;
                    st.qp_y = lumaQp(st, d);
                }
                if (cbf_chroma and !cu.bypass and st.hdr.cu_chroma_qp_offset and !st.chroma_offset_coded) {
                    var cb_off: i32 = 0;
                    var cr_off: i32 = 0;
                    if (e.decision(&st.ctx[Ctx.cu_chroma_qp_offset_flag]) == 1) {
                        var idx: u32 = 0;
                        const len = pps.chroma_qp_offset_list_len;
                        while (idx + 1 < len and e.decision(&st.ctx[Ctx.cu_chroma_qp_offset_idx]) == 1) idx += 1;
                        cb_off = pps.cb_qp_offset_list[idx];
                        cr_off = pps.cr_qp_offset_list[idx];
                    }
                    st.cu_off_cb = cb_off;
                    st.cu_off_cr = cr_off;
                    st.chroma_offset_coded = true;
                }
            }
            const pb = blockOf(cu, x0, y0);
            const luma_mode = cu.luma_modes[pb];
            if (cu.intra) predictIntra(st, cu, 0, x0, y0, log2, luma_mode);
            const ccp = pps.cross_component_prediction and cbf_luma and (!cu.intra or cu.chroma_dm[pb]);
            if (cbf_luma) try residual(st, cu, 0, x0, y0, log2, luma_mode, true, 0, ccp);
            if (cat == 0) return;
            if (!small) {
                const xc = x0 >> sps.shiftW();
                const yc = y0 >> sps.shiftH();
                const tcount: u32 = if (cat == 2) 2 else 1;
                for (1..3) |c| {
                    var scale: i32 = 0;
                    if (ccp) scale = crossComponent(st, c - 1);
                    const flags = if (c == 1) cb else cr;
                    for (0..tcount) |t| {
                        const yt = yc + (@as(u32, @intCast(t)) << log2c);
                        const mode = cu.chroma_modes[pb];
                        if (cu.intra) predictIntra(st, cu, c, xc, yt, log2c, mode);
                        const coded = (flags >> @intCast(t)) & 1 != 0;
                        if (coded or scale != 0) try residual(st, cu, c, xc, yt, log2c, mode, coded, scale, false);
                    }
                }
            } else if (blk == 3) {
                const xc = xb >> sps.shiftW();
                const yc = yb >> sps.shiftH();
                const tcount: u32 = if (cat == 2) 2 else 1;
                for (1..3) |c| {
                    const flags = if (c == 1) pcb else pcr;
                    for (0..tcount) |t| {
                        const yt = yc + (@as(u32, @intCast(t)) << 2);
                        const mode = cu.chroma_modes[0];
                        if (cu.intra) predictIntra(st, cu, c, xc, yt, 2, mode);
                        if ((flags >> @intCast(t)) & 1 != 0) try residual(st, cu, c, xc, yt, 2, mode, true, 0, false);
                    }
                }
            }
        }

        /// cross_comp_pred( ) (7.3.8.12): ResScaleVal.
        fn crossComponent(st: *State, c: usize) i32 {
            const e = &st.e;
            var v: u32 = 0;
            while (v < 4 and e.decision(&st.ctx[Ctx.log2_res_scale_abs + 4 * c + v]) == 1) v += 1;
            if (v == 0) return 0;
            const s: i32 = @as(i32, 1) << @intCast(v - 1);
            return if (e.decision(&st.ctx[Ctx.res_scale_sign + c]) == 1) -s else s;
        }

        // --- intra prediction --------------------------------------------

        /// The block of component `c` at (xt, yt) of its plane predicted by
        /// `mode` (8.4.4.2).
        fn predictIntra(st: *State, cu: *const Cu, c: usize, xt: u32, yt: u32, log2: u3, mode: u8) void {
            const sps = st.sps;
            const pps = st.pps;
            const info = st.info;
            const sw: u5 = if (c == 0) 0 else sps.shiftW();
            const sh: u5 = if (c == 0) 0 else sps.shiftH();
            const n: u32 = @as(u32, 1) << log2;
            const n2 = 2 * n;
            const depth: u5 = if (c == 0) sps.bit_depth_luma else sps.bit_depth_chroma;
            const stride = st.store.stride[c];
            const p = plane(st, c);
            const xl = xt << sw;
            const yl = yt << sh;
            const line = &st.line;
            const cip = pps.constrained_intra_pred;
            // Availability by the 4x4 luma blocks the neighbours lie in.
            const ux: u32 = @as(u32, 4) >> sw;
            const uy: u32 = @as(u32, 4) >> sh;
            const Avail = struct {
                fn f(i: *const picture.Info, cx: u32, cy: u32, nx: i32, ny: i32, need_intra: bool) bool {
                    if (!i.available(cx, cy, nx, ny)) return false;
                    return !need_intra or i.cu(@intCast(nx), @intCast(ny)).flags & picture.cu_intra != 0;
                }
            }.f;
            // The left column, from the bottom up.
            {
                const xn: i32 = (@as(i32, @intCast(xt)) - 1) << sw;
                var y: u32 = 0;
                while (y < n2) : (y += uy) {
                    const yn: i32 = @intCast((yt + y) << sh);
                    const ok = Avail(info, xl, yl, xn, yn, cip);
                    for (0..uy) |k| {
                        const yy = y + @as(u32, @intCast(k));
                        line[n2 - 1 - yy] = if (ok) p[(yt + yy) * stride + xt - 1] else intra.missing;
                    }
                }
            }
            {
                const xn: i32 = (@as(i32, @intCast(xt)) - 1) << sw;
                const yn: i32 = (@as(i32, @intCast(yt)) - 1) << sh;
                line[n2] = if (Avail(info, xl, yl, xn, yn, cip)) p[(yt - 1) * stride + xt - 1] else intra.missing;
            }
            {
                const yn: i32 = (@as(i32, @intCast(yt)) - 1) << sh;
                var x: u32 = 0;
                while (x < n2) : (x += ux) {
                    const xn: i32 = @intCast((xt + x) << sw);
                    const ok = Avail(info, xl, yl, xn, yn, cip);
                    for (0..ux) |k| {
                        const xx = x + @as(u32, @intCast(k));
                        line[n2 + 1 + xx] = if (ok) p[(yt - 1) * stride + xt + xx] else intra.missing;
                    }
                }
            }
            intra.substitute(line, log2, depth);
            if (!sps.intra_smoothing_disabled and (c == 0 or sps.chromaArrayType() == 3))
                intra.smooth(line, log2, mode, sps.strong_intra_smoothing and c == 0, depth);
            intra.predict(T, line, log2, mode, c == 0, sps.implicit_rdpcm and cu.bypass, depth, p + yt * stride + xt, stride);
        }

        // --- residuals ---------------------------------------------------

        /// A residual block of component `c` at (xt, yt) of its plane: its
        /// coefficients parsed when `coded`, scaled, transformed and added
        /// to the prediction there; `scale` the ResScaleVal of a chroma
        /// block predicted from the luma residual, `keep` to keep a luma
        /// residual for that.
        fn residual(st: *State, cu: *const Cu, c: usize, xt: u32, yt: u32, log2: u3, mode: u8, coded: bool, scale: i32, keep: bool) Error!void {
            const sps = st.sps;
            const n: usize = @as(usize, 1) << log2;
            const nn = n * n;
            const depth: u5 = if (c == 0) sps.bit_depth_luma else sps.bit_depth_chroma;
            if (coded) {
                const r = try parseResidual(st, cu, log2, c, mode);
                reconstruct(st, cu, &r, log2, c, mode, depth);
            } else @memset(st.res[0..nn], 0);
            if (keep) @memcpy(st.res_y[0..nn], st.res[0..nn]);
            if (scale != 0) {
                const dy = sps.bit_depth_luma;
                // rY << BitDepthC takes more than 32 bits at 16.
                for (st.res[0..nn], st.res_y[0..nn]) |*v, y| v.* += @intCast((scale * ((@as(i64, y) << depth) >> dy)) >> 3);
            }
            const stride = st.store.stride[c];
            const dst = plane(st, c) + yt * stride + xt;
            const max: i32 = (@as(i32, 1) << depth) - 1;
            for (0..n) |j| {
                const row = dst + j * stride;
                const rr = st.res[j * n ..][0..n];
                for (0..n) |i| row[i] = @intCast(clip3(0, max, @as(i32, row[i]) + rr[i]));
            }
        }

        /// residual_coding( ) (7.3.8.11): the coefficients into `st.coeff`.
        fn parseResidual(st: *State, cu: *const Cu, log2: u3, c: usize, mode: u8) Error!Res {
            const sps = st.sps;
            const pps = st.pps;
            const e = &st.e;
            const ctx = &st.ctx;
            const luma = c == 0;
            const chroma_inc: usize = @intFromBool(!luma);
            var r: Res = .{};
            if (pps.transform_skip and !cu.bypass and log2 <= pps.log2_max_transform_skip_size)
                r.ts = e.decision(&ctx[Ctx.transform_skip + chroma_inc]) == 1;
            if (!cu.intra and sps.explicit_rdpcm and (r.ts or cu.bypass)) {
                r.rdpcm = e.decision(&ctx[Ctx.explicit_rdpcm + chroma_inc]) == 1;
                if (r.rdpcm) r.rdpcm_dir = e.decision(&ctx[Ctx.explicit_rdpcm_dir + chroma_inc]);
            }
            // The last significant coefficient.
            const max_prefix: u32 = (@as(u32, log2) << 1) - 1;
            var off: usize = 15;
            var shift: u5 = log2 - 2;
            if (luma) {
                off = 3 * @as(usize, log2 - 2) + ((log2 - 1) >> 2);
                shift = (log2 + 1) >> 2;
            }
            var px: u32 = 0;
            while (px < max_prefix and e.decision(&ctx[Ctx.last_x_prefix + off + (px >> shift)]) == 1) px += 1;
            var py: u32 = 0;
            while (py < max_prefix and e.decision(&ctx[Ctx.last_y_prefix + off + (py >> shift)]) == 1) py += 1;
            var lx = px;
            var ly = py;
            if (px > 3) {
                const nb: u5 = @intCast((px >> 1) - 1);
                lx = ((2 + (px & 1)) << nb) + e.bypassBits(nb);
            }
            if (py > 3) {
                const nb: u5 = @intCast((py >> 1) - 1);
                ly = ((2 + (py & 1)) << nb) + e.bypassBits(nb);
            }
            var scan_idx: usize = 0;
            if (cu.intra and (log2 == 2 or (log2 == 3 and (luma or sps.chromaArrayType() == 3)))) {
                if (mode >= 6 and mode <= 14) scan_idx = 2 else if (mode >= 22 and mode <= 30) scan_idx = 1;
            }
            if (scan_idx == 2) {
                const t = lx;
                lx = ly;
                ly = t;
            }
            const sb_log2: u3 = log2 - 2;
            const side: u32 = @as(u32, 1) << sb_log2;
            const sb_scan = &tables.scan[sb_log2][scan_idx];
            const pos_scan = &tables.scan[2][scan_idx];
            const sb_key: u8 = @intCast((ly >> 2) << 4 | (lx >> 2));
            var last_sb: usize = 0;
            while (sb_scan[last_sb] != sb_key) last_sb += 1;
            const pos_key: u8 = @intCast((ly & 3) << 4 | (lx & 3));
            var last_pos: usize = 0;
            while (pos_scan[last_pos] != pos_key) last_pos += 1;

            const n: usize = @as(usize, 1) << log2;
            const ts_ctx = sps.transform_skip_context and (r.ts or cu.bypass);
            const hide_off = cu.bypass or (cu.intra and sps.implicit_rdpcm and r.ts and (mode == 10 or mode == 26)) or r.rdpcm;
            const persistent = sps.persistent_rice;
            const sb_type: usize = 2 * @as(usize, @intFromBool(luma)) + @intFromBool(r.ts or cu.bypass);
            const depth: u5 = if (luma) sps.bit_depth_luma else sps.bit_depth_chroma;
            const range: u5 = if (sps.extended_precision) @max(15, depth + 6) else 15;
            const coeff_max: i32 = (@as(i32, 1) << range) - 1;
            var csbf: u64 = 0;
            var first_set = true;
            var prev_g1: u32 = 1;
            var i: isize = @intCast(last_sb);
            while (i >= 0) : (i -= 1) {
                const key = sb_scan[@intCast(i)];
                const xs: u32 = key & 15;
                const ys: u32 = key >> 4;
                const right: u32 = if (xs + 1 < side) @intCast((csbf >> @intCast(ys * 8 + xs + 1)) & 1) else 0;
                const below: u32 = if (ys + 1 < side) @intCast((csbf >> @intCast((ys + 1) * 8 + xs)) & 1) else 0;
                var infer_dc = false;
                if (i < last_sb and i > 0) {
                    const inc: usize = @min(right + below, 1) + 2 * chroma_inc;
                    if (e.decision(&ctx[Ctx.coded_sub_block + inc]) == 0) continue;
                    infer_dc = true;
                }
                csbf |= @as(u64, 1) << @intCast(ys * 8 + xs);

                // The significance of each coefficient.
                var sig_inc: [16]u8 = undefined;
                const prev_csbf = right | below << 1;
                for (0..16) |k| {
                    const p = pos_scan[k];
                    const xp: u32 = p & 15;
                    const yp: u32 = p >> 4;
                    var s: u32 = undefined;
                    if (ts_ctx) {
                        s = if (luma) 42 else 16;
                    } else if (log2 == 2) {
                        s = tables.ctx_idx_map[(yp << 2) + xp];
                    } else if (xs == 0 and ys == 0 and xp == 0 and yp == 0) {
                        s = 0;
                    } else {
                        s = switch (prev_csbf) {
                            0 => if (xp + yp == 0) 2 else if (xp + yp < 3) 1 else 0,
                            1 => if (yp == 0) 2 else if (yp == 1) 1 else 0,
                            2 => if (xp == 0) 2 else if (xp == 1) 1 else 0,
                            else => 2,
                        };
                        if (luma) {
                            if (xs + ys > 0) s += 3;
                            s += if (log2 == 3) (if (scan_idx == 0) @as(u32, 9) else 15) else 21;
                        } else {
                            s += if (log2 == 3) @as(u32, 9) else 12;
                        }
                    }
                    sig_inc[k] = @intCast(if (luma) s else 27 + s);
                }
                var sig: u32 = 0;
                var start: isize = 15;
                if (i == last_sb) {
                    sig = @as(u32, 1) << @intCast(last_pos);
                    start = @as(isize, @intCast(last_pos)) - 1;
                }
                var k: isize = start;
                while (k >= 0) : (k -= 1) {
                    const ku: usize = @intCast(k);
                    if (k > 0 or !infer_dc) {
                        if (e.decision(&ctx[Ctx.sig_coeff + sig_inc[ku]]) == 1) {
                            sig |= @as(u32, 1) << @intCast(ku);
                            infer_dc = false;
                        }
                    } else sig |= 1;
                }
                if (sig == 0) continue;

                // The levels, in decreasing scan order.
                var order: [16]u8 = undefined;
                var nsig: usize = 0;
                var m: isize = 15;
                while (m >= 0) : (m -= 1) {
                    if ((sig >> @intCast(m)) & 1 != 0) {
                        order[nsig] = @intCast(m);
                        nsig += 1;
                    }
                }
                var set: usize = if (i == 0 or !luma) 0 else 2;
                if (!first_set and prev_g1 == 0) set += 1;
                first_set = false;
                var g1ctx: u32 = 1;
                var g1: u16 = 0;
                var first_g1: isize = -1;
                var escape = nsig > 8;
                const g1base = Ctx.greater1 + 16 * chroma_inc + set * 4;
                for (0..@min(8, nsig)) |q| {
                    if (e.decision(&ctx[g1base + @min(3, g1ctx)]) == 1) {
                        g1 |= @as(u16, 1) << @intCast(q);
                        if (first_g1 == -1) first_g1 = @intCast(q) else escape = true;
                        g1ctx = 0;
                    } else if (g1ctx > 0) g1ctx += 1;
                }
                prev_g1 = g1ctx;
                var g2: u32 = 0;
                if (first_g1 != -1) {
                    g2 = e.decision(&ctx[Ctx.greater2 + 4 * chroma_inc + set]);
                    if (g2 == 1) escape = true;
                }
                const first_sig = order[nsig - 1];
                const hidden = pps.sign_data_hiding and !hide_off and order[0] - first_sig > 3;
                if (sps.cabac_bypass_alignment and escape) e.alignBypass();
                const nsigns: u5 = @intCast(if (hidden) nsig - 1 else nsig);
                var signs: u32 = 0;
                if (nsigns > 0) signs = e.bypassBits(nsigns) << @intCast(@as(u6, 32) - nsigns);
                var first_rem = true;
                var last_abs: u32 = 0;
                var last_rice: u32 = 0;
                var sum: u32 = 0;
                for (0..nsig) |q| {
                    var base: u32 = 1;
                    if (q < 8) base += (g1 >> @intCast(q)) & 1;
                    if (q == first_g1) base += g2;
                    const threshold: u32 = if (q < 8) (if (q == first_g1) @as(u32, 3) else 2) else 1;
                    var a: u32 = base;
                    if (base == threshold) {
                        var rice: u32 = undefined;
                        if (first_rem) {
                            rice = if (persistent) st.stat[sb_type] / 4 else 0;
                        } else {
                            rice = last_rice + @intFromBool(last_abs > 3 * (@as(u32, 1) << @intCast(last_rice)));
                            if (!persistent) rice = @min(rice, 4);
                        }
                        rice = @min(rice, 24);
                        const rem = try remaining(st, rice, luma);
                        if (first_rem and persistent) {
                            const s = st.stat[sb_type];
                            if (rem >= (@as(u32, 3) << @intCast(s / 4))) {
                                st.stat[sb_type] +|= 1;
                            } else if (2 * rem < (@as(u32, 1) << @intCast(s / 4)) and s > 0) st.stat[sb_type] -= 1;
                        }
                        first_rem = false;
                        a = base +| rem;
                        last_abs = a;
                        last_rice = rice;
                    }
                    sum +%= a;
                    var level: i32 = @intCast(@min(a, @as(u32, @intCast(coeff_max))));
                    const pos = order[q];
                    if (q < nsigns) {
                        if ((signs << @intCast(q)) & 0x8000_0000 != 0) level = -level;
                    } else if (sum & 1 != 0) level = -level;
                    const p = pos_scan[pos];
                    const xc: u32 = xs * 4 + (p & 15);
                    const yc: u32 = ys * 4 + (p >> 4);
                    st.coeff[yc * n + xc] = level;
                    r.max_x = @max(r.max_x, xc);
                    r.max_y = @max(r.max_y, yc);
                }
            }
            return r;
        }

        /// coeff_abs_level_remaining (9.3.3.11) with Rice parameter `rice`.
        fn remaining(st: *State, rice: u32, luma: bool) Error!u32 {
            const e = &st.e;
            var prefix: u32 = 0;
            while (prefix < 4 and e.bypass() == 1) prefix += 1;
            if (prefix < 4) return (prefix << @intCast(rice)) + e.bypassBits(rice);
            const k = rice + 1;
            const cmax = @as(u32, 4) << @intCast(rice);
            const sps = st.sps;
            if (!sps.extended_precision) {
                var kk = k;
                var v: u32 = 0;
                while (e.bypass() == 1) {
                    if (kk >= 31) return error.Corrupt;
                    v +%= @as(u32, 1) << @intCast(kk);
                    kk += 1;
                }
                return cmax +| (v +% e.bypassBits(kk));
            }
            const depth: u32 = if (luma) sps.bit_depth_luma else sps.bit_depth_chroma;
            const range: u32 = @max(15, depth + 6);
            const max_pel = 28 - range;
            var pel: u32 = 0;
            while (pel < max_pel and e.bypass() == 1) pel += 1;
            const esc = if (pel == max_pel) range else pel + k;
            if (esc > 32) return error.Corrupt;
            const v = (((@as(u32, 1) << @intCast(pel)) - 1) << @intCast(k)) +% e.bypassBits(esc);
            return cmax +| v;
        }

        /// The residual (8.6.2) of the parsed coefficients into `st.res`,
        /// and the coefficients cleared again.
        fn reconstruct(st: *State, cu: *const Cu, r: *const Res, log2: u3, c: usize, mode: u8, depth: u5) void {
            const sps = st.sps;
            const n: usize = @as(usize, 1) << log2;
            const nn = n * n;
            const coeff = st.coeff[0..nn];
            const res = st.res[0..nn];
            const rotate = sps.transform_skip_rotation and n == 4 and cu.intra;
            if (cu.bypass) {
                for (res, 0..) |*v, k| v.* = if (rotate) coeff[nn - 1 - k] else coeff[k];
            } else {
                const range: u5 = if (sps.extended_precision) @max(15, depth + 6) else 15;
                const cmin: i32 = -(@as(i32, 1) << range);
                const cmax: i32 = (@as(i32, 1) << range) - 1;
                const qp = chromaOrLumaQp(st, c);
                const dq = transform.Dequant.init(qp, depth, log2, range, cmin, cmax);
                const flat = !sps.scaling_enabled or (r.ts and n > 4);
                const m = st.scales.of(log2, (if (cu.intra) @as(usize, 0) else 3) + c);
                for (0..r.max_y + 1) |y| {
                    for (0..r.max_x + 1) |x| {
                        const k = y * n + x;
                        if (coeff[k] != 0) coeff[k] = dq.apply(coeff[k], if (flat) 16 else m[k]);
                    }
                }
                const bd: u6 = @intCast(@max(@as(i32, 20) - depth, if (sps.extended_precision) @as(i32, 11) else 0));
                if (r.ts) {
                    const ts_shift: u6 = 5 + @as(u6, log2);
                    const rnd = @as(i64, 1) << (bd - 1);
                    for (res, 0..) |*v, k| {
                        const d: i64 = if (rotate) coeff[nn - 1 - k] else coeff[k];
                        v.* = @intCast(((d << ts_shift) + rnd) >> bd);
                    }
                } else {
                    const dst = cu.intra and n == 4 and c == 0;
                    if (range > 15) {
                        transform.inverse(i64, &st.tw, coeff, log2, dst, r.max_x, r.max_y, bd, cmin, cmax, res);
                    } else transform.inverse(i32, &st.tw, coeff, log2, dst, r.max_x, r.max_y, bd, cmin, cmax, res);
                }
            }
            // Directional residual modification (8.6.5).
            var dir: ?u1 = null;
            if (cu.intra and sps.implicit_rdpcm and (r.ts or cu.bypass) and (mode == 10 or mode == 26)) {
                dir = @intFromBool(mode == 26);
            } else if (r.rdpcm) dir = r.rdpcm_dir;
            if (dir) |d| {
                if (d == 0) {
                    for (0..n) |y| {
                        for (1..n) |x| res[y * n + x] += res[y * n + x - 1];
                    }
                } else {
                    for (1..n) |y| {
                        for (0..n) |x| res[y * n + x] += res[(y - 1) * n + x];
                    }
                }
            }
            for (0..r.max_y + 1) |y| @memset(coeff[y * n ..][0 .. r.max_x + 1], 0);
        }

        /// Qp′Y, Qp′Cb or Qp′Cr of the coding unit (8.6.1).
        fn chromaOrLumaQp(st: *const State, c: usize) i32 {
            const sps = st.sps;
            if (c == 0) return st.qp_y + 6 * @as(i32, sps.bit_depth_luma - 8);
            const off_c: i32 = 6 * @as(i32, sps.bit_depth_chroma - 8);
            const pps = st.pps;
            const h = st.hdr;
            const extra: i32 = if (c == 1) @as(i32, pps.cb_qp_offset) + h.cb_qp_offset + st.cu_off_cb else @as(i32, pps.cr_qp_offset) + h.cr_qp_offset + st.cu_off_cr;
            const qpi = clip3(-off_c, 57, st.qp_y + extra);
            const q = if (sps.chromaArrayType() == 1) tables.qpc420(qpi) else @min(qpi, 51);
            return q + off_c;
        }

        // --- deblocking strengths ----------------------------------------

        /// bS (8.7.2.4) of the edges on the 8x8 grid of a coding unit: its
        /// left and top edges where they are filtered, and the edges of its
        /// transform and prediction blocks inside it.
        fn strengths(st: *State, cu: *const Cu) void {
            const info = st.info;
            const pps = st.pps;
            const h = st.hdr;
            const n = @as(u32, 1) << cu.log2;
            const k = n >> 2;
            // Prediction block edges.
            const q = k >> 2;
            const half = k >> 1;
            switch (cu.part) {
                .p2Nx2N => {},
                .p2NxN => markH(st, k, half),
                .pNx2N => markV(st, k, half),
                .pNxN => {
                    markH(st, k, half);
                    markV(st, k, half);
                },
                .p2NxnU => markH(st, k, q),
                .p2NxnD => markH(st, k, k - q),
                .pnLx2N => markV(st, k, q),
                .pnRx2N => markV(st, k, k - q),
            }
            // Whether the coding unit's left and top edges are filtered.
            const here = info.ctbOf(cu.x, cu.y);
            var left = cu.x > 0;
            if (left and cu.x & ((@as(u32, 1) << info.log2_ctb) - 1) == 0) {
                const other = here - 1;
                if (!pps.loop_filter_across_tiles and info.tiles.tile[other] != info.tiles.tile[here]) left = false;
                if (!h.loop_filter_across_slices and !sameSlice(info, here, other)) left = false;
            }
            var top = cu.y > 0;
            if (top and cu.y & ((@as(u32, 1) << info.log2_ctb) - 1) == 0) {
                const other = here - info.wctb;
                if (!pps.loop_filter_across_tiles and info.tiles.tile[other] != info.tiles.tile[here]) top = false;
                if (!h.loop_filter_across_slices and !sameSlice(info, here, other)) top = false;
            }
            for (0..k) |v| {
                for (0..k) |u| {
                    const x = cu.x + @as(u32, @intCast(u)) * 4;
                    const y = cu.y + @as(u32, @intCast(v)) * 4;
                    const ed = st.edges[v * 16 + u];
                    var b: u8 = 0;
                    if (x & 7 == 0 and ed & (edge_tu_v | edge_pu_v) != 0 and (u != 0 or left))
                        b = strength(st, x - 1, y, x, y, ed & edge_tu_v != 0);
                    if (y & 7 == 0 and ed & (edge_tu_h | edge_pu_h) != 0 and (v != 0 or top))
                        b |= strength(st, x, y - 1, x, y, ed & edge_tu_h != 0) << 2;
                    info.bs[info.at4(x, y)] = b;
                }
            }
        }

        fn sameSlice(info: *const picture.Info, a: u32, b: u32) bool {
            const sb = info.ctb_slice[b];
            return sb != picture.Info.no_slice and info.slices[sb].addr == info.slices[info.ctb_slice[a]].addr;
        }

        fn markH(st: *State, k: u32, row: u32) void {
            for (0..k) |u| st.edges[row * 16 + u] |= edge_pu_h;
        }
        fn markV(st: *State, k: u32, col: u32) void {
            for (0..k) |v| st.edges[v * 16 + col] |= edge_pu_v;
        }

        fn strength(st: *State, xp: u32, yp: u32, xq: u32, yq: u32, tu: bool) u8 {
            const info = st.info;
            if ((info.cu(xp, yp).flags | info.cu(xq, yq).flags) & picture.cu_intra != 0) return 2;
            const ip = info.at4(xp, yp);
            const iq = info.at4(xq, yq);
            if (tu and (info.modes[ip] | info.modes[iq]) & 0x80 != 0) return 1;
            return motionStrength(info.mvf[ip], info.mvf[iq]);
        }

        fn far(a: [2]i16, b: [2]i16) bool {
            return @abs(@as(i32, a[0]) - b[0]) >= 4 or @abs(@as(i32, a[1]) - b[1]) >= 4;
        }

        fn motionStrength(p: MvField, q: MvField) u8 {
            const np = @as(u32, @intFromBool(p.uses(0))) + @intFromBool(p.uses(1));
            const nq = @as(u32, @intFromBool(q.uses(0))) + @intFromBool(q.uses(1));
            if (np != nq) return 1;
            if (np == 1) {
                const lp: usize = if (p.uses(0)) 0 else 1;
                const lq: usize = if (q.uses(0)) 0 else 1;
                if (p.ref_id[lp] != q.ref_id[lq]) return 1;
                return @intFromBool(far(p.mv[lp], q.mv[lq]));
            }
            const p0 = p.ref_id[0];
            const p1 = p.ref_id[1];
            const q0 = q.ref_id[0];
            const q1 = q.ref_id[1];
            if (!((p0 == q0 and p1 == q1) or (p0 == q1 and p1 == q0))) return 1;
            if (p0 != p1) {
                if (p0 == q0) return @intFromBool(far(p.mv[0], q.mv[0]) or far(p.mv[1], q.mv[1]));
                return @intFromBool(far(p.mv[0], q.mv[1]) or far(p.mv[1], q.mv[0]));
            }
            return @intFromBool((far(p.mv[0], q.mv[0]) or far(p.mv[1], q.mv[1])) and
                (far(p.mv[0], q.mv[1]) or far(p.mv[1], q.mv[0])));
        }
    };
}

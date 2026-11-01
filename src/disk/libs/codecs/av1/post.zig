// SPDX-License-Identifier: MIT
//! The filters after a frame is put together (7.14 to 7.17): the loop
//! filter across the transform and block edges, CDEF, the upscaling of
//! a frame coded narrower (superres) and loop restoration - each over
//! the whole frame, in the specification's order.

const common = @import("common.zig");
const tables = @import("tables.zig");
const header = @import("header.zig");
const parse = @import("parse.zig");
const Env = common.Env;
const Error = common.Error;
const Frame = common.Frame;
const Block = parse.Block;

const SGRPROJ_RST_BITS = 4;
const SGRPROJ_PRJ_BITS = 7;
const SGRPROJ_MTABLE_BITS = 20;
const SGRPROJ_RECIP_BITS = 12;
const SGRPROJ_SGR_BITS = 8;
const SUPERRES_SCALE_BITS = 14;
const SUPERRES_SCALE_MASK = (1 << SUPERRES_SCALE_BITS) - 1;
const SUPERRES_EXTRA_BITS = 8;

/// The loop restoration's pieces: at most 64 rows of a stripe by 64
/// columns, and the rows and columns around them the filters read.
const PIECE = 64;

/// Frames to filter from and into, and the loop restoration's working
/// memory.
pub const Scratch = struct {
    frames: [3]Frame = .{ .{}, .{}, .{} },
    work: ?*Work = null,

    pub fn deinit(s: *Scratch, env: Env) void {
        for (&s.frames) |*f| env.freeSlice(u8, f.memory);
        if (s.work) |w| env.destroy(Work, w);
        s.* = .{};
    }

    /// Scratch frame `i` laid out as `like`, its samples undefined.
    pub fn frameLike(s: *Scratch, env: Env, i: usize, like: *const Frame) Error!*Frame {
        const f = &s.frames[i];
        if (f.memory.len != like.memory.len) {
            env.freeSlice(u8, f.memory);
            f.memory = &.{};
            f.memory = env.slice(u8, like.memory.len) orelse return error.NoMemory;
        }
        const memory = f.memory;
        f.* = like.*;
        f.memory = memory;
        f.mvs = &.{};
        f.segs = &.{};
        for (0..3) |p| f.planes[p] = memory.ptr + (@intFromPtr(like.planes[p]) - @intFromPtr(like.memory.ptr));
        return f;
    }
};

const Work = struct {
    mid: [(PIECE + 6) * PIECE]i32,
    a: [(PIECE + 2) * (PIECE + 2)]i32,
    b: [(PIECE + 2) * (PIECE + 2)]i32,
    flt: [2][PIECE * PIECE]i32,
};

fn copyFrame(dst: *Frame, src: *const Frame) void {
    @memcpy(dst.memory, src.memory);
}

/// Filters the frame put together in `coded` into `cur` (the same frame
/// unless it is upscaled).
pub fn frame(s: *Scratch, env: Env, seq: *const header.Sequence, h: *const header.Frame, out: *const parse.Out, coded: *Frame, cur: *Frame) Error!void {
    if (s.work == null) s.work = env.create(Work) orelse return error.NoMemory;
    if (coded.alloc_bytes == 2) {
        try Filter(u16).run(s, env, seq, h, out, coded, cur);
    } else {
        try Filter(u8).run(s, env, seq, h, out, coded, cur);
    }
}

fn Filter(comptime P: type) type {
    return struct {
        const F = @This();

        seq: *const header.Sequence,
        h: *const header.Frame,
        out: *const parse.Out,
        bd: u5,
        work: *Work,

        fn run(s: *Scratch, env: Env, seq: *const header.Sequence, h: *const header.Frame, out: *const parse.Out, coded: *Frame, cur: *Frame) Error!void {
            const ft: F = .{ .seq = seq, .h = h, .out = out, .bd = @intCast(seq.bit_depth), .work = s.work.? };
            if (h.loop_filter_level[0] != 0 or h.loop_filter_level[1] != 0) ft.deblock(coded);

            // CDEF reads the deblocked frame (kept in `deb`) and leaves
            // its output in `coded`.
            var deb: *Frame = coded;
            if (h.enable_cdef) {
                deb = try s.frameLike(env, 0, coded);
                copyFrame(deb, coded);
                ft.cdef(deb, coded);
            }

            if (h.use_superres) {
                if (h.uses_lr) {
                    const up_cdef = try s.frameLike(env, 1, cur);
                    const up_deb = try s.frameLike(env, 2, cur);
                    ft.upscale(coded, up_cdef);
                    ft.upscale(deb, up_deb);
                    copyFrame(cur, up_cdef);
                    ft.restore(up_cdef, up_deb, cur);
                } else {
                    ft.upscale(coded, cur);
                }
            } else if (h.uses_lr) {
                if (deb == coded) {
                    deb = try s.frameLike(env, 0, coded);
                    copyFrame(deb, coded);
                }
                const src = try s.frameLike(env, 1, coded);
                copyFrame(src, coded);
                ft.restore(src, deb, cur);
            }
        }

        fn row(f: *const Frame, p: usize, y: usize) [*]P {
            return f.plane(P, p) + y * f.stride[p];
        }

        /// The sample `d` steps (of `step`) from `at`.
        fn off(at: [*]P, d: isize) *P {
            return if (d >= 0) &at[@intCast(d)] else &(at - @as(usize, @intCast(-d)))[0];
        }

        fn ssx(ft: *const F, p: usize) u5 {
            return if (p > 0) ft.seq.ss_x else 0;
        }

        fn ssy(ft: *const F, p: usize) u5 {
            return if (p > 0) ft.seq.ss_y else 0;
        }

        fn clip1(ft: *const F, v: i32) i32 {
            return common.clip3(0, (@as(i32, 1) << ft.bd) - 1, v);
        }

        // --- the loop filter (7.14) ---

        fn deblock(ft: *const F, f: *Frame) void {
            const h = ft.h;
            const out = ft.out;
            for (0..ft.seq.planes()) |p| {
                if (p > 0 and h.loop_filter_level[1 + p] == 0) continue;
                const row_step: u32 = @as(u32, 1) << ft.ssy(p);
                const col_step: u32 = @as(u32, 1) << ft.ssx(p);
                for (0..2) |pass| {
                    var r: u32 = 0;
                    while (r < out.mi_rows) : (r += row_step) {
                        var c: u32 = 0;
                        while (c < out.mi_cols) : (c += col_step) ft.edge(f, @intCast(p), @intCast(pass), r, c);
                    }
                }
            }
        }

        const Strength = struct { lvl: i32, limit: i32, blimit: i32, thresh: i32 };

        fn strength(ft: *const F, r: u32, c: u32, p: u32, pass: u32) Strength {
            const h = ft.h;
            const b = ft.out.block(r, c);
            const mode_type: usize = if (b.y_mode >= common.NEARESTMV and b.y_mode != common.GLOBALMV and b.y_mode != common.GLOBAL_GLOBALMV) 1 else 0;
            const i: usize = if (p == 0) pass else p + 1;
            const delta: i32 = if (h.delta_lf_multi) b.delta_lf[i] else b.delta_lf[0];
            var lvl = common.clip3(0, common.MAX_LOOP_FILTER, delta + h.loop_filter_level[i]);
            const feature = common.SEG_LVL_ALT_LF_Y_V + i;
            if (h.featureActive(b.segment, feature)) {
                lvl = common.clip3(0, common.MAX_LOOP_FILTER, lvl + h.feature_data[b.segment][feature]);
            }
            if (h.loop_filter_delta_enabled) {
                const n: u5 = @intCast(lvl >> 5);
                const ref = b.ref[0];
                if (ref == common.INTRA_FRAME) {
                    lvl += @as(i32, h.loop_filter_ref_deltas[0]) << n;
                } else {
                    lvl += (@as(i32, h.loop_filter_ref_deltas[@intCast(ref)]) << n) + (@as(i32, h.loop_filter_mode_deltas[mode_type]) << n);
                }
                lvl = common.clip3(0, common.MAX_LOOP_FILTER, lvl);
            }
            const sharp = h.loop_filter_sharpness;
            const shift: u5 = if (sharp > 4) 2 else if (sharp > 0) 1 else 0;
            const limit = if (sharp > 0) common.clip3(1, 9 - @as(i32, sharp), lvl >> shift) else @max(1, lvl >> shift);
            return .{ .lvl = lvl, .limit = limit, .blimit = 2 * (lvl + 2) + limit, .thresh = lvl >> 4 };
        }

        fn edge(ft: *const F, f: *Frame, p: u32, pass: u32, r0: u32, c0: u32) void {
            const h = ft.h;
            const out = ft.out;
            const sx = ft.ssx(p);
            const sy = ft.ssy(p);
            const x = c0 * 4;
            const y = r0 * 4;
            const r = r0 | sy;
            const c = c0 | sx;
            if (x >= h.frame_width or y >= h.frame_height) return;
            if (pass == 0 and x == 0) return;
            if (pass == 1 and y == 0) return;
            const xp = x >> sx;
            const yp = y >> sy;
            const prev_r = if (pass == 1) r - (@as(u32, 1) << sy) else r;
            const prev_c = if (pass == 0) c - (@as(u32, 1) << sx) else c;
            const b = out.block(r, c);
            const lf = out.lf_tx[p];
            const tx = lf[(r >> sy) * out.mi_cols + (c >> sx)];
            const psz = tables.subsampled_size[b.size][sx][sy];
            const is_intra = b.ref[0] <= common.INTRA_FRAME;
            const prev_tx = lf[(prev_r >> sy) * out.mi_cols + (prev_c >> sx)];
            const block_edge = if (pass == 0) xp % parse.blockWidth(psz) == 0 else yp % parse.blockHeight(psz) == 0;
            const tx_edge = if (pass == 0) xp % tables.tx_width[tx] == 0 else yp % tables.tx_height[tx] == 0;
            if (!tx_edge) return;
            if (!(block_edge or !b.skip or is_intra)) return;
            const base: u32 = if (pass == 0) @min(tables.tx_width[prev_tx], tables.tx_width[tx]) else @min(tables.tx_height[prev_tx], tables.tx_height[tx]);
            const size: u32 = if (p == 0) @min(16, base) else @min(8, base);
            var st = ft.strength(r, c, p, pass);
            if (st.lvl == 0) st = ft.strength(prev_r, prev_c, p, pass);
            if (st.lvl == 0) return;
            const dx: i32 = if (pass == 0) 1 else 0;
            for (0..4) |i| {
                const ii: u32 = @intCast(i);
                ft.sample(f, p, if (pass == 1) xp + ii else xp, if (pass == 0) yp + ii else yp, st, dx, size);
            }
        }

        fn sample(ft: *const F, f: *Frame, p: u32, x: u32, y: u32, st: Strength, dx: i32, size: u32) void {
            // The samples across the edge: q[ k ] at k, p[ k ] at -1 - k.
            const stride: isize = @intCast(f.stride[p]);
            const step: isize = if (dx == 1) 1 else stride;
            const at: [*]P = row(f, p, y) + x;
            const n: usize = if (size == 16) 7 else 4;
            var q: [7]i32 = undefined;
            var pp: [7]i32 = undefined;
            for (0..n) |k| {
                const kk: isize = @intCast(k);
                q[k] = off(at, kk * step).*;
                pp[k] = off(at, -(kk + 1) * step).*;
            }
            const shift: u5 = ft.bd - 8;
            const one = @as(i32, 1) << shift;
            const hev = @abs(pp[1] - pp[0]) > st.thresh << shift or @abs(q[1] - q[0]) > st.thresh << shift;
            const len: u32 = if (size == 4) 4 else if (p != 0) 6 else if (size == 8) 8 else 16;
            const limit = st.limit << shift;
            const blimit = st.blimit << shift;
            var mask = @abs(pp[1] - pp[0]) > limit or @abs(q[1] - q[0]) > limit or
                @abs(pp[0] - q[0]) * 2 + @abs(pp[1] - q[1]) / 2 > blimit;
            if (len >= 6) mask = mask or @abs(pp[2] - pp[1]) > limit or @abs(q[2] - q[1]) > limit;
            if (len >= 8) mask = mask or @abs(pp[3] - pp[2]) > limit or @abs(q[3] - q[2]) > limit;
            if (mask) return;
            var flat = false;
            if (size >= 8) {
                var m = @abs(pp[1] - pp[0]) > one or @abs(q[1] - q[0]) > one or @abs(pp[2] - pp[0]) > one or @abs(q[2] - q[0]) > one;
                if (len >= 8) m = m or @abs(pp[3] - pp[0]) > one or @abs(q[3] - q[0]) > one;
                flat = !m;
            }
            var flat2 = false;
            if (size >= 16) {
                const m = @abs(pp[6] - pp[0]) > one or @abs(q[6] - q[0]) > one or @abs(pp[5] - pp[0]) > one or
                    @abs(q[5] - q[0]) > one or @abs(pp[4] - pp[0]) > one or @abs(q[4] - q[0]) > one;
                flat2 = !m;
            }
            if (size == 4 or !flat) {
                ft.narrow(at, step, hev);
            } else if (size == 8 or !flat2) {
                wide(at, step, p, 3);
            } else {
                wide(at, step, p, 4);
            }
        }

        fn narrow(ft: *const F, at: [*]P, step: isize, hev: bool) void {
            const half = @as(i32, 0x80) << (ft.bd - 8);
            const lo = -(@as(i32, 1) << (ft.bd - 1));
            const hi = (@as(i32, 1) << (ft.bd - 1)) - 1;
            const ps1 = @as(i32, off(at, -2 * step).*) - half;
            const ps0 = @as(i32, off(at, -step).*) - half;
            const qs0 = @as(i32, at[0]) - half;
            const qs1 = @as(i32, off(at, step).*) - half;
            var filter: i32 = if (hev) common.clip3(lo, hi, ps1 - qs1) else 0;
            filter = common.clip3(lo, hi, filter + 3 * (qs0 - ps0));
            const filter1 = common.clip3(lo, hi, filter + 4) >> 3;
            const filter2 = common.clip3(lo, hi, filter + 3) >> 3;
            at[0] = @intCast(common.clip3(lo, hi, qs0 - filter1) + half);
            off(at, -step).* = @intCast(common.clip3(lo, hi, ps0 + filter2) + half);
            if (!hev) {
                const f = common.round2(filter1, 1);
                off(at, step).* = @intCast(common.clip3(lo, hi, qs1 - f) + half);
                off(at, -2 * step).* = @intCast(common.clip3(lo, hi, ps1 + f) + half);
            }
        }

        fn wide(at: [*]P, step: isize, p: u32, log2: u5) void {
            const n: i32 = if (log2 == 4) 6 else if (p == 0) 3 else 2;
            const n2: i32 = if (log2 == 3 and p == 0) 0 else 1;
            var v: [14]i32 = undefined;
            var k: i32 = -(n + 1);
            while (k <= n) : (k += 1) v[@intCast(k + 7)] = off(at, k * step).*;
            var fo: [12]i32 = undefined;
            var i: i32 = -n;
            while (i < n) : (i += 1) {
                var t: i32 = 0;
                var j: i32 = -n;
                while (j <= n) : (j += 1) {
                    const pos = common.clip3(-(n + 1), n, i + j);
                    const tap: i32 = if (@abs(j) <= n2) 2 else 1;
                    t += v[@intCast(pos + 7)] * tap;
                }
                fo[@intCast(i + 6)] = common.round2(t, log2);
            }
            i = -n;
            while (i < n) : (i += 1) off(at, i * step).* = @intCast(fo[@intCast(i + 6)]);
        }

        // --- CDEF (7.15) ---

        /// CDEF from the deblocked `src` into `dst` (a copy of it).
        fn cdef(ft: *const F, src: *const Frame, dst: *Frame) void {
            const out = ft.out;
            var r: u32 = 0;
            while (r < out.mi_rows) : (r += 2) {
                var c: u32 = 0;
                while (c < out.mi_cols) : (c += 2) {
                    const idx = out.cdef_idx[(r >> 4) * out.cdef_stride + (c >> 4)];
                    if (idx == -1) continue;
                    ft.cdefBlock(src, dst, r, c, @intCast(idx));
                }
            }
        }

        fn cdefBlock(ft: *const F, src: *const Frame, dst: *Frame, r: u32, c: u32, idx: usize) void {
            const h = ft.h;
            const out = ft.out;
            const skip = out.block(r, c).skip and out.block(r + 1, c).skip and out.block(r, c + 1).skip and out.block(r + 1, c + 1).skip;
            if (skip) return;
            const shift: u5 = ft.bd - 8;
            var var_: i32 = 0;
            const y_dir = ft.direction(src, r, c, &var_);
            var pri: i32 = @as(i32, h.cdef_y_pri_strength[idx]) << shift;
            const sec: i32 = @as(i32, h.cdef_y_sec_strength[idx]) << shift;
            var dir: usize = if (pri == 0) 0 else y_dir;
            const var_str: i32 = if ((var_ >> 6) != 0) @min(common.floorLog2(@intCast(var_ >> 6)), 12) else 0;
            pri = if (var_ != 0) (pri * (4 + var_str) + 8) >> 4 else 0;
            const damping: i32 = @as(i32, h.cdef_damping) + shift;
            ft.cdefFilter(src, dst, 0, r, c, pri, sec, damping, dir);
            if (ft.seq.planes() == 1) return;
            pri = @as(i32, h.cdef_uv_pri_strength[idx]) << shift;
            const sec_uv: i32 = @as(i32, h.cdef_uv_sec_strength[idx]) << shift;
            dir = if (pri == 0) 0 else tables.cdef_uv_dir[ft.seq.ss_x][ft.seq.ss_y][y_dir];
            ft.cdefFilter(src, dst, 1, r, c, pri, sec_uv, damping - 1, dir);
            ft.cdefFilter(src, dst, 2, r, c, pri, sec_uv, damping - 1, dir);
        }

        fn direction(ft: *const F, src: *const Frame, r: u32, c: u32, var_: *i32) usize {
            var cost: [8]i32 = @splat(0);
            var partial: [8][15]i32 = @splat(@splat(0));
            const x0 = c * 4;
            const y0 = r * 4;
            for (0..8) |i| {
                const line = row(src, 0, y0 + i) + x0;
                for (0..8) |j| {
                    const x = (@as(i32, line[j]) >> (ft.bd - 8)) - 128;
                    partial[0][i + j] += x;
                    partial[1][i + j / 2] += x;
                    partial[2][i] += x;
                    partial[3][3 + i - j / 2] += x;
                    partial[4][7 + i - j] += x;
                    partial[5][3 - i / 2 + j] += x;
                    partial[6][j] += x;
                    partial[7][i / 2 + j] += x;
                }
            }
            const dt = &tables.div_table;
            for (0..8) |i| {
                cost[2] += partial[2][i] * partial[2][i];
                cost[6] += partial[6][i] * partial[6][i];
            }
            cost[2] *= dt[8];
            cost[6] *= dt[8];
            for (0..7) |i| {
                cost[0] += (partial[0][i] * partial[0][i] + partial[0][14 - i] * partial[0][14 - i]) * dt[i + 1];
                cost[4] += (partial[4][i] * partial[4][i] + partial[4][14 - i] * partial[4][14 - i]) * dt[i + 1];
            }
            cost[0] += partial[0][7] * partial[0][7] * dt[8];
            cost[4] += partial[4][7] * partial[4][7] * dt[8];
            var i: usize = 1;
            while (i < 8) : (i += 2) {
                for (0..5) |j| cost[i] += partial[i][3 + j] * partial[i][3 + j];
                cost[i] *= dt[8];
                for (0..3) |j| cost[i] += (partial[i][j] * partial[i][j] + partial[i][10 - j] * partial[i][10 - j]) * dt[2 * j + 2];
            }
            var best: i32 = 0;
            var y_dir: usize = 0;
            for (0..8) |k| {
                if (cost[k] > best) {
                    best = cost[k];
                    y_dir = k;
                }
            }
            var_.* = (best - cost[(y_dir + 4) & 7]) >> 10;
            return y_dir;
        }

        fn constrain(diff: i32, threshold: i32, damping: i32) i32 {
            if (threshold == 0) return 0;
            const adj: u5 = @intCast(@max(0, damping - common.floorLog2(@intCast(threshold))));
            const mag: i32 = @intCast(@abs(diff));
            const v = common.clip3(0, mag, threshold - (mag >> adj));
            return if (diff < 0) -v else v;
        }

        fn cdefFilter(ft: *const F, src: *const Frame, dst: *Frame, p: u32, r: u32, c: u32, pri: i32, sec: i32, damping: i32, dir: usize) void {
            const out = ft.out;
            const sx = ft.ssx(p);
            const sy = ft.ssy(p);
            const shift: u5 = ft.bd - 8;
            const x0 = (c * 4) >> sx;
            const y0 = (r * 4) >> sy;
            const w = @as(u32, 8) >> sx;
            const hh = @as(u32, 8) >> sy;
            const ti: usize = @intCast((pri >> shift) & 1);
            const max_y: i32 = @intCast(out.mi_rows);
            const max_x: i32 = @intCast(out.mi_cols);
            for (0..hh) |i| {
                const o = row(dst, p, y0 + i) + x0;
                for (0..w) |j| {
                    var sum: i32 = 0;
                    const x: i32 = row(src, p, y0 + i)[x0 + j];
                    var mx = x;
                    var mn = x;
                    for (0..2) |k| {
                        var sign: i32 = -1;
                        while (sign <= 1) : (sign += 2) {
                            const dirs = [3]usize{ dir, (dir + 6) & 7, (dir + 2) & 7 };
                            for (dirs, 0..) |d, which| {
                                const yy = @as(i32, @intCast(y0 + i)) + sign * tables.cdef_directions[d][k][0];
                                const xx = @as(i32, @intCast(x0 + j)) + sign * tables.cdef_directions[d][k][1];
                                const cr = (yy << sy) >> 2;
                                const cc = (xx << sx) >> 2;
                                if (cr < 0 or cr >= max_y or cc < 0 or cc >= max_x) continue;
                                const v: i32 = row(src, p, @intCast(yy))[@intCast(xx)];
                                if (which == 0) {
                                    sum += @as(i32, tables.cdef_pri_taps[ti][k]) * constrain(v - x, pri, damping);
                                } else {
                                    sum += @as(i32, tables.cdef_sec_taps[ti][k]) * constrain(v - x, sec, damping);
                                }
                                mx = @max(v, mx);
                                mn = @min(v, mn);
                            }
                        }
                    }
                    o[j] = @intCast(common.clip3(mn, mx, x + ((8 + sum - @as(i32, @intFromBool(sum < 0))) >> 4)));
                }
            }
        }

        // --- the upscaling (7.16) ---

        fn upscale(ft: *const F, src: *const Frame, dst: *Frame) void {
            const h = ft.h;
            for (0..ft.seq.planes()) |p| {
                const sx = ft.ssx(p);
                const sy = ft.ssy(p);
                const down_w: i64 = common.round2(@intCast(h.frame_width), sx);
                const up_w: i64 = common.round2(@intCast(h.upscaled_width), sx);
                const plane_h: u32 = @intCast(common.round2(@intCast(h.frame_height), sy));
                const step = @divTrunc((down_w << SUPERRES_SCALE_BITS) + @divTrunc(up_w, 2), up_w);
                const err = up_w * step - (down_w << SUPERRES_SCALE_BITS);
                var initial = @divTrunc(-((up_w - down_w) << (SUPERRES_SCALE_BITS - 1)) + @divTrunc(up_w, 2), up_w) +
                    (1 << (SUPERRES_EXTRA_BITS - 1)) - @divTrunc(err, 2);
                initial &= SUPERRES_SCALE_MASK;
                const max_x: i64 = @as(i64, ft.out.mi_cols >> sx) * 4 - 1;
                for (0..plane_h) |y| {
                    const in = row(src, p, y);
                    const o = row(dst, p, y);
                    for (0..@intCast(up_w)) |x| {
                        const src_x = -(@as(i64, 1) << SUPERRES_SCALE_BITS) + initial + @as(i64, @intCast(x)) * step;
                        const px = src_x >> SUPERRES_SCALE_BITS;
                        const sub: usize = @intCast((src_x & SUPERRES_SCALE_MASK) >> SUPERRES_EXTRA_BITS);
                        var sum: i32 = 0;
                        for (0..8) |k| {
                            const at = @max(0, @min(max_x, px + @as(i64, @intCast(k)) - 3));
                            sum += @as(i32, in[@intCast(at)]) * tables.upscale_filter[sub][k];
                        }
                        o[x] = @intCast(ft.clip1(common.round2(sum, 7)));
                    }
                }
            }
        }

        // --- loop restoration (7.17) ---

        const Area = struct {
            p: u32,
            /// The stripe's first and last rows, and the plane's last
            /// column and row.
            stripe_start: i32,
            stripe_end: i32,
            end_x: i32,
            end_y: i32,
            cdef: *const Frame,
            deb: *const Frame,

            fn get(a: *const Area, x0: i32, y0: i32) i32 {
                const x: usize = @intCast(@max(0, @min(a.end_x, x0)));
                var y: i32 = @max(0, @min(a.end_y, y0));
                if (y < a.stripe_start) {
                    y = @max(a.stripe_start - 2, y);
                    return row(a.deb, a.p, @intCast(y))[x];
                } else if (y > a.stripe_end) {
                    y = @min(a.stripe_end + 2, y);
                    return row(a.deb, a.p, @intCast(y))[x];
                }
                return row(a.cdef, a.p, @intCast(y))[x];
            }
        };

        /// Loop restoration from the upscaled CDEF output `src` (and the
        /// deblocked frame `deb` beyond each stripe) into `dst` (a copy
        /// of `src`), stripe by stripe, a unit's piece at a time.
        fn restore(ft: *const F, src: *const Frame, deb: *const Frame, dst: *Frame) void {
            const h = ft.h;
            for (0..ft.seq.planes()) |pu| {
                const p: u32 = @intCast(pu);
                if (h.frame_restoration_type[p] == common.RESTORE_NONE) continue;
                const sx = ft.ssx(p);
                const sy = ft.ssy(p);
                const lr = &ft.out.lr[p];
                const unit = lr.unit_size;
                const end_x: i32 = common.round2(@intCast(h.upscaled_width), sx) - 1;
                const end_y: i32 = common.round2(@intCast(h.frame_height), sy) - 1;
                var stripe: i32 = 0;
                while (true) : (stripe += 1) {
                    // The luma rows of the stripe, and its rows in the plane.
                    const luma_top = @max(0, stripe * 64 - 8);
                    if (luma_top >= h.frame_height) break;
                    const luma_bottom = @min(@as(i32, @intCast(h.frame_height)), stripe * 64 + 56);
                    const start = (-8 + stripe * 64) >> sy;
                    const area: Area = .{
                        .p = p,
                        .stripe_start = start,
                        .stripe_end = start + (@as(i32, 64) >> sy) - 1,
                        .end_x = end_x,
                        .end_y = end_y,
                        .cdef = src,
                        .deb = deb,
                    };
                    const y0 = luma_top >> sy;
                    // The plane's rows of the stripe's last 4x4 row.
                    const last = ((luma_bottom - 1) & ~@as(i32, 3)) >> sy;
                    const y1 = @min(end_y, last + (@as(i32, 4) >> sy) - 1);
                    const unit_row = @min(lr.rows - 1, @as(u32, @intCast((luma_top + 8) >> sy)) / unit);
                    for (0..lr.cols) |uc| {
                        const x_start: i32 = @intCast(uc * unit);
                        const x_end: i32 = if (uc == lr.cols - 1) end_x else @min(end_x, @as(i32, @intCast((uc + 1) * unit)) - 1);
                        const at = unit_row * lr.cols + @as(u32, @intCast(uc));
                        const kind = lr.kind[at];
                        if (kind == common.RESTORE_NONE) continue;
                        var x = x_start;
                        while (x <= x_end) : (x += PIECE) {
                            const w: u32 = @intCast(@min(PIECE, x_end - x + 1));
                            const hh: u32 = @intCast(y1 - y0 + 1);
                            if (kind == common.RESTORE_WIENER) {
                                ft.wiener(&area, &lr.wiener[at], x, y0, w, hh, dst);
                            } else {
                                ft.selfGuided(&area, lr.sgr_set[at], lr.sgr_xqd[at], x, y0, w, hh, dst);
                            }
                        }
                    }
                }
            }
        }

        fn wiener(ft: *const F, a: *const Area, coeffs: *const [2][3]i8, x: i32, y: i32, w: u32, h: u32, dst: *Frame) void {
            const r0: u5 = if (ft.bd == 12) 5 else 3;
            const r1: u5 = if (ft.bd == 12) 9 else 11;
            var vf: [7]i32 = undefined;
            var hf: [7]i32 = undefined;
            coefficients(&coeffs[0], &vf);
            coefficients(&coeffs[1], &hf);
            const offset = @as(i32, 1) << (ft.bd + 7 - r0 - 1);
            const limit = (@as(i32, 1) << (ft.bd + 1 + 7 - r0)) - 1;
            const mid = &ft.work.mid;
            for (0..h + 6) |r| {
                for (0..w) |c| {
                    var s: i32 = 0;
                    for (0..7) |t| s += hf[t] * a.get(x + @as(i32, @intCast(c + t)) - 3, y + @as(i32, @intCast(r)) - 3);
                    mid[r * w + c] = common.clip3(-offset, limit - offset, common.round2(s, r0));
                }
            }
            for (0..h) |r| {
                const o = row(dst, a.p, @as(usize, @intCast(y)) + r) + @as(usize, @intCast(x));
                for (0..w) |c| {
                    var s: i32 = 0;
                    for (0..7) |t| s += vf[t] * mid[(r + t) * w + c];
                    o[c] = @intCast(ft.clip1(common.round2(s, r1)));
                }
            }
        }

        fn coefficients(c: *const [3]i8, f: *[7]i32) void {
            f[3] = 128;
            for (0..3) |i| {
                f[i] = c[i];
                f[6 - i] = c[i];
                f[3] -= 2 * @as(i32, c[i]);
            }
        }

        fn selfGuided(ft: *const F, a: *const Area, set: u8, xqd: [2]i8, x: i32, y: i32, w: u32, h: u32, dst: *Frame) void {
            const params = &tables.sgr_params[set];
            ft.boxFilter(a, x, y, w, h, set, 0, &ft.work.flt[0]);
            ft.boxFilter(a, x, y, w, h, set, 1, &ft.work.flt[1]);
            const w0: i32 = xqd[0];
            const w1: i32 = xqd[1];
            const w2 = (1 << SGRPROJ_PRJ_BITS) - w0 - w1;
            for (0..h) |i| {
                const yy = @as(usize, @intCast(y)) + i;
                const in = row(a.cdef, a.p, yy) + @as(usize, @intCast(x));
                const o = row(dst, a.p, yy) + @as(usize, @intCast(x));
                for (0..w) |j| {
                    const u = @as(i32, in[j]) << SGRPROJ_RST_BITS;
                    var v = w1 * u;
                    v += if (params[0] != 0) w0 * ft.work.flt[0][i * w + j] else w0 * u;
                    v += if (params[2] != 0) w2 * ft.work.flt[1][i * w + j] else w2 * u;
                    o[j] = @intCast(ft.clip1(common.round2(v, SGRPROJ_RST_BITS + SGRPROJ_PRJ_BITS)));
                }
            }
        }

        fn boxFilter(ft: *const F, a: *const Area, x: i32, y: i32, w: u32, h: u32, set: u8, pass: u32, out: *[PIECE * PIECE]i32) void {
            const r: i32 = tables.sgr_params[set][pass * 2];
            if (r == 0) return;
            const eps: u32 = tables.sgr_params[set][pass * 2 + 1];
            const aa = &ft.work.a;
            const bb = &ft.work.b;
            const stride = w + 2;
            const n: u32 = @intCast((2 * r + 1) * (2 * r + 1));
            const n2e = n * n * eps;
            const s: u32 = ((1 << SGRPROJ_MTABLE_BITS) + n2e / 2) / n2e;
            const one_over_n: u32 = ((1 << SGRPROJ_RECIP_BITS) + n / 2) / n;
            const shift: u5 = ft.bd - 8;
            for (0..h + 2) |iu| {
                const i = @as(i32, @intCast(iu)) - 1;
                for (0..w + 2) |ju| {
                    const j = @as(i32, @intCast(ju)) - 1;
                    var sa: u32 = 0;
                    var sb: u32 = 0;
                    var dy = -r;
                    while (dy <= r) : (dy += 1) {
                        var dx = -r;
                        while (dx <= r) : (dx += 1) {
                            const c: u32 = @intCast(a.get(x + j + dx, y + i + dy));
                            sa += c * c;
                            sb += c;
                        }
                    }
                    const av: u32 = @intCast(common.round2_64(sa, 2 * shift));
                    const d: u32 = @intCast(common.round2_64(sb, shift));
                    const pv: u32 = if (av * n > d * d) av * n - d * d else 0;
                    const z: u32 = @intCast(common.round2_64(@as(i64, pv) * s, SGRPROJ_MTABLE_BITS));
                    const a2: u32 = if (z >= 255) 256 else if (z == 0) 1 else ((z << SGRPROJ_SGR_BITS) + z / 2) / (z + 1);
                    const b2: u64 = @as(u64, (1 << SGRPROJ_SGR_BITS) - a2) * sb * one_over_n;
                    aa[iu * stride + ju] = @intCast(a2);
                    bb[iu * stride + ju] = @intCast(common.round2_64(@intCast(b2), SGRPROJ_RECIP_BITS));
                }
            }
            for (0..h) |i| {
                const shift_ = if (pass == 0 and i & 1 == 1) @as(u5, 4) else 5;
                const in = row(a.cdef, a.p, @as(usize, @intCast(y)) + i) + @as(usize, @intCast(x));
                for (0..w) |j| {
                    var sa: i32 = 0;
                    var sb: i32 = 0;
                    for (0..3) |dyu| {
                        for (0..3) |dxu| {
                            const weight: i32 = if (pass == 0)
                                (if ((i + dyu + 1) & 1 == 1) (if (dxu == 1) @as(i32, 6) else 5) else 0)
                            else if (dxu == 1 or dyu == 1) 4 else 3;
                            const at = (i + dyu) * stride + j + dxu;
                            sa += weight * aa[at];
                            sb += weight * bb[at];
                        }
                    }
                    const v = sa * @as(i32, in[j]) + sb;
                    out[i * w + j] = common.round2(v, SGRPROJ_SGR_BITS + shift_ - SGRPROJ_RST_BITS);
                }
            }
        }
    };
}

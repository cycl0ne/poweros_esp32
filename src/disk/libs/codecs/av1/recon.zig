// SPDX-License-Identifier: MIT
//! Putting a frame together (7.11 to 7.13): each block predicted - from
//! the samples around it, its palette, or the references - and its
//! transform blocks' residuals added, superblock by superblock, a row of
//! superblocks at a time. References still being decoded on other cores
//! are waited for, before each read, as far down as the read reaches.

const common = @import("common.zig");
const tables = @import("tables.zig");
const header = @import("header.zig");
const parse = @import("parse.zig");
const warp = @import("warp.zig");
const itx = @import("itx.zig");
const Env = common.Env;
const Error = common.Error;
const Frame = common.Frame;
const Block = parse.Block;
const Txb = parse.Txb;
const Mv = common.Mv;
const Cores = common.Cores;

/// Who waits for the lines of the references: the cores, and which of
/// them it is.
pub const Wait = struct { cores: *const Cores, who: u32 };

const MAX_SB = 128;
/// The edges' arrays start at -16 (AboveRow[ -2 ] and on), and run to
/// 2 * (w + h) and a little after for the directional modes.
const EDGE_OFF = 16;
const EDGE_LEN = EDGE_OFF + 2 * MAX_SB + 64;

const WEDGE_HORIZONTAL = 0;
const WEDGE_VERTICAL = 1;
const WEDGE_OBLIQUE27 = 2;
const WEDGE_OBLIQUE63 = 3;
const WEDGE_OBLIQUE117 = 4;
const WEDGE_OBLIQUE153 = 5;

/// The working memory of putting a block together.
const Work = struct {
    res: [64 * 64]i32,
    pred: [64 * 64]i32,
    above: [EDGE_LEN]i32,
    left: [EDGE_LEN]i32,
    preds: [2][MAX_SB * MAX_SB]i32,
    /// At the stride MAX_SB; kept from the brightness for the colours.
    mask: [MAX_SB * MAX_SB]u8,
    obmc: [64 * 64]i32,
    /// The horizontal filter's output: up to twice the block's height
    /// (a reference twice the size) and the taps.
    mid: [(2 * MAX_SB + 8) * MAX_SB]i32,
    /// A block's reach of a reference at its edge, the edge repeated:
    /// the block and the taps around it, of 8 or 16-bit samples.
    edge: [(MAX_SB + 7) * (MAX_SB + 7)]u16,
};

pub const Recon = struct {
    work: ?*Work = null,
    /// The wedges' master masks (initialise_wedge_mask_table).
    master: ?*[6][64][64]u8 = null,

    pub fn deinit(rc: *Recon, env: Env) void {
        if (rc.work) |w| env.destroy(Work, w);
        if (rc.master) |m| env.destroy([6][64][64]u8, m);
        rc.* = .{};
    }

    /// The working memory made, before the first row.
    pub fn prepare(rc: *Recon, env: Env) Error!void {
        if (rc.work == null) rc.work = env.create(Work) orelse return error.NoMemory;
        if (rc.master == null) {
            const m = env.create([6][64][64]u8) orelse return error.NoMemory;
            initMaster(m);
            rc.master = m;
        }
    }

    /// Superblock row `r` of the frame `f` put together from what the
    /// reading left (`out`) and the references (by LAST_FRAME to
    /// ALTREF_FRAME, there for an inter frame); with `wait`, each read of
    /// a reference waits for the lines it reaches.
    pub fn row(rc: *const Recon, seq: *const header.Sequence, h: *const header.Frame, out: *const parse.Out, f: *Frame, refs: [8]?*const Frame, wait: ?Wait, r: u32) void {
        if (f.alloc_bytes == 2) {
            var s: Put(u16) = .{ .w = rc.work.?, .master = rc.master.?, .seq = seq, .h = h, .out = out, .f = f, .refs = refs, .wait = wait, .bd = @intCast(seq.bit_depth) };
            s.sbRow(r);
        } else {
            var s: Put(u8) = .{ .w = rc.work.?, .master = rc.master.?, .seq = seq, .h = h, .out = out, .f = f, .refs = refs, .wait = wait, .bd = 8 };
            s.sbRow(r);
        }
    }
};

fn initMaster(m: *[6][64][64]u8) void {
    const n = 64;
    for (0..n) |j| {
        var shift: i32 = n / 4;
        var i: usize = 0;
        while (i < n) : (i += 2) {
            const jj: i32 = @intCast(j);
            m[WEDGE_OBLIQUE63][i][j] = tables.wedge_master_oblique_even[@intCast(common.clip3(0, n - 1, jj - shift))];
            shift -= 1;
            m[WEDGE_OBLIQUE63][i + 1][j] = tables.wedge_master_oblique_odd[@intCast(common.clip3(0, n - 1, jj - shift))];
            m[WEDGE_VERTICAL][i][j] = tables.wedge_master_vertical[j];
            m[WEDGE_VERTICAL][i + 1][j] = tables.wedge_master_vertical[j];
        }
    }
    for (0..n) |i| {
        for (0..n) |j| {
            const msk = m[WEDGE_OBLIQUE63][i][j];
            m[WEDGE_OBLIQUE27][j][i] = msk;
            m[WEDGE_OBLIQUE117][i][n - 1 - j] = 64 - msk;
            m[WEDGE_OBLIQUE153][n - 1 - j][i] = 64 - msk;
            m[WEDGE_HORIZONTAL][j][i] = m[WEDGE_VERTICAL][i][j];
        }
    }
}

fn smWeights(log2: u5) []const u8 {
    return switch (log2) {
        2 => &tables.sm_weights_tx_4x4,
        3 => &tables.sm_weights_tx_8x8,
        4 => &tables.sm_weights_tx_16x16,
        5 => &tables.sm_weights_tx_32x32,
        else => &tables.sm_weights_tx_64x64,
    };
}

fn obmcMask(len: u32) []const u8 {
    return switch (len) {
        2 => &tables.obmc_mask_2,
        4 => &tables.obmc_mask_4,
        8 => &tables.obmc_mask_8,
        16 => &tables.obmc_mask_16,
        else => &tables.obmc_mask_32,
    };
}

fn isDirectional(mode: u8) bool {
    return mode >= common.V_PRED and mode <= common.D67_PRED;
}

fn isSmooth(mode: u8) bool {
    return mode == common.SMOOTH_PRED or mode == common.SMOOTH_V_PRED or mode == common.SMOOTH_H_PRED;
}

/// intra_edge_filter_strength_selection.
fn edgeStrength(w: u32, h: u32, filter_type: bool, delta: i32) u32 {
    const d = @abs(delta);
    const wh = w + h;
    var s: u32 = 0;
    if (!filter_type) {
        if (wh <= 8) {
            if (d >= 56) s = 1;
        } else if (wh <= 12) {
            if (d >= 40) s = 1;
        } else if (wh <= 16) {
            if (d >= 40) s = 1;
        } else if (wh <= 24) {
            if (d >= 8) s = 1;
            if (d >= 16) s = 2;
            if (d >= 32) s = 3;
        } else if (wh <= 32) {
            s = 1;
            if (d >= 4) s = 2;
            if (d >= 32) s = 3;
        } else {
            s = 3;
        }
    } else {
        if (wh <= 8) {
            if (d >= 40) s = 1;
            if (d >= 64) s = 2;
        } else if (wh <= 16) {
            if (d >= 20) s = 1;
            if (d >= 48) s = 2;
        } else if (wh <= 24) {
            if (d >= 4) s = 3;
        } else {
            s = 3;
        }
    }
    return s;
}

/// intra_edge_upsample_selection.
fn useUpsample(w: u32, h: u32, filter_type: bool, delta: i32) bool {
    const d = @abs(delta);
    if (d == 0 or d >= 40) return false;
    return if (filter_type) w + h <= 8 else w + h <= 16;
}

/// The intra edge filter: `sz` samples from buf[ -1 ] on.
fn edgeFilter(buf: *[EDGE_LEN]i32, sz: u32, strength: u32) void {
    if (strength == 0) return;
    var edge: [2 * MAX_SB + 2]i32 = undefined;
    for (0..sz) |i| edge[i] = buf[EDGE_OFF + i - 1];
    const k = &tables.intra_edge_kernel[strength - 1];
    const last: i32 = @intCast(sz - 1);
    for (1..sz) |i| {
        var s: i32 = 0;
        for (0..5) |j| {
            const at = common.clip3(0, last, @as(i32, @intCast(i + j)) - 2);
            s += @as(i32, k[j]) * edge[@intCast(at)];
        }
        buf[EDGE_OFF + i - 1] = (s + 8) >> 4;
    }
}

/// The intra edge upsample: buf[ -1 .. num_px - 1 ] to
/// buf[ -2 .. 2 * num_px - 2 ].
fn upsampleEdge(buf: *[EDGE_LEN]i32, num_px: u32, hi: i32) void {
    var dup: [24]i32 = undefined;
    const o = EDGE_OFF;
    dup[0] = buf[o - 1];
    for (0..num_px + 1) |k| dup[k + 1] = buf[o + k - 1];
    dup[num_px + 2] = buf[o + num_px - 1];
    buf[o - 2] = dup[0];
    for (0..num_px) |i| {
        const s = -dup[i] + 9 * dup[i + 1] + 9 * dup[i + 2] - dup[i + 3];
        buf[o + 2 * i - 1] = common.clip3(0, hi, common.round2(s, 4));
        buf[o + 2 * i] = dup[i + 2];
    }
}

fn Put(comptime P: type) type {
    return struct {
        const S = @This();

        w: *Work,
        master: *const [6][64][64]u8,
        seq: *const header.Sequence,
        h: *const header.Frame,
        out: *const parse.Out,
        f: *Frame,
        refs: [8]?*const Frame,
        wait: ?Wait,
        bd: u5,
        max_luma_w: u32 = 0,
        max_luma_h: u32 = 0,

        inline fn hi(s: *const S) i32 {
            return (@as(i32, 1) << s.bd) - 1;
        }

        inline fn clip1(s: *const S, v: i32) i32 {
            return common.clip3(0, s.hi(), v);
        }

        inline fn row(s: *const S, p: usize, y: usize) [*]P {
            return s.f.plane(P, p) + y * s.f.stride[p];
        }

        inline fn get(s: *const S, p: usize, x: usize, y: usize) i32 {
            return s.row(p, y)[x];
        }

        inline fn put(s: *const S, p: usize, x: usize, y: usize, v: i32) void {
            s.row(p, y)[x] = @intCast(v);
        }

        fn ssx(s: *const S, p: usize) u5 {
            return if (p > 0) s.seq.ss_x else 0;
        }

        fn ssy(s: *const S, p: usize) u5 {
            return if (p > 0) s.seq.ss_y else 0;
        }

        /// The block at a 4x4: `cur` beyond the frame (where only the
        /// block being put together reaches).
        fn blockAt(s: *const S, r: u32, c: u32, cur: *const Block) *const Block {
            if (r >= s.out.mi_rows or c >= s.out.mi_cols) return cur;
            return s.out.block(r, c);
        }

        fn sbRow(s: *S, sr: u32) void {
            const out = s.out;
            for (0..out.sb_cols) |sc| {
                const i = sr * out.sb_cols + sc;
                for (out.blocks[out.sb_first[i]..][0..out.sb_count[i]]) |*b| s.block(b);
            }
        }

        /// Until plane `p` of `ref` is final down to row `last` - none
        /// of the frame itself, which intra block copy reads.
        fn need(s: *const S, ref: *const Frame, p: u32, last: i32) void {
            const wt = s.wait orelse return;
            if (ref == s.f) return;
            const n = (@as(u32, @intCast(@max(0, last))) + 1) << s.ssy(p);
            wt.cores.lines(wt.who, ref, n);
        }

        fn block(s: *S, b: *const Block) void {
            const txbs = s.out.txbs[b.txb..][0..b.ntxb];
            if (b.is_inter) {
                s.predictInter(b);
                for (txbs) |*t| {
                    if (t.eob > 0) s.reconstruct(b, t);
                }
                return;
            }
            for (txbs) |*t| {
                const p = t.plane;
                const x = @as(u32, t.x4) * 4;
                const y = @as(u32, t.y4) * 4;
                const tw: u32 = tables.tx_width[t.txsz];
                const th: u32 = tables.tx_height[t.txsz];
                const pal = if (p == 0) b.pal_y else b.pal_uv;
                if (pal > 0) {
                    s.predictPalette(b, p, x, y, t.txsz);
                } else {
                    const cfl = p > 0 and b.uv_mode == common.UV_CFL_PRED;
                    const mode = if (p == 0) b.y_mode else if (cfl) common.DC_PRED else b.uv_mode;
                    s.predictIntra(b, p, x, y, t.edges & parse.EDGE_LEFT != 0, t.edges & parse.EDGE_ABOVE != 0, t.edges & parse.EDGE_ABOVE_RIGHT != 0, t.edges & parse.EDGE_BELOW_LEFT != 0, mode, @intCast(tables.tx_width_log2[t.txsz]), @intCast(tables.tx_height_log2[t.txsz]));
                    if (cfl) s.predictCfl(p, x, y, t.txsz, if (p == 1) b.cfl_u else b.cfl_v);
                }
                if (p == 0) {
                    s.max_luma_w = x + tw;
                    s.max_luma_h = y + th;
                }
                if (t.eob > 0) s.reconstruct(b, t);
            }
        }

        // --- the residual (7.12.3) ---

        fn reconstruct(s: *S, b: *const Block, t: *const Txb) void {
            const res = &s.w.res;
            const coefs = s.out.coefs[t.coef..][0..t.eob];
            itx.inverse(res, coefs, parse.getScan(t.txsz, t.tx_type), t.txsz, t.tx_type, b.lossless, s.bd);
            const w: u32 = tables.tx_width[t.txsz];
            const h: u32 = tables.tx_height[t.txsz];
            const flip_ud = switch (t.tx_type) {
                common.FLIPADST_DCT, common.FLIPADST_ADST, common.V_FLIPADST, common.FLIPADST_FLIPADST => true,
                else => false,
            };
            const flip_lr = switch (t.tx_type) {
                common.DCT_FLIPADST, common.ADST_FLIPADST, common.H_FLIPADST, common.FLIPADST_FLIPADST => true,
                else => false,
            };
            const p = t.plane;
            const x = @as(u32, t.x4) * 4;
            const y = @as(u32, t.y4) * 4;
            for (0..h) |i| {
                const yy = if (flip_ud) h - 1 - i else i;
                const r = s.row(p, y + yy) + x;
                for (0..w) |j| {
                    const xx = if (flip_lr) w - 1 - j else j;
                    r[xx] = @intCast(s.clip1(@as(i32, r[xx]) + res[i * w + j]));
                }
            }
        }

        // --- intra prediction (7.11.2) ---

        fn predictPalette(s: *S, b: *const Block, p: u32, x: u32, y: u32, txsz: u8) void {
            const w: u32 = tables.tx_width[txsz];
            const h: u32 = tables.tx_height[txsz];
            const colors = s.out.colors[b.pal + 8 * p ..][0..8];
            var stride = parse.blockWidth(b.size) >> s.ssx(p);
            if (p > 0 and stride < 4) stride += 2;
            const map = s.out.maps[if (p == 0) b.map else b.map_uv..];
            // The transform block's place in the block.
            const bx = x - (b.col >> s.ssx(p)) * 4;
            const by = y - (b.row >> s.ssy(p)) * 4;
            for (0..h) |i| {
                const r = s.row(p, y + i) + x;
                const m = map[(by + i) * stride + bx ..];
                for (0..w) |j| r[j] = @intCast(colors[m[j]]);
            }
        }

        fn predictCfl(s: *S, p: u32, x: u32, y: u32, txsz: u8, alpha: i8) void {
            const w: u32 = tables.tx_width[txsz];
            const h: u32 = tables.tx_height[txsz];
            const sx = s.seq.ss_x;
            const sy = s.seq.ss_y;
            const l = &s.w.pred;
            var avg: i32 = 0;
            for (0..h) |i| {
                const ly = @min((y + @as(u32, @intCast(i))) << sy, s.max_luma_h - (@as(u32, 1) << sy));
                for (0..w) |j| {
                    const lx = @min((x + @as(u32, @intCast(j))) << sx, s.max_luma_w - (@as(u32, 1) << sx));
                    var t: i32 = 0;
                    for (0..@as(u32, sy) + 1) |dy| {
                        for (0..@as(u32, sx) + 1) |dx| t += s.get(0, lx + dx, ly + dy);
                    }
                    const v = t << @intCast(3 - @as(u32, sx) - sy);
                    l[i * w + j] = v;
                    avg += v;
                }
            }
            avg = common.round2(avg, @intCast(tables.tx_width_log2[txsz] + tables.tx_height_log2[txsz]));
            for (0..h) |i| {
                const r = s.row(p, y + i) + x;
                for (0..w) |j| {
                    const scaled: i32 = @intCast(common.round2Signed(@as(i64, alpha) * (l[i * w + j] - avg), 6));
                    r[j] = @intCast(s.clip1(@as(i32, r[j]) + scaled));
                }
            }
        }

        /// get_filter_type: whether the block above or left is smooth.
        fn filterType(s: *const S, b: *const Block, p: u32) bool {
            const seq = s.seq;
            const up = if (p == 0) b.avail & parse.AVAIL_U != 0 else b.avail & parse.AVAIL_U_CHROMA != 0;
            const lt = if (p == 0) b.avail & parse.AVAIL_L != 0 else b.avail & parse.AVAIL_L_CHROMA != 0;
            if (up) {
                var r = b.row - 1;
                var c = b.col;
                if (p > 0) {
                    if (seq.ss_x == 1 and b.col & 1 == 0) c += 1;
                    if (seq.ss_y == 1 and b.row & 1 == 1) r -= 1;
                }
                if (s.smoothAt(r, c, p)) return true;
            }
            if (lt) {
                var r = b.row;
                var c = b.col - 1;
                if (p > 0) {
                    if (seq.ss_x == 1 and b.col & 1 == 1) c -= 1;
                    if (seq.ss_y == 1 and b.row & 1 == 0) r += 1;
                }
                if (s.smoothAt(r, c, p)) return true;
            }
            return false;
        }

        fn smoothAt(s: *const S, r: u32, c: u32, p: u32) bool {
            const n = s.out.block(r, c);
            if (p == 0) return isSmooth(n.y_mode);
            if (n.ref[0] > common.INTRA_FRAME) return false;
            return isSmooth(n.uv_mode);
        }

        fn predictIntra(s: *S, b: *const Block, p: u32, x: u32, y: u32, have_left: bool, have_above: bool, have_ar: bool, have_bl: bool, mode: u8, log2w: u5, log2h: u5) void {
            const w = @as(u32, 1) << log2w;
            const h = @as(u32, 1) << log2h;
            const max_x = ((s.out.mi_cols * 4) >> s.ssx(p)) - 1;
            const max_y = ((s.out.mi_rows * 4) >> s.ssy(p)) - 1;
            const above = &s.w.above;
            const left = &s.w.left;
            const o = EDGE_OFF;
            const n = w + h;
            const mid = @as(i32, 1) << (s.bd - 1);
            if (!have_above and have_left) {
                @memset(above[o..][0..n], s.get(p, x - 1, y));
            } else if (!have_above) {
                @memset(above[o..][0..n], mid - 1);
            } else {
                const limit = @min(max_x, x + (if (have_ar) 2 * w else w) - 1);
                const r = s.row(p, y - 1);
                for (0..n) |i| above[o + i] = r[@min(limit, x + i)];
            }
            if (!have_left and have_above) {
                @memset(left[o..][0..n], s.get(p, x, y - 1));
            } else if (!have_left) {
                @memset(left[o..][0..n], mid + 1);
            } else {
                const limit = @min(max_y, y + (if (have_bl) 2 * h else h) - 1);
                for (0..n) |i| left[o + i] = s.get(p, x - 1, @min(limit, y + i));
            }
            const corner = if (have_above and have_left)
                s.get(p, x - 1, y - 1)
            else if (have_above)
                s.get(p, x, y - 1)
            else if (have_left)
                s.get(p, x - 1, y)
            else
                mid;
            above[o - 1] = corner;
            left[o - 1] = corner;

            const pred = &s.w.pred;
            if (p == 0 and b.filter_intra) {
                s.recursive(b.filter_mode, w, h);
            } else if (isDirectional(mode)) {
                s.directional(b, p, x, y, have_left, have_above, mode, w, h, max_x, max_y);
            } else if (isSmooth(mode)) {
                smooth(pred, above, left, mode, log2w, log2h);
            } else if (mode == common.DC_PRED) {
                s.dc(have_left, have_above, log2w, log2h);
            } else {
                paeth(pred, above, left, w, h);
            }
            for (0..h) |i| {
                const r = s.row(p, y + i) + x;
                for (0..w) |j| r[j] = @intCast(pred[i * w + j]);
            }
        }

        fn recursive(s: *S, filter_mode: u8, w: u32, h: u32) void {
            const pred = &s.w.pred;
            const above = &s.w.above;
            const left = &s.w.left;
            const o = EDGE_OFF;
            const taps = &tables.intra_filter_taps[filter_mode];
            for (0..h >> 1) |r2| {
                for (0..w >> 2) |c4| {
                    var pv: [7]i32 = undefined;
                    for (0..7) |i| {
                        if (i < 5) {
                            pv[i] = if (r2 == 0)
                                above[o + (c4 << 2) + i - 1]
                            else if (c4 == 0 and i == 0)
                                left[o + (r2 << 1) - 1]
                            else
                                pred[((r2 << 1) - 1) * w + (c4 << 2) + i - 1];
                        } else {
                            pv[i] = if (c4 == 0)
                                left[o + (r2 << 1) + i - 5]
                            else
                                pred[((r2 << 1) + i - 5) * w + (c4 << 2) - 1];
                        }
                    }
                    for (0..2) |r1| {
                        for (0..4) |c1| {
                            var pr: i32 = 0;
                            for (0..7) |i| pr += @as(i32, taps[(r1 << 2) + c1][i]) * pv[i];
                            pred[((r2 << 1) + r1) * w + (c4 << 2) + c1] = s.clip1(@intCast(common.round2Signed(pr, 4)));
                        }
                    }
                }
            }
        }

        fn directional(s: *S, b: *const Block, p: u32, x: u32, y: u32, have_left: bool, have_above: bool, mode: u8, w: u32, h: u32, max_x: u32, max_y: u32) void {
            const pred = &s.w.pred;
            const above = &s.w.above;
            const left = &s.w.left;
            const o = EDGE_OFF;
            const delta: i32 = if (p == 0) b.angle_y else b.angle_uv;
            const angle: i32 = @as(i32, tables.mode_to_angle[mode]) + delta * 3;
            var up_above: u5 = 0;
            var up_left: u5 = 0;
            if (s.seq.enable_intra_edge_filter) {
                var filter_type = false;
                if (angle != 90 and angle != 180) {
                    if (angle > 90 and angle < 180 and w + h >= 24) {
                        const c = common.round2(left[o] * 5 + above[o - 1] * 6 + above[o] * 5, 4);
                        left[o - 1] = c;
                        above[o - 1] = c;
                    }
                    filter_type = s.filterType(b, p);
                    if (have_above) {
                        const strength = edgeStrength(w, h, filter_type, angle - 90);
                        const num_px = @min(w, max_x - x + 1) + (if (angle < 90) h else 0) + 1;
                        edgeFilter(above, num_px, strength);
                    }
                    if (have_left) {
                        const strength = edgeStrength(w, h, filter_type, angle - 180);
                        const num_px = @min(h, max_y - y + 1) + (if (angle > 180) w else 0) + 1;
                        edgeFilter(left, num_px, strength);
                    }
                }
                if (useUpsample(w, h, filter_type, angle - 90)) {
                    up_above = 1;
                    upsampleEdge(above, w + (if (angle < 90) h else 0), s.hi());
                }
                if (useUpsample(w, h, filter_type, angle - 180)) {
                    up_left = 1;
                    upsampleEdge(left, h + (if (angle > 180) w else 0), s.hi());
                }
            }
            const io: i32 = o;
            if (angle < 90) {
                const dx: i32 = tables.dr_intra_derivative[@intCast(angle)];
                const max_base: i32 = @as(i32, @intCast(w + h - 1)) << up_above;
                for (0..h) |i| {
                    const idx = (@as(i32, @intCast(i)) + 1) * dx;
                    const shift = ((idx << up_above) >> 1) & 0x1F;
                    for (0..w) |j| {
                        const base = (idx >> (6 - up_above)) + (@as(i32, @intCast(j)) << up_above);
                        pred[i * w + j] = if (base < max_base)
                            common.round2(above[@intCast(io + base)] * (32 - shift) + above[@intCast(io + base + 1)] * shift, 5)
                        else
                            above[@intCast(io + max_base)];
                    }
                }
            } else if (angle > 90 and angle < 180) {
                const dx: i32 = tables.dr_intra_derivative[@intCast(180 - angle)];
                const dy: i32 = tables.dr_intra_derivative[@intCast(angle - 90)];
                for (0..h) |i| {
                    const ii: i32 = @intCast(i);
                    for (0..w) |j| {
                        const jj: i32 = @intCast(j);
                        var idx = (jj << 6) - (ii + 1) * dx;
                        var base = idx >> (6 - up_above);
                        if (base >= -(@as(i32, 1) << up_above)) {
                            const shift = ((idx << up_above) >> 1) & 0x1F;
                            pred[i * w + j] = common.round2(above[@intCast(io + base)] * (32 - shift) + above[@intCast(io + base + 1)] * shift, 5);
                        } else {
                            idx = (ii << 6) - (jj + 1) * dy;
                            base = idx >> (6 - up_left);
                            const shift = ((idx << up_left) >> 1) & 0x1F;
                            pred[i * w + j] = common.round2(left[@intCast(io + base)] * (32 - shift) + left[@intCast(io + base + 1)] * shift, 5);
                        }
                    }
                }
            } else if (angle > 180) {
                const dy: i32 = tables.dr_intra_derivative[@intCast(270 - angle)];
                for (0..w) |j| {
                    const idx = (@as(i32, @intCast(j)) + 1) * dy;
                    const shift = ((idx << up_left) >> 1) & 0x1F;
                    for (0..h) |i| {
                        const base = (idx >> (6 - up_left)) + (@as(i32, @intCast(i)) << up_left);
                        pred[i * w + j] = common.round2(left[@intCast(io + base)] * (32 - shift) + left[@intCast(io + base + 1)] * shift, 5);
                    }
                }
            } else if (angle == 90) {
                for (0..h) |i| {
                    for (0..w) |j| pred[i * w + j] = above[o + j];
                }
            } else {
                for (0..h) |i| {
                    for (0..w) |j| pred[i * w + j] = left[o + i];
                }
            }
        }

        fn dc(s: *S, have_left: bool, have_above: bool, log2w: u5, log2h: u5) void {
            const pred = &s.w.pred;
            const above = &s.w.above;
            const left = &s.w.left;
            const o = EDGE_OFF;
            const w = @as(u32, 1) << log2w;
            const h = @as(u32, 1) << log2h;
            var v: i32 = undefined;
            if (have_left and have_above) {
                var sum: u32 = 0;
                for (0..h) |k| sum += @intCast(left[o + k]);
                for (0..w) |k| sum += @intCast(above[o + k]);
                sum += (w + h) >> 1;
                v = @intCast(sum / (w + h));
            } else if (have_left) {
                var sum: i32 = 0;
                for (0..h) |k| sum += left[o + k];
                v = s.clip1((sum + @as(i32, @intCast(h >> 1))) >> log2h);
            } else if (have_above) {
                var sum: i32 = 0;
                for (0..w) |k| sum += above[o + k];
                v = s.clip1((sum + @as(i32, @intCast(w >> 1))) >> log2w);
            } else {
                v = @as(i32, 1) << (s.bd - 1);
            }
            @memset(pred[0 .. w * h], v);
        }

        // --- inter prediction (7.11.3) ---

        /// compute_prediction for an inter block: its interintra part and
        /// each plane's prediction - by the 4x4s' own vectors for the
        /// colours of blocks smaller than 8x8.
        fn predictInter(s: *S, b: *const Block) void {
            const planes: u32 = if (b.has_chroma) 3 else 1;
            for (0..planes) |pu| {
                const p: u32 = @intCast(pu);
                const sx = s.ssx(p);
                const sy = s.ssy(p);
                const psz = tables.subsampled_size[b.size][sx][sy];
                const n4w: u32 = tables.num_4x4_blocks_wide[psz];
                const n4h: u32 = tables.num_4x4_blocks_high[psz];
                const base_x = (b.col >> sx) * 4;
                const base_y = (b.row >> sy) * 4;
                var cand_row = (b.row >> sy) << sy;
                var cand_col = (b.col >> sx) << sx;
                if (b.interintra) {
                    const mode: u8 = switch (b.ii_mode) {
                        common.II_DC_PRED => common.DC_PRED,
                        common.II_V_PRED => common.V_PRED,
                        common.II_H_PRED => common.H_PRED,
                        else => common.SMOOTH_PRED,
                    };
                    const have_left = if (p == 0) b.avail & parse.AVAIL_L != 0 else b.avail & parse.AVAIL_L_CHROMA != 0;
                    const have_above = if (p == 0) b.avail & parse.AVAIL_U != 0 else b.avail & parse.AVAIL_U_CHROMA != 0;
                    const ar = b.ii_edges & (@as(u8, 1) << @intCast(2 * p)) != 0;
                    const bl = b.ii_edges & (@as(u8, 2) << @intCast(2 * p)) != 0;
                    s.predictIntra(b, p, base_x, base_y, have_left, have_above, ar, bl, mode, @intCast(2 + tables.mi_width_log2[psz]), @intCast(2 + tables.mi_height_log2[psz]));
                }
                var pred_w = parse.blockWidth(b.size) >> sx;
                var pred_h = parse.blockHeight(b.size) >> sy;
                var some_intra = false;
                for (0..n4h << sy) |r| {
                    for (0..n4w << sx) |c| {
                        if (s.blockAt(cand_row + @as(u32, @intCast(r)), cand_col + @as(u32, @intCast(c)), b).ref[0] == common.INTRA_FRAME) some_intra = true;
                    }
                }
                if (some_intra) {
                    pred_w = n4w * 4;
                    pred_h = n4h * 4;
                    cand_row = b.row;
                    cand_col = b.col;
                }
                var r: u32 = 0;
                var y: u32 = 0;
                while (y < n4h * 4) : (y += pred_h) {
                    var c: u32 = 0;
                    var x: u32 = 0;
                    while (x < n4w * 4) : (x += pred_w) {
                        s.predictRegion(b, p, base_x + x, base_y + y, pred_w, pred_h, cand_row + r, cand_col + c);
                        c += 1;
                    }
                    r += 1;
                }
            }
        }

        const Rounding = struct { r0: u5, r1: u5, post: u5 };

        fn rounding(s: *const S, compound: bool) Rounding {
            var r0: u5 = 3;
            var r1: u5 = if (compound) 7 else 11;
            if (s.bd == 12) r0 += 2;
            if (s.bd == 12 and !compound) r1 -= 2;
            return .{ .r0 = r0, .r1 = r1, .post = 14 - r0 - r1 };
        }

        const Scaled = struct { x: i32, y: i32, step_x: i32, step_y: i32 };

        /// The motion vector scaling process: where in a reference of
        /// `ref_w` by `ref_h` (luma) the block at x, y starts, in 1/1024.
        fn scale(s: *const S, p: u32, ref_w: u32, ref_h: u32, x: u32, y: u32, mv: Mv) Scaled {
            const fw: i64 = s.h.frame_width;
            const fh: i64 = s.h.frame_height;
            const x_scale = @divTrunc((@as(i64, ref_w) << 14) + @divTrunc(fw, 2), fw);
            const y_scale = @divTrunc((@as(i64, ref_h) << 14) + @divTrunc(fh, 2), fh);
            const half: i64 = 8;
            const orig_x = (@as(i64, x) << 4) + ((2 * @as(i64, mv.col)) >> s.ssx(p)) + half;
            const orig_y = (@as(i64, y) << 4) + ((2 * @as(i64, mv.row)) >> s.ssy(p)) + half;
            const base_x = orig_x * x_scale - (half << 14);
            const base_y = orig_y * y_scale - (half << 14);
            const off: i64 = 32;
            return .{
                .x = @intCast(common.round2Signed(base_x, 8) + off),
                .y = @intCast(common.round2Signed(base_y, 8) + off),
                .step_x = @intCast(common.round2Signed(x_scale, 4)),
                .step_y = @intCast(common.round2Signed(y_scale, 4)),
            };
        }

        fn isScaled(s: *const S, ref: *const Frame) bool {
            const fw: u64 = s.h.frame_width;
            const fh: u64 = s.h.frame_height;
            const x_scale = ((@as(u64, ref.width) << 14) + fw / 2) / fw;
            const y_scale = ((@as(u64, ref.height) << 14) + fh / 2) / fh;
            return x_scale != 1 << 14 or y_scale != 1 << 14;
        }

        /// predict_inter: a region of `w` by `h` at x, y of plane `p`, by
        /// the vectors of the 4x4 at `cand_row`, `cand_col`.
        fn predictRegion(s: *S, b: *const Block, p: u32, x: u32, y: u32, w: u32, h: u32, cand_row: u32, cand_col: u32) void {
            const hd = s.h;
            const wk = s.w;
            const cand = s.blockAt(cand_row, cand_col, b);
            const compound = cand.ref[1] > common.INTRA_FRAME;
            const rd = s.rounding(compound);
            const local_valid = b.motion_mode == common.LOCALWARP and b.warp != parse.NO_BLOCK;
            const global_mode = b.y_mode == common.GLOBALMV or b.y_mode == common.GLOBAL_GLOBALMV;
            const sx = s.ssx(p);
            const sy = s.ssy(p);
            for (0..@as(u32, if (compound) 2 else 1)) |list| {
                const ref_frame: usize = @intCast(cand.ref[list]);
                const dst = wk.preds[list][0 .. w * h];
                var ref: *const Frame = undefined;
                var ref_w: u32 = undefined;
                var ref_h: u32 = undefined;
                var last_x: i32 = undefined;
                var last_y: i32 = undefined;
                if (b.intrabc) {
                    ref = s.f;
                    ref_w = hd.frame_width;
                    ref_h = hd.frame_height;
                    last_x = @intCast(((s.out.mi_cols * 4 + sx) >> sx) - 1);
                    last_y = @intCast(((s.out.mi_rows * 4 + sy) >> sy) - 1);
                } else {
                    ref = s.refs[ref_frame].?;
                    ref_w = ref.width;
                    ref_h = ref.height;
                    last_x = @intCast(((ref.width + sx) >> sx) - 1);
                    last_y = @intCast(((ref.height + sy) >> sy) - 1);
                }
                var use_warp: u2 = 0;
                if (w >= 8 and h >= 8 and !hd.force_integer_mv) {
                    if (local_valid) {
                        use_warp = 1;
                    } else if (global_mode and hd.gm_type[ref_frame] > common.TRANSLATION and !s.isScaled(ref) and
                        warp.setupShear(&hd.gm_params[ref_frame]).valid)
                    {
                        use_warp = 2;
                    }
                }
                if (use_warp != 0) {
                    const params = if (use_warp == 1) &s.out.warps[b.warp].params else &hd.gm_params[ref_frame];
                    for (0..((h - 1) >> 3) + 1) |bi| {
                        for (0..((w - 1) >> 3) + 1) |bj| {
                            s.blockWarp(p, ref, last_x, last_y, params, x, y, @intCast(bi), @intCast(bj), w, h, dst, rd);
                        }
                    }
                } else {
                    const sc = s.scale(p, ref_w, ref_h, x, y, cand.mv[list]);
                    s.blockInter(p, ref, last_x, last_y, sc, w, h, cand, dst, rd);
                }
            }

            // The masks.
            const mask = &wk.mask;
            if (b.compound_type == common.COMPOUND_WEDGE and p == 0) {
                s.wedgeMask(b.size, b.wedge_sign, b.wedge_index, w, h);
            } else if (b.compound_type == common.COMPOUND_INTRA) {
                const scale_ = MAX_SB / @max(w, h);
                for (0..h) |i| {
                    for (0..w) |j| {
                        mask[i * MAX_SB + j] = switch (b.ii_mode) {
                            common.II_V_PRED => tables.ii_weights_1d[i * scale_],
                            common.II_H_PRED => tables.ii_weights_1d[j * scale_],
                            common.II_SMOOTH_PRED => tables.ii_weights_1d[@min(i, j) * scale_],
                            else => 32,
                        };
                    }
                }
            } else if (b.compound_type == common.COMPOUND_DIFFWTD and p == 0) {
                const p0 = &wk.preds[0];
                const p1 = &wk.preds[1];
                for (0..h) |i| {
                    for (0..w) |j| {
                        var diff: i32 = @intCast(@abs(p0[i * w + j] - p1[i * w + j]));
                        diff = common.round2(diff, (s.bd - 8) + rd.post);
                        const m: u8 = @intCast(common.clip3(0, 64, 38 + @divTrunc(diff, 16)));
                        mask[i * MAX_SB + j] = if (b.mask_type != 0) 64 - m else m;
                    }
                }
            }

            const p0 = &wk.preds[0];
            const p1 = &wk.preds[1];
            if (!compound and !b.interintra) {
                for (0..h) |i| {
                    const r = s.row(p, y + i) + x;
                    for (0..w) |j| r[j] = @intCast(s.clip1(p0[i * w + j]));
                }
            } else if (b.compound_type == common.COMPOUND_AVERAGE) {
                for (0..h) |i| {
                    const r = s.row(p, y + i) + x;
                    for (0..w) |j| r[j] = @intCast(s.clip1(common.round2(p0[i * w + j] + p1[i * w + j], 1 + rd.post)));
                }
            } else if (b.compound_type == common.COMPOUND_DISTANCE) {
                const wt = s.distanceWeights(cand);
                for (0..h) |i| {
                    const r = s.row(p, y + i) + x;
                    for (0..w) |j| r[j] = @intCast(s.clip1(common.round2(wt[0] * p0[i * w + j] + wt[1] * p1[i * w + j], 4 + rd.post)));
                }
            } else {
                const full = (sx == 0 and sy == 0) or (b.interintra and !b.wedge_interintra);
                for (0..h) |i| {
                    const r = s.row(p, y + i) + x;
                    for (0..w) |j| {
                        const m: i32 = if (full)
                            mask[i * MAX_SB + j]
                        else if (sx == 1 and sy == 0)
                            common.round2(@as(i32, mask[i * MAX_SB + 2 * j]) + mask[i * MAX_SB + 2 * j + 1], 1)
                        else
                            common.round2(@as(i32, mask[2 * i * MAX_SB + 2 * j]) + mask[2 * i * MAX_SB + 2 * j + 1] +
                                mask[(2 * i + 1) * MAX_SB + 2 * j] + mask[(2 * i + 1) * MAX_SB + 2 * j + 1], 2);
                        if (b.interintra) {
                            const pred0 = s.clip1(common.round2(p0[i * w + j], rd.post));
                            const pred1: i32 = r[j];
                            r[j] = @intCast(common.round2(m * pred1 + (64 - m) * pred0, 6));
                        } else {
                            r[j] = @intCast(s.clip1(common.round2(m * p0[i * w + j] + (64 - m) * p1[i * w + j], 6 + rd.post)));
                        }
                    }
                }
            }
            if (b.motion_mode == common.OBMC) s.obmc(b, p, w, h, rd);
        }

        /// The block inter prediction process: `w` by `h` from `ref`
        /// at `sc`, by the filters of `cand`, into `dst` (at the stride
        /// `w`).
        fn blockInter(s: *S, p: u32, ref: *const Frame, last_x: i32, last_y: i32, sc: Scaled, w: u32, h: u32, cand: *const Block, dst: []i32, rd: Rounding) void {
            const mid = &s.w.mid;
            const inter_h: u32 = @intCast(((@as(i32, @intCast(h)) - 1) * sc.step_y + (1 << 10) - 1 >> 10) + 8);
            var fx: usize = cand.filter[1];
            if (w <= 4) {
                if (fx == common.EIGHTTAP or fx == common.EIGHTTAP_SHARP) fx = 4 else if (fx == common.EIGHTTAP_SMOOTH) fx = 5;
            }
            var fy: usize = cand.filter[0];
            if (h <= 4) {
                if (fy == common.EIGHTTAP or fy == common.EIGHTTAP_SHARP) fy = 4 else if (fy == common.EIGHTTAP_SMOOTH) fy = 5;
            }
            s.need(ref, p, @min(last_y, (sc.y >> 10) + @as(i32, @intCast(inter_h)) - 4));
            const plane = ref.plane(P, p);
            const stride = ref.stride[p];
            if (sc.step_x == 1 << 10 and sc.step_y == 1 << 10) {
                const x0 = sc.x >> 10;
                const y0 = sc.y >> 10;
                const w_: i32 = @intCast(w);
                const h_: i32 = @intCast(h);
                const frac_x: usize = @intCast((sc.x >> 6) & 15);
                const frac_y: usize = @intCast((sc.y >> 6) & 15);
                if (x0 >= 3 and y0 >= 3 and x0 + w_ + 4 <= last_x + 1 and y0 + h_ + 4 <= last_y + 1) {
                    return s.blockInterInside(plane + @as(usize, @intCast(y0)) * stride + @as(usize, @intCast(x0)), stride, frac_x, frac_y, fx, fy, w, h, dst, rd);
                }
                // At the edge: what the taps reach copied, the edge
                // repeated as the clipped positions would read it.
                const edge: [*]P = @ptrCast(&s.w.edge);
                const ew = w + 7;
                var cols: [MAX_SB + 7]usize = undefined;
                for (cols[0..ew], 0..) |*c, i| c.* = @intCast(common.clip3(0, last_x, x0 + @as(i32, @intCast(i)) - 3));
                for (0..h + 7) |r| {
                    const ry = common.clip3(0, last_y, y0 + @as(i32, @intCast(r)) - 3);
                    const src = plane + @as(usize, @intCast(ry)) * stride;
                    for (edge[r * ew ..][0..ew], cols[0..ew]) |*o, c| o.* = src[c];
                }
                return s.blockInterInside(edge + 3 * ew + 3, ew, frac_x, frac_y, fx, fy, w, h, dst, rd);
            }
            for (0..inter_h) |r| {
                const ry = common.clip3(0, last_y, (sc.y >> 10) + @as(i32, @intCast(r)) - 3);
                const src = plane + @as(usize, @intCast(ry)) * stride;
                for (0..w) |c| {
                    const pos = sc.x + sc.step_x * @as(i32, @intCast(c));
                    const taps = &tables.subpel_filters[fx][@intCast((pos >> 6) & 15)];
                    var sum: i32 = 0;
                    for (0..8) |t| {
                        const rx = common.clip3(0, last_x, (pos >> 10) + @as(i32, @intCast(t)) - 3);
                        sum += @as(i32, taps[t]) * @as(i32, src[@intCast(rx)]);
                    }
                    mid[r * w + c] = common.round2(sum, rd.r0);
                }
            }
            for (0..h) |r| {
                const pos = (sc.y & 1023) + sc.step_y * @as(i32, @intCast(r));
                const taps = &tables.subpel_filters[fy][@intCast((pos >> 6) & 15)];
                const top: usize = @intCast(pos >> 10);
                for (0..w) |c| {
                    var sum: i32 = 0;
                    for (0..8) |t| sum += @as(i32, taps[t]) * mid[(top + t) * w + c];
                    dst[r * w + c] = common.round2(sum, rd.r1);
                }
            }
        }

        /// blockInter for a block at whole steps whose taps all lie in
        /// the reference, `at` its first sample: the same sums, without a
        /// clip for each tap, and a filter at position 0 - the sample
        /// itself, times 128 - taken as the shift it is.
        fn blockInterInside(s: *S, at: [*]const P, stride: usize, frac_x: usize, frac_y: usize, fx: usize, fy: usize, w: u32, h: u32, dst: []i32, rd: Rounding) void {
            const mid = &s.w.mid;
            const up0: u5 = 7 - rd.r0;
            if (frac_y == 0) {
                // The rows themselves, filtered across or not.
                for (0..h) |r| {
                    const src = at + r * stride;
                    const o = dst[r * w ..][0..w];
                    if (frac_x == 0) {
                        for (o, 0..) |*d, c| d.* = common.round2(@as(i32, src[c]) << (up0 + 7), rd.r1);
                    } else {
                        const taps = &tables.subpel_filters[fx][frac_x];
                        const left = src - 3;
                        for (o, 0..) |*d, c| {
                            var sum: i32 = 0;
                            for (0..8) |t| sum += @as(i32, taps[t]) * @as(i32, left[c + t]);
                            d.* = common.round2(common.round2(sum, rd.r0) << 7, rd.r1);
                        }
                    }
                }
                return;
            }
            // The rows from 3 above to 4 below, filtered across, then down.
            const top = at - 3 * stride;
            for (0..h + 7) |r| {
                const src = top + r * stride;
                const m = mid[r * w ..][0..w];
                if (frac_x == 0) {
                    for (m, 0..) |*d, c| d.* = @as(i32, src[c]) << up0;
                } else {
                    const taps = &tables.subpel_filters[fx][frac_x];
                    const left = src - 3;
                    for (m, 0..) |*d, c| {
                        var sum: i32 = 0;
                        for (0..8) |t| sum += @as(i32, taps[t]) * @as(i32, left[c + t]);
                        d.* = common.round2(sum, rd.r0);
                    }
                }
            }
            const taps = &tables.subpel_filters[fy][frac_y];
            for (0..h) |r| {
                const o = dst[r * w ..][0..w];
                for (o, 0..) |*d, c| {
                    var sum: i32 = 0;
                    for (0..8) |t| sum += @as(i32, taps[t]) * mid[(r + t) * w + c];
                    d.* = common.round2(sum, rd.r1);
                }
            }
        }

        /// The block warp process: the 8x8 at i8, j8 of the block of `w`
        /// by `h` at x, y, warped by `params`.
        fn blockWarp(s: *S, p: u32, ref: *const Frame, last_x: i32, last_y: i32, params: *const [6]i32, x: u32, y: u32, bi: u32, bj: u32, w: u32, h: u32, dst: []i32, rd: Rounding) void {
            const sx = s.ssx(p);
            const sy = s.ssy(p);
            const src_x: i64 = @as(i64, x + bj * 8 + 4) << sx;
            const src_y: i64 = @as(i64, y + bi * 8 + 4) << sy;
            const dst_x = @as(i64, params[2]) * src_x + @as(i64, params[3]) * src_y + params[0];
            const dst_y = @as(i64, params[4]) * src_x + @as(i64, params[5]) * src_y + params[1];
            const sh = warp.setupShear(params);
            const x4 = dst_x >> sx;
            const y4 = dst_y >> sy;
            const ix4: i32 = @intCast(x4 >> warp.PREC_BITS);
            const sx4: i32 = @intCast(x4 & ((1 << warp.PREC_BITS) - 1));
            const iy4: i32 = @intCast(y4 >> warp.PREC_BITS);
            const sy4: i32 = @intCast(y4 & ((1 << warp.PREC_BITS) - 1));
            s.need(ref, p, @min(last_y, iy4 + 7));
            const plane = ref.plane(P, p);
            const stride = ref.stride[p];
            var mid: [15][8]i32 = undefined;
            var k1: i32 = -7;
            while (k1 < 8) : (k1 += 1) {
                const ry = common.clip3(0, last_y, iy4 + k1);
                const src = plane + @as(usize, @intCast(ry)) * stride;
                var k2: i32 = -4;
                while (k2 < 4) : (k2 += 1) {
                    const sxx = sx4 + sh.alpha * k2 + sh.beta * k1;
                    const offs: usize = @intCast(common.round2(sxx, 10) + 64);
                    var sum: i32 = 0;
                    for (0..8) |k3| {
                        const rx = common.clip3(0, last_x, ix4 + k2 - 3 + @as(i32, @intCast(k3)));
                        sum += @as(i32, tables.warped_filters[offs][k3]) * @as(i32, src[@intCast(rx)]);
                    }
                    mid[@intCast(k1 + 7)][@intCast(k2 + 4)] = common.round2(sum, rd.r0);
                }
            }
            const lim_y = @min(4, @as(i32, @intCast(h)) - @as(i32, @intCast(bi * 8)) - 4);
            const lim_x = @min(4, @as(i32, @intCast(w)) - @as(i32, @intCast(bj * 8)) - 4);
            k1 = -4;
            while (k1 < lim_y) : (k1 += 1) {
                var k2: i32 = -4;
                while (k2 < lim_x) : (k2 += 1) {
                    const syy = sy4 + sh.gamma * k2 + sh.delta * k1;
                    const offs: usize = @intCast(common.round2(syy, 10) + 64);
                    var sum: i32 = 0;
                    for (0..8) |k3| sum += @as(i32, tables.warped_filters[offs][k3]) * mid[@intCast(k1 + @as(i32, @intCast(k3)) + 4)][@intCast(k2 + 4)];
                    const oy: usize = @intCast(@as(i32, @intCast(bi * 8)) + k1 + 4);
                    const ox: usize = @intCast(@as(i32, @intCast(bj * 8)) + k2 + 4);
                    dst[oy * w + ox] = common.round2(sum, rd.r1);
                }
            }
        }

        fn wedgeMask(s: *S, size: u8, sign: u8, index: u8, w: u32, h: u32) void {
            const w4: u32 = tables.num_4x4_blocks_wide[size];
            const h4: u32 = tables.num_4x4_blocks_high[size];
            const shape: usize = if (h4 > w4) 0 else if (h4 < w4) 1 else 2;
            const code = tables.wedge_codebook[shape][index];
            const m = &s.master[code[0]];
            const xoff = 32 - ((@as(u32, code[1]) * w) >> 3);
            const yoff = 32 - ((@as(u32, code[2]) * h) >> 3);
            var sum: u32 = 0;
            for (0..w) |i| sum += m[yoff][xoff + i];
            for (1..h) |i| sum += m[yoff + i][xoff];
            const avg = (sum + (w + h - 1) / 2) / (w + h - 1);
            const flip: u8 = if (avg < 32) 1 else 0;
            const mask = &s.w.mask;
            for (0..h) |i| {
                for (0..w) |j| {
                    const v = m[yoff + i][xoff + j];
                    mask[i * MAX_SB + j] = if (sign == flip) v else 64 - v;
                }
            }
        }

        /// The distance weights process: FwdWeight and BckWeight.
        fn distanceWeights(s: *const S, cand: *const Block) [2]i32 {
            var dist: [2]i32 = undefined;
            for (0..2) |list| {
                const oh = s.h.order_hints[@intCast(cand.ref[list])];
                dist[list] = common.clip3(0, 31, @intCast(@abs(s.seq.dist(oh, s.h.order_hint))));
            }
            const d0 = dist[1];
            const d1 = dist[0];
            const order: usize = if (d0 <= d1) 1 else 0;
            var i: usize = 3;
            if (d0 != 0 and d1 != 0) {
                i = 0;
                while (i < 3) : (i += 1) {
                    const c0: i32 = tables.quant_dist_weight[i][order];
                    const c1: i32 = tables.quant_dist_weight[i][1 - order];
                    if (order == 1) {
                        if (d0 * c0 > d1 * c1) break;
                    } else {
                        if (d0 * c0 < d1 * c1) break;
                    }
                }
            }
            return .{ tables.quant_dist_lookup[i][order], tables.quant_dist_lookup[i][1 - order] };
        }

        /// The overlapped motion compensation: the block's prediction
        /// blended with its neighbours' above and left.
        fn obmc(s: *S, b: *const Block, p: u32, w: u32, h: u32, rd: Rounding) void {
            const out = s.out;
            const sx = s.ssx(p);
            const sy = s.ssy(p);
            if (b.avail & parse.AVAIL_U != 0 and tables.subsampled_size[b.size][sx][sy] >= common.BLOCK_8X8) {
                const w4: u32 = tables.num_4x4_blocks_wide[b.size];
                var x4 = b.col;
                var n: u32 = 0;
                const limit = @min(4, tables.mi_width_log2[b.size]);
                while (n < limit and x4 < @min(out.mi_cols, b.col + w4)) {
                    const cand_row = b.row - 1;
                    const cand_col = x4 | 1;
                    const cand = out.block(cand_row, cand_col);
                    const step4 = common.clip3(2, 16, tables.num_4x4_blocks_wide[cand.size]);
                    if (cand.ref[0] > common.INTRA_FRAME) {
                        n += 1;
                        const pw = @min(w, (@as(u32, @intCast(step4)) * 4) >> sx);
                        const ph = @min(h >> 1, @as(u32, 32) >> sy);
                        s.overlap(p, cand, x4, b.row, pw, ph, false, obmcMask(ph), rd);
                    }
                    x4 += @intCast(step4);
                }
            }
            if (b.avail & parse.AVAIL_L != 0) {
                const h4: u32 = tables.num_4x4_blocks_high[b.size];
                var y4 = b.row;
                var n: u32 = 0;
                const limit = @min(4, tables.mi_height_log2[b.size]);
                while (n < limit and y4 < @min(out.mi_rows, b.row + h4)) {
                    const cand_col = b.col - 1;
                    const cand_row = y4 | 1;
                    const cand = out.block(cand_row, cand_col);
                    const step4 = common.clip3(2, 16, tables.num_4x4_blocks_high[cand.size]);
                    if (cand.ref[0] > common.INTRA_FRAME) {
                        n += 1;
                        const pw = @min(w >> 1, @as(u32, 32) >> sx);
                        const ph = @min(h, (@as(u32, @intCast(step4)) * 4) >> sy);
                        s.overlap(p, cand, b.col, y4, pw, ph, true, obmcMask(pw), rd);
                    }
                    y4 += @intCast(step4);
                }
            }
        }

        /// predict_overlap and the overlap blending process.
        fn overlap(s: *S, p: u32, cand: *const Block, x4: u32, y4: u32, pw: u32, ph: u32, from_left: bool, mask: []const u8, rd: Rounding) void {
            const ref = s.refs[@intCast(cand.ref[0])].?;
            const sx = s.ssx(p);
            const sy = s.ssy(p);
            const px = (x4 * 4) >> sx;
            const py = (y4 * 4) >> sy;
            const sc = s.scale(p, ref.width, ref.height, px, py, cand.mv[0]);
            const last_x: i32 = @intCast(((ref.width + sx) >> sx) - 1);
            const last_y: i32 = @intCast(((ref.height + sy) >> sy) - 1);
            const pred = s.w.obmc[0 .. pw * ph];
            s.blockInter(p, ref, last_x, last_y, sc, pw, ph, cand, pred, rd);
            for (0..ph) |i| {
                const r = s.row(p, py + i) + px;
                for (0..pw) |j| {
                    const m: i32 = if (from_left) mask[j] else mask[i];
                    const o = s.clip1(pred[i * pw + j]);
                    r[j] = @intCast(common.round2(m * @as(i32, r[j]) + (64 - m) * o, 6));
                }
            }
        }
    };
}

fn smooth(pred: *[64 * 64]i32, above: *const [EDGE_LEN]i32, left: *const [EDGE_LEN]i32, mode: u8, log2w: u5, log2h: u5) void {
    const o = EDGE_OFF;
    const w = @as(u32, 1) << log2w;
    const h = @as(u32, 1) << log2h;
    const wx = smWeights(log2w);
    const wy = smWeights(log2h);
    for (0..h) |i| {
        for (0..w) |j| {
            const ay: i32 = wy[i];
            const ax: i32 = wx[j];
            pred[i * w + j] = switch (mode) {
                common.SMOOTH_PRED => common.round2(ay * above[o + j] + (256 - ay) * left[o + h - 1] +
                    ax * left[o + i] + (256 - ax) * above[o + w - 1], 9),
                common.SMOOTH_V_PRED => common.round2(ay * above[o + j] + (256 - ay) * left[o + h - 1], 8),
                else => common.round2(ax * left[o + i] + (256 - ax) * above[o + w - 1], 8),
            };
        }
    }
}

fn paeth(pred: *[64 * 64]i32, above: *const [EDGE_LEN]i32, left: *const [EDGE_LEN]i32, w: u32, h: u32) void {
    const o = EDGE_OFF;
    const tl = above[o - 1];
    for (0..h) |i| {
        // By the row: the index into the whole of `pred`, checked, is
        // more than the Xtensa backend of LLVM can make.
        const row = pred[i * w ..][0..w];
        for (0..w) |j| {
            const base = above[o + j] + left[o + i] - tl;
            const p_left = @abs(base - left[o + i]);
            const p_top = @abs(base - above[o + j]);
            const p_tl = @abs(base - tl);
            row[j] = if (p_left <= p_top and p_left <= p_tl)
                left[o + i]
            else if (p_top <= p_tl)
                above[o + j]
            else
                tl;
        }
    }
}

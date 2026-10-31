// SPDX-License-Identifier: MIT
//! The deblocking filter (8.7), over a decoded picture once all of its
//! macroblocks are there: each macroblock in turn, its vertical edges
//! left to right, then its horizontal ones top to bottom.
//!
//! The samples on either side of an edge are found by where they are in
//! the frame, as the macroblocks' neighbours are: a field macroblock's
//! rows are every other row, and the macroblock owning a sample to the
//! left or above follows from the row. The strength of each line follows
//! from the two macroblocks and 4x4 blocks it crosses (8.7.2.1). Without
//! macroblock pairs the lines of a block share it, and every plane's
//! lines take their luma block's: it is worked out once a block.

const common = @import("common.zig");
const MbInfo = common.MbInfo;
const Store = common.Store;
const tables = @import("tables.zig");

/// A picture to filter.
pub const Db = struct {
    store: *Store,
    infos: []const MbInfo,
    /// Macroblocks across, and macroblock rows of the frame.
    width: u32,
    rows: u32,
    mbaff: bool,
    field_pic: bool,
    bottom: bool,
    /// The picture's first slice: a macroblock of a lower one was not
    /// decoded in it.
    first_slice: u32,
    cat: u2,
    mbh_c: u32,
    depth_y: u5,
    depth_c: u5,
};

const Cur = struct {
    xy: u32,
    mb_x: u32,
    mb_y: u32,
    field: bool,
    info: *const MbInfo,
};

const Owner = struct { xy: u32, row: u32 };

/// Whether an edge with macroblock `xy` is filtered: decoded in this
/// picture, and in the same slice when the slice says so.
fn usable(db: *const Db, cur: *const Cur, xy: u32) bool {
    const n = &db.infos[xy];
    if (n.slice < db.first_slice) return false;
    if (cur.info.filter == 2 and n.slice != cur.info.slice) return false;
    return true;
}

/// The macroblock holding the sample `dx` macroblocks across and on row
/// `y` of the current one (-1 above), in a plane `mbh` high; its row.
fn owner(db: *const Db, cur: *const Cur, dx: i32, y: i32, mbh: u32) ?Owner {
    const nx = @as(i32, @intCast(cur.mb_x)) + dx;
    if (nx < 0 or nx >= @as(i32, @intCast(db.width))) return null;
    const ux: u32 = @intCast(nx);
    const w = db.width;
    var xy: u32 = undefined;
    var row: u32 = undefined;
    if (!db.mbaff) {
        if (y < 0) {
            const step: u32 = if (db.field_pic) 2 else 1;
            if (cur.mb_y < step) return null;
            xy = (cur.mb_y - step) * w + ux;
            row = mbh - 1;
        } else {
            xy = cur.mb_y * w + ux;
            row = @intCast(y);
        }
    } else {
        const h: i32 = @intCast(mbh);
        const pair_h = 2 * h;
        const pair_y0: i32 = @as(i32, @intCast(cur.mb_y >> 1)) * pair_h;
        const bottom: i32 = @intCast(cur.mb_y & 1);
        const y0 = if (cur.field) pair_y0 + bottom else pair_y0 + bottom * h;
        const yy = y0 + (if (cur.field) @as(i32, 2) else 1) * y;
        if (yy < 0) return null;
        const pr = @divFloor(yy, pair_h);
        const o = yy - pr * pair_h;
        const top: u32 = @as(u32, @intCast(2 * pr)) * w + ux;
        if (!usable(db, cur, top)) return null;
        if (db.infos[top].flags & common.F_FIELD != 0) {
            xy = top + @as(u32, @intCast(o & 1)) * w;
            row = @intCast(o >> 1);
        } else {
            xy = top + (if (o >= h) w else 0);
            row = @intCast(@mod(o, h));
        }
    }
    if (!usable(db, cur, xy)) return null;
    return .{ .xy = xy, .row = row };
}

inline fn blkOf(x: u32, y: u32) u32 {
    return (y >> 2) * 4 + (x >> 2);
}

fn isField(db: *const Db, n: *const MbInfo) bool {
    return db.field_pic or n.flags & common.F_FIELD != 0;
}

fn intraLike(n: *const MbInfo) bool {
    return n.flags & (common.F_INTRA | common.F_SWITCH) != 0;
}

/// Whether the 4x4 luma block (or with 8x8 transforms its 8x8 block) has
/// non-zero coefficients.
fn coded(n: *const MbInfo, blk: u32) bool {
    if (n.flags & common.F_T8X8 != 0) return n.nz8 >> @intCast((blk >> 3) * 2 + ((blk & 3) >> 1)) & 1 != 0;
    return n.nnz[blk] != 0;
}

inline fn far(a: i32, b: i32, limit: i32) bool {
    return @abs(a - b) >= limit;
}

/// Whether the motion of two blocks differs as 8.7.2.1 counts it: other
/// pictures, another number of vectors, or vectors a sample apart (or
/// `limit` quarters vertically).
fn motionDiffers(p: *const MbInfo, pb: u32, q: *const MbInfo, qb: u32, limit: i32) bool {
    const p8 = (pb >> 3) * 2 + ((pb & 3) >> 1);
    const q8 = (qb >> 3) * 2 + ((qb & 3) >> 1);
    const pr = [2]u32{ p.ref_id[0][p8], p.ref_id[1][p8] };
    const qr = [2]u32{ q.ref_id[0][q8], q.ref_id[1][q8] };
    const pm = &p.mv;
    const qm = &q.mv;
    const M = struct {
        fn apart(a: [2]i16, b: [2]i16, lim: i32) bool {
            return far(a[0], b[0], 4) or far(a[1], b[1], lim);
        }
    };
    var v = pr[0] != qr[0];
    if (!v and pr[0] != 0) v = M.apart(pm[0][pb], qm[0][qb], limit);
    if (!v) v = pr[1] != qr[1] or M.apart(pm[1][pb], qm[1][qb], limit);
    if (!v) return false;
    if (pr[0] != qr[1] or pr[1] != qr[0]) return true;
    return M.apart(pm[0][pb], qm[1][qb], limit) or M.apart(pm[1][pb], qm[0][qb], limit);
}

/// bS of the line through 4x4 block `qb` of `q` and `pb` of `p`.
fn strength(db: *const Db, q: *const MbInfo, qb: u32, p: *const MbInfo, pb: u32, mb_edge: bool, vertical: bool) u8 {
    if (intraLike(p) or intraLike(q)) {
        if (mb_edge) {
            if (!isField(db, p) and !isField(db, q)) return 4;
            if ((db.mbaff or db.field_pic) and vertical) return 4;
        }
        return 3;
    }
    if (coded(q, qb) or coded(p, pb)) return 2;
    if (db.mbaff and (p.flags ^ q.flags) & common.F_FIELD != 0) return 1;
    const limit: i32 = if (isField(db, q)) 2 else 4;
    return @intFromBool(motionDiffers(p, pb, q, qb, limit));
}

/// A macroblock's bS of a picture without macroblock pairs, a 4x4 luma
/// block at a time, and its neighbours to the left and above.
const Strengths = struct {
    /// The vertical edges left to right, each block of one top to bottom;
    /// the horizontal edges top to bottom, each block across.
    v: [4][4]u8 = @splat(@splat(0)),
    h: [4][4]u8 = @splat(@splat(0)),
    left: ?u32 = null,
    top: ?u32 = null,
};

fn strengths(db: *const Db, cur: *const Cur) Strengths {
    const q = cur.info;
    var st: Strengths = .{
        .left = if (owner(db, cur, -1, 0, 16)) |o| o.xy else null,
        .top = if (owner(db, cur, 0, -1, 16)) |o| o.xy else null,
    };
    for (0..4) |e| {
        for (0..4) |b| {
            const e32: u32 = @intCast(e);
            const b32: u32 = @intCast(b);
            const qv = b32 * 4 + e32;
            if (e == 0) {
                if (st.left) |l| st.v[0][b] = strength(db, q, qv, &db.infos[l], b32 * 4 + 3, true, true);
            } else st.v[e][b] = strength(db, q, qv, q, qv - 1, false, true);
            const qh = e32 * 4 + b32;
            if (e == 0) {
                if (st.top) |t| st.h[0][b] = strength(db, q, qh, &db.infos[t], 12 + b32, true, false);
            } else st.h[e][b] = strength(db, q, qh, q, qh - 4, false, false);
        }
    }
    return st;
}

inline fn clip3(lo: i32, hi: i32, v: i32) i32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}

pub fn Deblock(comptime P: type) type {
    return struct {
        /// The thresholds of an edge, from the two macroblocks' QPs.
        const Limits = struct {
            alpha: i32,
            beta: i32,
            index_a: usize,
            scale: u5,
        };

        fn limits(cur: *const MbInfo, qp_p: i32, qp_q: i32, depth: u5) Limits {
            const av = (qp_p + qp_q + 1) >> 1;
            const ia: usize = @intCast(clip3(0, 51, av + cur.alpha_off));
            const ib: usize = @intCast(clip3(0, 51, av + cur.beta_off));
            const sc: u5 = depth - 8;
            return .{
                .alpha = @as(i32, tables.alpha[ia]) << sc,
                .beta = @as(i32, tables.beta[ib]) << sc,
                .index_a = ia,
                .scale = sc,
            };
        }

        /// One line across an edge: q0 at `q0`, the samples `d` apart.
        fn line(s: [*]P, q0: usize, d: usize, bs: u8, lim: Limits, chroma_style: bool, max: i32) void {
            const alpha = lim.alpha;
            const beta = lim.beta;
            const p0: i32 = s[q0 - d];
            const p1: i32 = s[q0 - 2 * d];
            const q0v: i32 = s[q0];
            const q1: i32 = s[q0 + d];
            if (!(@abs(p0 - q0v) < alpha and @abs(p1 - p0) < beta and @abs(q1 - q0v) < beta)) return;
            if (chroma_style) {
                if (bs < 4) {
                    const tc = (@as(i32, tables.tc0[lim.index_a][bs - 1]) << lim.scale) + 1;
                    const delta = clip3(-tc, tc, (((q0v - p0) << 2) + (p1 - q1) + 4) >> 3);
                    s[q0 - d] = @intCast(clip3(0, max, p0 + delta));
                    s[q0] = @intCast(clip3(0, max, q0v - delta));
                } else {
                    s[q0 - d] = @intCast((2 * p1 + p0 + q1 + 2) >> 2);
                    s[q0] = @intCast((2 * q1 + q0v + p1 + 2) >> 2);
                }
                return;
            }
            const p2: i32 = s[q0 - 3 * d];
            const q2: i32 = s[q0 + 2 * d];
            const ap = @abs(p2 - p0) < beta;
            const aq = @abs(q2 - q0v) < beta;
            if (bs < 4) {
                const tc0 = @as(i32, tables.tc0[lim.index_a][bs - 1]) << lim.scale;
                const tc = tc0 + @intFromBool(ap) + @intFromBool(aq);
                const delta = clip3(-tc, tc, (((q0v - p0) << 2) + (p1 - q1) + 4) >> 3);
                const avg = (p0 + q0v + 1) >> 1;
                if (ap) s[q0 - 2 * d] = @intCast(p1 + clip3(-tc0, tc0, (p2 + avg - (p1 << 1)) >> 1));
                if (aq) s[q0 + d] = @intCast(q1 + clip3(-tc0, tc0, (q2 + avg - (q1 << 1)) >> 1));
                s[q0 - d] = @intCast(clip3(0, max, p0 + delta));
                s[q0] = @intCast(clip3(0, max, q0v - delta));
                return;
            }
            const near = @abs(p0 - q0v) < ((alpha >> 2) + 2);
            if (ap and near) {
                const p3: i32 = s[q0 - 4 * d];
                s[q0 - d] = @intCast((p2 + 2 * p1 + 2 * p0 + 2 * q0v + q1 + 4) >> 3);
                s[q0 - 2 * d] = @intCast((p2 + p1 + p0 + q0v + 2) >> 2);
                s[q0 - 3 * d] = @intCast((2 * p3 + 3 * p2 + p1 + p0 + q0v + 4) >> 3);
            } else s[q0 - d] = @intCast((2 * p1 + p0 + q1 + 2) >> 2);
            if (aq and near) {
                const q3: i32 = s[q0 + 3 * d];
                s[q0] = @intCast((p1 + 2 * p0 + 2 * q0v + 2 * q1 + q2 + 4) >> 3);
                s[q0 + d] = @intCast((p0 + q0v + q1 + q2 + 2) >> 2);
                s[q0 + 2 * d] = @intCast((2 * q3 + 3 * q2 + q1 + q0v + p0 + 4) >> 3);
            } else s[q0] = @intCast((2 * q1 + q0v + p1 + 2) >> 2);
        }

        /// A plane as the edges of the current macroblock see it.
        const Plane = struct {
            s: [*]P,
            stride: usize,
            p: usize,
            /// Chroma of 4:2:0 or 4:2:2: its own filter, and its samples
            /// stand for SubWidthC x SubHeightC luma samples.
            chroma: bool,
            mbw: u32,
            mbh: u32,
            sw: u32,
            sh: u32,
            x0: usize,
            y0: usize,
            step: usize,
            depth: u5,
            max: i32,
        };

        fn qpOf(n: *const MbInfo, p: usize) i32 {
            return if (p == 0) n.qp else n.qpc[p - 1];
        }

        /// The whole picture, macroblock by macroblock.
        pub fn picture(db: *const Db) void {
            const w = db.width;
            if (db.field_pic) {
                const par: u32 = @intFromBool(db.bottom);
                for (0..db.rows / 2) |fy| {
                    for (0..w) |x| macroblock(db, @intCast(x), @intCast(2 * fy + par));
                }
            } else if (db.mbaff) {
                for (0..db.rows / 2) |py| {
                    for (0..w) |x| {
                        macroblock(db, @intCast(x), @intCast(2 * py));
                        macroblock(db, @intCast(x), @intCast(2 * py + 1));
                    }
                }
            } else {
                for (0..db.rows) |y| {
                    for (0..w) |x| macroblock(db, @intCast(x), @intCast(y));
                }
            }
        }

        fn macroblock(db: *const Db, mb_x: u32, mb_y: u32) void {
            const xy = mb_y * db.width + mb_x;
            const info = &db.infos[xy];
            if (info.slice < db.first_slice or info.filter == 1) return;
            const cur: Cur = .{
                .xy = xy,
                .mb_x = mb_x,
                .mb_y = mb_y,
                .field = db.field_pic or (db.mbaff and info.flags & common.F_FIELD != 0),
                .info = info,
            };
            const t8 = info.flags & common.F_T8X8 != 0;
            const st: ?Strengths = if (db.mbaff) null else strengths(db, &cur);
            const planes: usize = if (db.cat == 0) 1 else 3;
            for (0..planes) |p| {
                const chroma = p > 0 and db.cat != 3;
                const mbw: u32 = if (chroma) 8 else 16;
                const mbh: u32 = if (chroma) db.mbh_c else 16;
                const s = db.store;
                const depth = if (p == 0) db.depth_y else db.depth_c;
                var pl: Plane = .{
                    .s = @ptrCast(@alignCast(s.planes[p])),
                    .stride = s.stride[p],
                    .p = p,
                    .chroma = chroma,
                    .mbw = mbw,
                    .mbh = mbh,
                    .sw = if (chroma) 2 else 1,
                    .sh = if (chroma and db.cat == 1) 2 else 1,
                    .x0 = mb_x * mbw,
                    .y0 = undefined,
                    .step = if (cur.field) 2 else 1,
                    .depth = depth,
                    .max = (@as(i32, 1) << depth) - 1,
                };
                pl.y0 = if (cur.field) mbh * (mb_y & ~@as(u32, 1)) + (mb_y & 1) else mbh * mb_y;
                // Luma's internal edges are its transform's: every 4 or 8;
                // chroma's are always every 4.
                var e: u32 = 0;
                while (e < mbw) : (e += 4) {
                    if (!chroma and t8 and e & 4 != 0) continue;
                    if (st) |*known| verticalKnown(db, &cur, &pl, e, known) else vertical(db, &cur, &pl, e);
                }
                e = 0;
                while (e < mbh) : (e += 4) {
                    if (!chroma and t8 and e & 4 != 0) continue;
                    if (st) |*known| horizontalKnown(db, &cur, &pl, e, known) else horizontal(db, &cur, &pl, e);
                }
            }
        }

        /// A vertical edge whose strengths are known, as Strengths has
        /// them.
        fn verticalKnown(db: *const Db, cur: *const Cur, pl: *const Plane, xe: u32, st: *const Strengths) void {
            const bs = &st.v[(xe * pl.sw) >> 2];
            if (@as(u32, @bitCast(bs.*)) == 0) return;
            const q = cur.info;
            const pn = if (xe == 0) &db.infos[st.left orelse return] else q;
            const lim = limits(q, qpOf(pn, pl.p), qpOf(q, pl.p), pl.depth);
            for (0..pl.mbh) |k| {
                const b = bs[(k * pl.sh) >> 2];
                if (b == 0) continue;
                const q0 = (pl.y0 + pl.step * k) * pl.stride + pl.x0 + xe;
                line(pl.s, q0, 1, b, lim, pl.chroma, pl.max);
            }
        }

        /// A horizontal edge whose strengths are known.
        fn horizontalKnown(db: *const Db, cur: *const Cur, pl: *const Plane, ye: u32, st: *const Strengths) void {
            const bs = &st.h[(ye * pl.sh) >> 2];
            if (@as(u32, @bitCast(bs.*)) == 0) return;
            const q = cur.info;
            const pn = if (ye == 0) &db.infos[st.top orelse return] else q;
            const lim = limits(q, qpOf(pn, pl.p), qpOf(q, pl.p), pl.depth);
            const q0row = (pl.y0 + pl.step * ye) * pl.stride + pl.x0;
            const d = pl.step * pl.stride;
            for (0..pl.mbw) |k| {
                const b = bs[(k * pl.sw) >> 2];
                if (b == 0) continue;
                line(pl.s, q0row + k, d, b, lim, pl.chroma, pl.max);
            }
        }

        fn vertical(db: *const Db, cur: *const Cur, pl: *const Plane, xe: u32) void {
            const q = cur.info;
            const qqp = qpOf(q, pl.p);
            var last_xy: u32 = cur.xy;
            var lim = limits(q, qqp, qqp, pl.depth);
            if (xe == 0) last_xy = ~@as(u32, 0);
            for (0..pl.mbh) |k| {
                const kk: u32 = @intCast(k);
                var pn = q;
                var pxy = cur.xy;
                var prow = kk;
                if (xe == 0) {
                    const o = owner(db, cur, -1, @intCast(k), pl.mbh) orelse continue;
                    pxy = o.xy;
                    pn = &db.infos[o.xy];
                    prow = o.row;
                }
                const qb = blkOf(xe * pl.sw, kk * pl.sh);
                const pb = if (xe == 0) blkOf(15, prow * pl.sh) else blkOf(xe * pl.sw - 1, kk * pl.sh);
                const bs = strength(db, q, qb, pn, pb, xe == 0, true);
                if (bs == 0) continue;
                if (pxy != last_xy) {
                    lim = limits(q, qpOf(pn, pl.p), qqp, pl.depth);
                    last_xy = pxy;
                }
                const q0 = (pl.y0 + pl.step * k) * pl.stride + pl.x0 + xe;
                line(pl.s, q0, 1, bs, lim, pl.chroma, pl.max);
            }
        }

        fn horizontal(db: *const Db, cur: *const Cur, pl: *const Plane, ye: u32) void {
            const q = cur.info;
            const qqp = qpOf(q, pl.p);
            const w = db.width;
            if (ye == 0 and db.mbaff and !cur.field and cur.mb_y & 1 == 0 and cur.mb_y >= 2) {
                // A frame macroblock under a field pair: its top edge is
                // filtered as two fields, each against the field macroblock
                // of its parity above.
                const top = (cur.mb_y - 2) * w + cur.mb_x;
                if (usable(db, cur, top) and db.infos[top].flags & common.F_FIELD != 0) {
                    for (0..2) |j| {
                        const pxy = top + @as(u32, @intCast(j)) * w;
                        if (!usable(db, cur, pxy)) continue;
                        const pn = &db.infos[pxy];
                        const lim = limits(q, qpOf(pn, pl.p), qqp, pl.depth);
                        for (0..pl.mbw) |k| {
                            const kk: u32 = @intCast(k);
                            const bs = strength(db, q, blkOf(kk * pl.sw, 0), pn, blkOf(kk * pl.sw, 15), true, false);
                            if (bs == 0) continue;
                            const q0 = (pl.y0 + j) * pl.stride + pl.x0 + k;
                            line(pl.s, q0, 2 * pl.stride, bs, lim, pl.chroma, pl.max);
                        }
                    }
                    return;
                }
            }
            var pn = q;
            var prow: u32 = ye -% 1;
            if (ye == 0) {
                const o = owner(db, cur, 0, -1, pl.mbh) orelse return;
                pn = &db.infos[o.xy];
                prow = o.row;
            }
            const lim = limits(q, qpOf(pn, pl.p), qqp, pl.depth);
            const q0row = (pl.y0 + pl.step * ye) * pl.stride + pl.x0;
            for (0..pl.mbw) |k| {
                const kk: u32 = @intCast(k);
                const bs = strength(db, q, blkOf(kk * pl.sw, ye * pl.sh), pn, blkOf(kk * pl.sw, prow * pl.sh), ye == 0, false);
                if (bs == 0) continue;
                line(pl.s, q0row + k, pl.step * pl.stride, bs, lim, pl.chroma, pl.max);
            }
        }
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "an intra edge between two flat halves is smoothed, a coded inter one a little" {
    var y: [32 * 16]u8 = undefined;
    for (0..16) |r| {
        for (0..32) |c| y[r * 32 + c] = if (c < 16) 100 else 106;
    }
    var store: Store = .{};
    store.planes = .{ &y, &y, &y };
    store.stride = .{ 32, 16, 16 };
    var infos: [2]MbInfo = .{ .{ .slice = 1, .qp = 30, .flags = common.F_INTRA }, .{ .slice = 1, .qp = 30, .flags = common.F_INTRA } };
    const db: Db = .{ .store = &store, .infos = &infos, .width = 2, .rows = 1, .mbaff = false, .field_pic = false, .bottom = false, .first_slice = 1, .cat = 0, .mbh_c = 0, .depth_y = 8, .depth_c = 8 };
    Deblock(u8).picture(&db);
    // bS 4 at the macroblock edge: the step is spread over three samples.
    try testing.expect(y[15] > 100 and y[16] < 106);
    try testing.expect(y[13] > 100);
    // Rows are alike.
    try testing.expectEqual(y[15], y[5 * 32 + 15]);
    // An inter pair with the same motion and no coefficients: untouched.
    for (0..16) |r| {
        for (0..32) |c| y[r * 32 + c] = if (c < 16) 100 else 106;
    }
    infos[0].flags = 0;
    infos[1].flags = 0;
    Deblock(u8).picture(&db);
    try testing.expectEqual(@as(u8, 100), y[15]);
    infos[1].nnz[0] = 1;
    Deblock(u8).picture(&db);
    try testing.expect(y[15] > 100 and y[15] < 104);
}

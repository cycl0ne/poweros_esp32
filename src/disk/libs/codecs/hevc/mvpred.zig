// SPDX-License-Identifier: MIT
//! Motion vector prediction (8.5.3.2): the merge candidates of a
//! prediction block - its neighbours', the collocated picture's, their
//! pairs and zeros - and the predictor of a coded vector from the
//! neighbours' and the collocated picture's (AMVP).

const common = @import("common.zig");
const picture = @import("picture.zig");
const MvField = picture.MvField;

/// PartMode of an inter coding unit (Table 7-10).
pub const Part = enum(u3) { p2Nx2N, p2NxN, pNx2N, pNxN, p2NxnU, p2NxnD, pnLx2N, pnRx2N };

/// A prediction block and its coding block.
pub const Pu = struct {
    xcb: u32,
    ycb: u32,
    ncbs: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    part_idx: u32,
    part: Part,
};

/// What the prediction looks at besides the block.
pub const Ctx = struct {
    info: *const picture.Info,
    lists: *const picture.Lists,
    /// The current picture's order count.
    poc: i32,
    /// Log2ParMrgLevel.
    par_mrg: u3,
    max_merge: u8,
    b_slice: bool,
    /// slice_temporal_mvp_enabled_flag, and collocated_from_l0_flag.
    tmvp: bool,
    col_from_l0: bool,
};

inline fn clip3(lo: i32, hi: i32, v: i32) i32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}

/// A vector scaled by the ratio of two order count distances (8-179 to
/// 8-183): `td` the candidate's, `tb` the target's.
fn scale(mv: [2]i16, td_in: i32, tb_in: i32) [2]i16 {
    const td = clip3(-128, 127, td_in);
    const tb = clip3(-128, 127, tb_in);
    if (td == 0) return mv;
    const tx = @divTrunc(16384 + @as(i32, @intCast(@abs(td) >> 1)), td);
    const dsf = clip3(-4096, 4095, (tb * tx + 32) >> 6);
    var out: [2]i16 = undefined;
    for (0..2) |i| {
        const p = dsf * @as(i32, mv[i]);
        const m: i32 = @intCast((@abs(p) + 127) >> 8);
        out[i] = @intCast(clip3(-32768, 32767, if (p < 0) -m else m));
    }
    return out;
}

/// Whether the prediction block at (xn, yn) is available to `pu`
/// (6.4.2): decoded, and not intra.
fn availablePb(c: *const Ctx, pu: *const Pu, xn: i32, yn: i32) bool {
    const xcb: i32 = @intCast(pu.xcb);
    const ycb: i32 = @intCast(pu.ycb);
    const n: i32 = @intCast(pu.ncbs);
    var ok: bool = undefined;
    if (xn >= xcb and yn >= ycb and xn < xcb + n and yn < ycb + n) {
        // Inside the coding block: decoded, but for the second NxN block's
        // look at the third's.
        ok = !(pu.w << 1 == pu.ncbs and pu.h << 1 == pu.ncbs and pu.part_idx == 1 and
            ycb + @as(i32, @intCast(pu.h)) <= yn and xcb + @as(i32, @intCast(pu.w)) > xn);
    } else ok = c.info.available(pu.x, pu.y, xn, yn);
    if (!ok) return false;
    return c.info.cu(@intCast(xn), @intCast(yn)).flags & picture.cu_intra == 0;
}

inline fn fieldAt(c: *const Ctx, xn: i32, yn: i32) MvField {
    return c.info.mvf[c.info.at4(@intCast(xn), @intCast(yn))];
}

/// The collocated block's vector for list `x` and `ref_idx` from the
/// motion of the collocated picture at (xc, yc) (8.5.3.2.9).
fn colMv(c: *const Ctx, col: *const common.Store, xc: u32, yc: u32, x: usize, ref_idx: usize) ?[2]i16 {
    const w16 = (col.width[0] + 15) >> 4;
    const m = col.motion[(yc >> 4) * w16 + (xc >> 4)];
    if (m.flags & 3 == 0) return null;
    const lc: usize = if (m.flags & 1 == 0)
        1
    else if (m.flags & 2 == 0)
        0
    else if (c.lists.no_backward)
        x
    else
        @intFromBool(c.col_from_l0);
    const ref = c.lists.refs[x][ref_idx];
    const col_long = m.flags & (@as(u8, 4) << @intCast(lc)) != 0;
    if (ref.long != col_long) return null;
    const col_diff = col.poc - m.poc[lc];
    const cur_diff = c.poc - ref.poc;
    if (ref.long or col_diff == cur_diff) return m.mv[lc];
    return scale(m.mv[lc], col_diff, cur_diff);
}

/// The temporal predictor for list `x` and `ref_idx` (8.5.3.2.8): the
/// collocated picture's motion below and right of the block, else at
/// its centre.
fn temporal(c: *const Ctx, pu: *const Pu, x: usize, ref_idx: usize) ?[2]i16 {
    if (!c.tmvp) return null;
    const col = c.lists.col orelse return null;
    if (col.motion.len == 0) return null;
    const info = c.info;
    const xbr = pu.x + pu.w;
    const ybr = pu.y + pu.h;
    if (pu.y >> info.log2_ctb == ybr >> info.log2_ctb and ybr < info.height and xbr < info.width) {
        if (colMv(c, col, xbr, ybr, x, ref_idx)) |mv| return mv;
    }
    return colMv(c, col, pu.x + (pu.w >> 1), pu.y + (pu.h >> 1), x, ref_idx);
}

/// The merge candidate `idx` of `pu` (8.5.3.2.2 to 8.5.3.2.5), without
/// its pictures' store numbers.
pub fn merge(c: *const Ctx, pu_in: *const Pu, idx: u32) MvField {
    var pu = pu_in.*;
    if (c.par_mrg > 2 and pu.ncbs == 8) {
        pu.x = pu.xcb;
        pu.y = pu.ycb;
        pu.w = 8;
        pu.h = 8;
        pu.part_idx = 0;
    }
    var f = candidate(c, &pu, idx);
    // An 8x4 or 4x8 block predicts from one list (8-123).
    if (f.uses(0) and f.uses(1) and pu_in.w + pu_in.h == 12) {
        f.ref_idx[1] = -1;
        f.mv[1] = .{ 0, 0 };
    }
    return f;
}

fn candidate(c: *const Ctx, pu: *const Pu, idx: u32) MvField {
    var list: [5]MvField = undefined;
    var n: u32 = 0;
    const pm = c.par_mrg;
    const xp: i32 = @intCast(pu.x);
    const yp: i32 = @intCast(pu.y);
    const w: i32 = @intCast(pu.w);
    const h: i32 = @intCast(pu.h);
    const sameMer = struct {
        fn f(ax: i32, ay: i32, bx: i32, by: i32, s: u3) bool {
            return ax >> s == bx >> s and ay >> s == by >> s;
        }
    }.f;

    // A1, B1, B0, A0, B2 (8.5.3.2.3).
    const xa1 = xp - 1;
    const ya1 = yp + h - 1;
    const second = pu.part_idx == 1;
    var fa1: MvField = .{};
    const ava1 = !sameMer(xp, yp, xa1, ya1, pm) and
        !(second and (pu.part == .pNx2N or pu.part == .pnLx2N or pu.part == .pnRx2N)) and
        availablePb(c, pu, xa1, ya1);
    if (ava1) {
        fa1 = fieldAt(c, xa1, ya1);
        list[n] = fa1;
        n += 1;
        if (idx < n) return list[idx];
    }
    const xb1 = xp + w - 1;
    const yb1 = yp - 1;
    // The pruning compares with the neighbours that are available,
    // whether or not they became candidates.
    var fb1: MvField = .{};
    const avb1 = !sameMer(xp, yp, xb1, yb1, pm) and
        !(second and (pu.part == .p2NxN or pu.part == .p2NxnU or pu.part == .p2NxnD)) and
        availablePb(c, pu, xb1, yb1);
    if (avb1) {
        fb1 = fieldAt(c, xb1, yb1);
        if (!(ava1 and fa1.same(fb1))) {
            list[n] = fb1;
            n += 1;
            if (idx < n) return list[idx];
        }
    }
    const xb0 = xp + w;
    const yb0 = yp - 1;
    if (!sameMer(xp, yp, xb0, yb0, pm) and availablePb(c, pu, xb0, yb0)) {
        const f = fieldAt(c, xb0, yb0);
        if (!(avb1 and fb1.same(f))) {
            list[n] = f;
            n += 1;
            if (idx < n) return list[idx];
        }
    }
    const xa0 = xp - 1;
    const ya0 = yp + h;
    if (!sameMer(xp, yp, xa0, ya0, pm) and availablePb(c, pu, xa0, ya0)) {
        const f = fieldAt(c, xa0, ya0);
        if (!(ava1 and fa1.same(f))) {
            list[n] = f;
            n += 1;
            if (idx < n) return list[idx];
        }
    }
    if (n < 4) {
        const xb2 = xp - 1;
        const yb2 = yp - 1;
        if (!sameMer(xp, yp, xb2, yb2, pm) and availablePb(c, pu, xb2, yb2)) {
            const f = fieldAt(c, xb2, yb2);
            if (!(ava1 and fa1.same(f)) and !(avb1 and fb1.same(f))) {
                list[n] = f;
                n += 1;
                if (idx < n) return list[idx];
            }
        }
    }

    // The temporal candidate (8.5.3.2.2 step 3), reference index 0.
    var all: [5]MvField = undefined;
    @memcpy(all[0..n], list[0..n]);
    if (n < c.max_merge) {
        var col: MvField = .{};
        if (temporal(c, pu, 0, 0)) |mv| {
            col.mv[0] = mv;
            col.ref_idx[0] = 0;
        }
        if (c.b_slice) {
            if (temporal(c, pu, 1, 0)) |mv| {
                col.mv[1] = mv;
                col.ref_idx[1] = 0;
            }
        }
        if (col.uses(0) or col.uses(1)) {
            all[n] = col;
            n += 1;
            if (idx < n) return all[idx];
        }
    }

    // Pairs of them (8.5.3.2.4).
    const orig = n;
    if (c.b_slice and orig > 1 and orig < c.max_merge) {
        const l0_idx = [12]u8{ 0, 1, 0, 2, 1, 2, 0, 3, 1, 3, 2, 3 };
        const l1_idx = [12]u8{ 1, 0, 2, 0, 2, 1, 3, 0, 3, 1, 3, 2 };
        var comb: u32 = 0;
        while (true) {
            const a = all[l0_idx[comb]];
            const b = all[l1_idx[comb]];
            if (a.uses(0) and b.uses(1)) {
                const pa = c.lists.refs[0][@intCast(a.ref_idx[0])].poc;
                const pb = c.lists.refs[1][@intCast(b.ref_idx[1])].poc;
                if (pa != pb or @as(u32, @bitCast(a.mv[0])) != @as(u32, @bitCast(b.mv[1]))) {
                    if (n == idx) return .{ .mv = .{ a.mv[0], b.mv[1] }, .ref_idx = .{ a.ref_idx[0], b.ref_idx[1] } };
                    n += 1;
                }
            }
            comb += 1;
            if (comb == orig * (orig - 1) or n == c.max_merge) break;
        }
    }

    // Zeros (8.5.3.2.5).
    const num_ref: u32 = if (c.b_slice) @min(c.lists.count[0], c.lists.count[1]) else c.lists.count[0];
    const zero = idx - n;
    const r: i8 = if (zero < num_ref) @intCast(zero) else 0;
    return .{ .ref_idx = .{ r, if (c.b_slice) r else -1 } };
}

/// The neighbour at (xn, yn)'s vector for list `x` when it names the
/// picture `ref` names - from its list `x`, else from its other one.
fn unscaled(c: *const Ctx, f: MvField, x: usize, ref: picture.Ref) ?[2]i16 {
    const y = 1 - x;
    if (f.uses(x) and c.lists.refs[x][@intCast(f.ref_idx[x])].poc == ref.poc) return f.mv[x];
    if (f.uses(y) and c.lists.refs[y][@intCast(f.ref_idx[y])].poc == ref.poc) return f.mv[y];
    return null;
}

/// The neighbour's vector when its picture is a reference of the same
/// kind as `ref`'s, scaled to `ref`'s distance when both are short-term.
fn scaled(c: *const Ctx, f: MvField, x: usize, ref: picture.Ref) ?[2]i16 {
    const y = 1 - x;
    const from: ?struct { mv: [2]i16, ref: picture.Ref } = blk: {
        if (f.uses(x)) {
            const r = c.lists.refs[x][@intCast(f.ref_idx[x])];
            if (r.long == ref.long) break :blk .{ .mv = f.mv[x], .ref = r };
        }
        if (f.uses(y)) {
            const r = c.lists.refs[y][@intCast(f.ref_idx[y])];
            if (r.long == ref.long) break :blk .{ .mv = f.mv[y], .ref = r };
        }
        break :blk null;
    };
    const a = from orelse return null;
    if (a.ref.poc == ref.poc or a.ref.long or ref.long) return a.mv;
    return scale(a.mv, c.poc - a.ref.poc, c.poc - ref.poc);
}

/// mvpLX of `pu` for list `x` and `ref_idx`: the candidate `flag` of the
/// predictor list (8.5.3.2.6, 8.5.3.2.7).
pub fn amvp(c: *const Ctx, pu: *const Pu, x: usize, ref_idx: usize, flag: u1) [2]i16 {
    const ref = c.lists.refs[x][ref_idx];
    const xp: i32 = @intCast(pu.x);
    const yp: i32 = @intCast(pu.y);
    const w: i32 = @intCast(pu.w);
    const h: i32 = @intCast(pu.h);

    const as = [2][2]i32{ .{ xp - 1, yp + h }, .{ xp - 1, yp + h - 1 } };
    var ava: [2]bool = undefined;
    for (as, 0..) |p, k| ava[k] = availablePb(c, pu, p[0], p[1]);
    const is_scaled = ava[0] or ava[1];
    var a: ?[2]i16 = null;
    for (as, 0..) |p, k| {
        if (ava[k] and a == null) a = unscaled(c, fieldAt(c, p[0], p[1]), x, ref);
    }
    if (a == null) {
        for (as, 0..) |p, k| {
            if (ava[k] and a == null) a = scaled(c, fieldAt(c, p[0], p[1]), x, ref);
        }
    }

    const bs = [3][2]i32{ .{ xp + w, yp - 1 }, .{ xp + w - 1, yp - 1 }, .{ xp - 1, yp - 1 } };
    var avb: [3]bool = undefined;
    for (bs, 0..) |p, k| avb[k] = availablePb(c, pu, p[0], p[1]);
    var b: ?[2]i16 = null;
    for (bs, 0..) |p, k| {
        if (avb[k] and b == null) b = unscaled(c, fieldAt(c, p[0], p[1]), x, ref);
    }
    if (!is_scaled) {
        if (b != null) a = b;
        b = null;
        for (bs, 0..) |p, k| {
            if (avb[k] and b == null) b = scaled(c, fieldAt(c, p[0], p[1]), x, ref);
        }
    }

    var list: [2][2]i16 = undefined;
    var i: u32 = 0;
    if (a) |va| {
        list[i] = va;
        i += 1;
        if (b) |vb| {
            if (@as(u32, @bitCast(va)) != @as(u32, @bitCast(vb))) {
                list[i] = vb;
                i += 1;
            }
        }
    } else if (b) |vb| {
        list[i] = vb;
        i += 1;
    }
    if (flag < i) return list[flag];
    // The temporal candidate fills the next place, zeros the rest.
    if (flag == i) {
        if (temporal(c, pu, x, ref_idx)) |mv| return mv;
    }
    return .{ 0, 0 };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "vector scaling" {
    // The same distance keeps the vector.
    try testing.expectEqual([2]i16{ 13, -7 }, scale(.{ 13, -7 }, 3, 3));
    // Twice the distance doubles it, half halves it (rounding away).
    try testing.expectEqual([2]i16{ 26, -14 }, scale(.{ 13, -7 }, 1, 2));
    try testing.expectEqual([2]i16{ 6, -3 }, scale(.{ 13, -7 }, 2, 1));
    // The other direction turns it round.
    try testing.expectEqual([2]i16{ -13, 7 }, scale(.{ 13, -7 }, 1, -1));
}

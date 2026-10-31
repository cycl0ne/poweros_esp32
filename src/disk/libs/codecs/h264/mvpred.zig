// SPDX-License-Identifier: MIT
//! Motion vectors and reference indices of an inter macroblock (8.4.1):
//! the prediction from the neighbours (8.4.1.3), P_Skip's (8.4.1.1), and
//! B's direct modes, spatial and temporal (8.4.1.2), with the colocated
//! macroblock of the first picture of list 1.
//!
//! A neighbour's motion is taken in the current macroblock's terms: a
//! frame macroblock sees a field neighbour's vertical component doubled
//! and its index halved, a field macroblock a frame neighbour's the other
//! way round (8.4.1.3.1).

const common = @import("common.zig");
const MbInfo = common.MbInfo;
const Motion = common.Motion;
const RefPic = common.RefPic;
const Store = common.Store;
const mbm = @import("mb.zig");
const Dec = mbm.Dec;
const Mb = mbm.Mb;
const Error = @import("bits.zig").Error;

/// What a slice's motion is derived with.
pub const Ctx = struct {
    /// The reference lists as the slice built them: frames for a frame
    /// picture, fields for a field picture.
    lists: *const [2][33]RefPic,
    /// The current picture: its store, 1 top / 2 bottom / 3 frame.
    cur: *Store,
    structure: u2,
    direct_spatial: bool = true,
    direct_8x8_inference: bool = true,
    /// For B slices: the colocated picture (RefPicList1[0]), which of its
    /// fields a frame macroblock takes (C.4's closer one), and the row
    /// offset of a field picture's colocated field of the other parity.
    col: ?RefPic = null,
    col_parity: u1 = 0,
    col_fieldoff: i32 = 0,
    /// With separate colour planes, where the slice's plane's macroblocks
    /// begin in a store's motion.
    motion_base: usize = 0,
    /// A picture decoded on a worker: how it waits for the colocated
    /// picture's rows.
    sync: ?*const common.Sync = null,
};

/// A neighbouring 4x4 block's motion for one list: ref -2 when it is not
/// there, -1 when it does not use the list.
const Cell = struct { ref: i32 = -2, mv: [2]i32 = .{ 0, 0 } };

/// The reference picture of an index in the current macroblock's terms:
/// a field macroblock of a frame indexes the fields of the frame list,
/// its own parity first (8.4.2.1).
pub fn refPic(ctx: *const Ctx, d: *const Dec, list: usize, idx: i32) RefPic {
    if (idx < 0) return .{};
    const i: usize = @intCast(idx);
    if (d.mbaff and d.field) {
        const fr = ctx.lists[list][i >> 1];
        if (fr.store == null) return .{};
        const own: u2 = if (d.mb_y & 1 != 0) 2 else 1;
        return .{ .store = fr.store, .structure = if (i & 1 == 0) own else 3 - own, .long = fr.long };
    }
    return ctx.lists[list][i];
}

/// The picture order count of the current picture as a macroblock sees it.
fn curPoc(ctx: *const Ctx, d: *const Dec) i32 {
    const s = ctx.cur;
    if (ctx.structure == 1) return s.poc[0];
    if (ctx.structure == 2) return s.poc[1];
    if (d.mbaff and d.field) return s.poc[d.mb_y & 1];
    return @min(s.poc[0], s.poc[1]);
}

/// DistScaleFactor (8.4.1.2.3) of the current picture between pic0 and
/// pic1; null when the temporal scaling does not apply (pic0 long-term or
/// both at one time).
fn distScale(cur_poc: i32, pic0: RefPic, pic1: RefPic) ?i32 {
    if (pic0.store == null or pic1.store == null) return null;
    const p0 = pic0.poc();
    const td = clip3(-128, 127, pic1.poc() - p0);
    if (td == 0 or pic0.long) return null;
    const tb = clip3(-128, 127, cur_poc - p0);
    const tx = @divTrunc(16384 + @as(i32, @intCast(@abs(@divTrunc(td, 2)))), td);
    return clip3(-1024, 1023, (tb * tx + 32) >> 6);
}

/// The implicit weights of a pair of references (8.4.2.3.1): w0, w1.
pub fn implicitWeights(ctx: *const Ctx, d: *const Dec, ref0: i32, ref1: i32) [2]i32 {
    const pic0 = refPic(ctx, d, 0, ref0);
    const pic1 = refPic(ctx, d, 1, ref1);
    if (pic0.store == null or pic1.store == null or pic1.long) return .{ 32, 32 };
    const dsf = distScale(curPoc(ctx, d), pic0, pic1) orelse return .{ 32, 32 };
    const w1 = dsf >> 2;
    if (w1 < -64 or w1 > 128) return .{ 32, 32 };
    return .{ 64 - w1, w1 };
}

inline fn clip3(lo: i32, hi: i32, v: i32) i32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}

inline fn median(a: i32, b: i32, c: i32) i32 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

/// The motion of the current macroblock as it is derived, with its
/// neighbours'.
const Tab = struct {
    left: [2][4]Cell = @splat(@splat(.{})),
    top: [2][4]Cell = @splat(@splat(.{})),
    c: [2]Cell = @splat(.{}),
    d: [2]Cell = @splat(.{}),
    /// Above left of the rows 1 to 3 of the left column (their own
    /// neighbour in MBAFF; elsewhere the left cell a row up).
    dleft: [2][4]Cell = @splat(@splat(.{})),
    cur: [2][16]Cell = @splat(@splat(.{})),

    fn get(t: *const Tab, list: usize, x: i32, y: i32) Cell {
        if (y < 0) {
            if (x < 0) return t.d[list];
            if (x >= 4) return t.c[list];
            return t.top[list][@intCast(x)];
        }
        if (x < 0) return t.left[list][@intCast(y)];
        if (x >= 4) return .{};
        return t.cur[list][@intCast(y * 4 + x)];
    }

    fn diag(t: *const Tab, list: usize, x: i32, y: i32) Cell {
        if (x == 0 and y > 0) return t.dleft[list][@intCast(y)];
        return t.get(list, x - 1, y - 1);
    }

    /// mvpLX of a partition at (x, y), `w` blocks wide (8.4.1.3).
    fn pred(t: *const Tab, list: usize, ref: i32, x: i32, y: i32, w: i32, shape: mbm.Shape, part: u32) [2]i32 {
        const a = t.get(list, x - 1, y);
        var b = t.get(list, x, y - 1);
        var c = t.get(list, x + w, y - 1);
        if (c.ref == -2) c = t.diag(list, x, y);
        if (b.ref == -2 and c.ref == -2 and a.ref != -2) {
            b = a;
            c = a;
        }
        switch (shape) {
            .p16x8 => {
                if (part == 0 and b.ref == ref) return b.mv;
                if (part == 1 and a.ref == ref) return a.mv;
            },
            .p8x16 => {
                if (part == 0 and a.ref == ref) return a.mv;
                if (part == 1 and c.ref == ref) return c.mv;
            },
            else => {},
        }
        const ma = a.ref == ref;
        const mb_ = b.ref == ref;
        const mc = c.ref == ref;
        const n = @as(u32, @intFromBool(ma)) + @intFromBool(mb_) + @intFromBool(mc);
        if (n == 1) {
            if (ma) return a.mv;
            if (mb_) return b.mv;
            return c.mv;
        }
        return .{ median(a.mv[0], b.mv[0], c.mv[0]), median(a.mv[1], b.mv[1], c.mv[1]) };
    }

    fn fill(t: *Tab, list: usize, x: u32, y: u32, w: u32, h: u32, cell: Cell) void {
        for (y..y + h) |yy| {
            for (x..x + w) |xx| t.cur[list][yy * 4 + xx] = cell;
        }
    }
};

fn cellOf(d: *const Dec, xy: u32, row: u32, col: u32, list: usize) Cell {
    const n = d.info(xy);
    if (n.flags & common.F_INTRA != 0) return .{ .ref = -1 };
    const b8 = (row >> 1) * 2 + (col >> 1);
    var r: i32 = n.ref[list][b8];
    if (r < 0) return .{ .ref = -1 };
    var mv: [2]i32 = .{ n.mv[list][row * 4 + col][0], n.mv[list][row * 4 + col][1] };
    if (d.mbaff) {
        const nf = n.flags & common.F_FIELD != 0;
        if (d.field and !nf) {
            mv[1] = @divTrunc(mv[1], 2);
            r *= 2;
        } else if (!d.field and nf) {
            mv[1] *= 2;
            r >>= 1;
        }
    }
    return .{ .ref = r, .mv = mv };
}

fn neighbourTab(d: *const Dec, t: *Tab) void {
    for (0..2) |list| {
        for (0..4) |y| {
            if (d.nb.left[y]) |s| t.left[list][y] = cellOf(d, s.xy, s.row, 3, list);
        }
        if (d.nb.b) |xy| {
            for (0..4) |x| t.top[list][x] = cellOf(d, xy, 3, @intCast(x), list);
        }
        if (d.nb.c) |xy| t.c[list] = cellOf(d, xy, 3, 0, list);
        if (d.nb.d) |s| t.d[list] = cellOf(d, s.xy, s.row, 3, list);
        for (1..4) |y| {
            if (!d.mbaff) {
                t.dleft[list][y] = t.left[list][y - 1];
            } else if (d.owner(-1, @intCast(4 * y - 1), 16)) |o| {
                t.dleft[list][y] = cellOf(d, o.xy, o.row >> 2, 3, list);
            }
        }
    }
}

/// The motion of each 4x4 block (raster) of the current macroblock, both
/// lists, as derived.
pub const Out = struct {
    ref: [2][4]i8 = @splat(@splat(-1)),
    mv: [2][16][2]i32 = @splat(@splat(.{ 0, 0 })),
};

/// The motion of an inter macroblock - skipped or not - into `out`.
pub fn derive(ctx: *const Ctx, d: *const Dec, m: *const Mb, out: *Out) Error!void {
    var t: Tab = .{};
    neighbourTab(d, &t);
    out.* = .{};
    const b_slice = d.hdr.kind == .b;
    if (m.skip and !b_slice) {
        // P_Skip (8.4.1.1).
        const a = t.get(0, -1, 0);
        const b = t.get(0, 0, -1);
        var mv: [2]i32 = .{ 0, 0 };
        const zero = a.ref == -2 or b.ref == -2 or
            (a.ref == 0 and a.mv[0] == 0 and a.mv[1] == 0) or
            (b.ref == 0 and b.mv[0] == 0 and b.mv[1] == 0);
        if (!zero) mv = t.pred(0, 0, 0, 0, 4, .p16x16, 0);
        out.ref[0] = @splat(0);
        for (0..16) |i| out.mv[0][i] = mv;
        return;
    }
    var dir: Direct = .{};
    if (m.direct != 0) try direct(ctx, d, &t, &dir);

    switch (m.shape) {
        .p16x16, .p16x8, .p8x16 => {
            const parts: u32 = if (m.shape == .p16x16) 1 else 2;
            const w = mbm.partW(m.shape);
            const h = mbm.partH(m.shape);
            for (0..parts) |pi| {
                const p: u32 = @intCast(pi);
                const x, const y = mbm.partOrigin(m.shape, p);
                for (0..2) |list| {
                    if (m.pred[p] >> @intCast(list) & 1 == 0) {
                        t.fill(list, x, y, w, h, .{ .ref = -1 });
                        continue;
                    }
                    const b8 = (y >> 1) * 2 + (x >> 1);
                    const ref: i32 = m.ref[list][b8];
                    const mvp = t.pred(list, ref, @intCast(x), @intCast(y), @intCast(w), m.shape, p);
                    const mvd = m.mvd[list][y * 4 + x];
                    t.fill(list, x, y, w, h, .{ .ref = ref, .mv = .{ mvp[0] +% mvd[0], mvp[1] +% mvd[1] } });
                }
            }
        },
        .p8x8 => {
            for (0..4) |si| {
                const s: u32 = @intCast(si);
                const x0 = (s & 1) * 2;
                const y0 = (s >> 1) * 2;
                if (m.direct >> @intCast(s) & 1 != 0) {
                    for (0..2) |list| {
                        for ([4]u32{ 0, 1, 4, 5 }) |o| {
                            const cell = y0 * 4 + x0 + o;
                            t.cur[list][cell] = .{ .ref = dir.ref[list][s], .mv = dir.mv[list][cell] };
                        }
                    }
                    continue;
                }
                const w: u32 = if (m.sub[s] == .s8x8 or m.sub[s] == .s8x4) 2 else 1;
                const h: u32 = if (m.sub[s] == .s8x8 or m.sub[s] == .s4x8) 2 else 1;
                // Sub-partitions in their order, both lists for each.
                var y = y0;
                while (y < y0 + 2) : (y += h) {
                    var x = x0;
                    while (x < x0 + 2) : (x += w) {
                        for (0..2) |list| {
                            if (m.pred[s] >> @intCast(list) & 1 == 0) {
                                t.fill(list, x, y, w, h, .{ .ref = -1 });
                                continue;
                            }
                            const ref: i32 = m.ref[list][s];
                            const mvp = t.pred(list, ref, @intCast(x), @intCast(y), @intCast(w), .p8x8, 0);
                            const mvd = m.mvd[list][y * 4 + x];
                            t.fill(list, x, y, w, h, .{ .ref = ref, .mv = .{ mvp[0] +% mvd[0], mvp[1] +% mvd[1] } });
                        }
                    }
                }
            }
        },
    }
    for (0..2) |list| {
        for (0..4) |b8| {
            const cell = (b8 >> 1) * 8 + (b8 & 1) * 2;
            const r = t.cur[list][cell].ref;
            out.ref[list][b8] = if (r < 0) -1 else @intCast(r);
        }
        for (0..16) |i| out.mv[list][i] = t.cur[list][i].mv;
    }
}

/// The direct prediction of each 8x8 block: its references and the
/// motion of its 4x4 blocks.
const Direct = struct {
    ref: [2][4]i32 = @splat(@splat(-1)),
    mv: [2][16][2]i32 = @splat(@splat(.{ 0, 0 })),
};

/// The colocated block of 4x4 block (bx, by) (8.4.1.2.1): its motion
/// as stored, and how its vertical motion is to be scaled.
const ColBlock = struct {
    m: *const Motion,
    b8: u32,
    b4: u32,
    scale: enum { one, frm_to_fld, fld_to_frm },
};

fn colocated(ctx: *const Ctx, d: *const Dec, bx: u32, by: u32) ?ColBlock {
    const col = ctx.col orelse return null;
    const s = col.store orelse return null;
    if (s.motion.len == 0) return null;
    const motion = s.motion[ctx.motion_base..];
    const w = d.width;
    const x8 = bx >> 1;
    const y8 = by >> 1;
    // With the 8x8 inference the corner block of each 8x8 stands for it.
    const cx = if (ctx.direct_8x8_inference) x8 * 3 else bx;
    const cy = if (ctx.direct_8x8_inference) y8 * 3 else by;
    const here = &motion[d.mb_y * w + d.mb_x];
    const cur_field = d.field;
    if (here.field) {
        if (!cur_field) {
            const row = (d.mb_y & ~@as(u32, 1)) + ctx.col_parity;
            const half = d.mb_y & 1;
            return .{ .m = &motion[row * w + d.mb_x], .b8 = 2 * half + x8, .b4 = (2 * half + y8) * 4 + x8 * 3, .scale = .fld_to_frm };
        }
        const row: i32 = @as(i32, @intCast(d.mb_y)) + ctx.col_fieldoff;
        const rr: u32 = @intCast(@max(0, row));
        return .{ .m = &motion[rr * w + d.mb_x], .b8 = y8 * 2 + x8, .b4 = cy * 4 + cx, .scale = .one };
    }
    if (cur_field) {
        const top = (d.mb_y & ~@as(u32, 1)) * w + d.mb_x;
        return .{ .m = &motion[top + y8 * w], .b8 = y8 * 2 + x8, .b4 = (y8 * 2) * 4 + x8 * 3, .scale = .frm_to_fld };
    }
    return .{ .m = here, .b8 = y8 * 2 + x8, .b4 = cy * 4 + cx, .scale = .one };
}

fn direct(ctx: *const Ctx, d: *const Dec, t: *const Tab, out: *Direct) Error!void {
    if (ctx.sync) |sy| {
        if (ctx.col) |c| {
            // The colocated macroblock's motion is final with its row.
            if (c.store) |s| sy.rows(s, @min((d.mb_y | 1) + 1, s.height[0] >> 4));
        }
    }
    if (ctx.direct_spatial) return spatial(ctx, d, t, out);
    return temporal(ctx, d, out);
}

fn minPositive(a: i32, b: i32) i32 {
    return if (a >= 0 and b >= 0) @min(a, b) else @max(a, b);
}

fn spatial(ctx: *const Ctx, d: *const Dec, t: *const Tab, out: *Direct) Error!void {
    var ref: [2]i32 = undefined;
    var mv: [2][2]i32 = .{ .{ 0, 0 }, .{ 0, 0 } };
    for (0..2) |list| {
        const a = t.get(list, -1, 0);
        const b = t.get(list, 0, -1);
        var c = t.get(list, 4, -1);
        if (c.ref == -2) c = t.get(list, -1, -1);
        ref[list] = minPositive(a.ref, minPositive(b.ref, c.ref));
    }
    if (ref[0] < 0 and ref[1] < 0) {
        out.ref = .{ @splat(0), @splat(0) };
        return;
    }
    for (0..2) |list| {
        if (ref[list] >= 0) mv[list] = t.pred(list, ref[list], 0, 0, 4, .p16x16, 0);
    }
    const col_short = if (ctx.col) |c| !c.long else false;
    for (0..4) |b8| {
        for (0..2) |list| out.ref[list][b8] = if (ref[list] < 0) -1 else ref[list];
        const x8: u32 = @intCast(b8 & 1);
        const y8: u32 = @intCast(b8 >> 1);
        for ([4]u32{ 0, 1, 4, 5 }) |o| {
            const cell = y8 * 8 + x8 * 2 + o;
            const bx = cell & 3;
            const by = cell >> 2;
            var zero = false;
            if (col_short) {
                if (colocated(ctx, d, bx, by)) |cb| {
                    if (!cb.m.intra) {
                        var r = cb.m.ref[0][cb.b8];
                        var cmv = cb.m.mv[0][cb.b4];
                        if (r < 0) {
                            r = cb.m.ref[1][cb.b8];
                            cmv = cb.m.mv[1][cb.b4];
                        }
                        zero = r == 0 and @abs(cmv[0]) <= 1 and @abs(cmv[1]) <= 1;
                    }
                }
            }
            for (0..2) |list| {
                if (ref[list] < 0 or (ref[list] == 0 and zero)) {
                    out.mv[list][cell] = .{ 0, 0 };
                } else out.mv[list][cell] = mv[list];
            }
        }
    }
}

/// MapColToList0 (8.4.1.2.3): the lowest index of list 0 that refers to
/// the colocated block's reference, in the current macroblock's terms.
fn mapColToList0(ctx: *const Ctx, d: *const Dec, ref_id: u32, scale: anytype) i32 {
    const uid = ref_id >> 2;
    var want: u32 = ref_id;
    switch (scale) {
        .one => {},
        .frm_to_fld => {
            const parity: u32 = if (ctx.structure != 3) ctx.structure else if (d.mb_y & 1 != 0) 2 else 1;
            want = uid << 2 | parity;
        },
        .fld_to_frm => want = uid << 2 | 3,
    }
    const n: u32 = if (d.mbaff and d.field) 2 * @as(u32, d.hdr.num_ref_idx[0]) else d.hdr.num_ref_idx[0];
    for (0..n) |i| {
        if (refPic(ctx, d, 0, @intCast(i)).id() == want) return @intCast(i);
    }
    return 0;
}

fn temporal(ctx: *const Ctx, d: *const Dec, out: *Direct) Error!void {
    const cur_poc = curPoc(ctx, d);
    const pic1 = refPic(ctx, d, 1, 0);
    for (0..4) |b8| {
        const x8: u32 = @intCast(b8 & 1);
        const y8: u32 = @intCast(b8 >> 1);
        out.ref[1][b8] = 0;
        var ref0: i32 = 0;
        for ([4]u32{ 0, 1, 4, 5 }) |o| {
            const cell = y8 * 8 + x8 * 2 + o;
            const cb = colocated(ctx, d, cell & 3, cell >> 2) orelse {
                out.ref[0][b8] = 0;
                continue;
            };
            if (cb.m.intra) {
                ref0 = 0;
                out.mv[0][cell] = .{ 0, 0 };
                out.mv[1][cell] = .{ 0, 0 };
                continue;
            }
            var list: usize = 0;
            if (cb.m.ref[0][cb.b8] < 0) list = 1;
            var cmv: [2]i32 = .{ cb.m.mv[list][cb.b4][0], cb.m.mv[list][cb.b4][1] };
            switch (cb.scale) {
                .frm_to_fld => cmv[1] = @divTrunc(cmv[1], 2),
                .fld_to_frm => cmv[1] *= 2,
                .one => {},
            }
            ref0 = mapColToList0(ctx, d, cb.m.ref_id[list][cb.b8], cb.scale);
            const pic0 = refPic(ctx, d, 0, ref0);
            if (distScale(cur_poc, pic0, pic1)) |dsf| {
                const m0: [2]i32 = .{ (dsf * cmv[0] + 128) >> 8, (dsf * cmv[1] + 128) >> 8 };
                out.mv[0][cell] = m0;
                out.mv[1][cell] = .{ m0[0] - cmv[0], m0[1] - cmv[1] };
            } else {
                out.mv[0][cell] = cmv;
                out.mv[1][cell] = .{ 0, 0 };
            }
        }
        out.ref[0][b8] = ref0;
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the median, MinPositive, and DistScaleFactor of a B picture halfway" {
    try testing.expectEqual(@as(i32, 3), median(1, 3, 7));
    try testing.expectEqual(@as(i32, -2), median(-2, -5, 4));
    try testing.expectEqual(@as(i32, 1), minPositive(1, 4));
    try testing.expectEqual(@as(i32, -1), minPositive(-2, -1));
    try testing.expectEqual(@as(i32, 3), minPositive(-1, 3));
    var s0: Store = .{ .poc = .{ 0, 0 }, .fields = 3 };
    var s1: Store = .{ .poc = .{ 8, 8 }, .fields = 3 };
    // Current at 4, between 0 and 8: the scale is a half (128 of 256).
    try testing.expectEqual(@as(?i32, 128), distScale(4, .{ .store = &s0 }, .{ .store = &s1 }));
    _ = &derive;
    _ = &implicitWeights;
}

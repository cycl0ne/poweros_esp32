// SPDX-License-Identifier: MIT
//! The macroblock headers of a row (RFC 6386 11, 16, 17), from the first
//! partition: segment, skip flag, intra modes or the reference and motion
//! vectors.

const common = @import("common.zig");
const tables = @import("tables.zig");
const Bool = @import("bool.zig").Bool;
const MbInfo = common.MbInfo;
const Mv = common.Mv;

/// What a row's headers are read with.
pub const Ctx = struct {
    hdr: *const common.Header,
    probs: *const common.Probs,
    seg: *const common.Segmentation,
    /// Each macroblock's segment, which stays until a frame gives it
    /// anew.
    segments: []u8,
    mbs: []MbInfo,
    cols: u32,
    rows: u32,
};

/// The subblock mode a 16x16 intra mode stands for to its neighbours.
fn impliedMode(y_mode: u8) u8 {
    return switch (y_mode) {
        common.V_PRED => common.B_VE_PRED,
        common.H_PRED => common.B_HE_PRED,
        common.TM_PRED => common.B_TM_PRED,
        else => common.B_DC_PRED,
    };
}

/// The headers of macroblock row `r`.
pub fn row(m: *const Ctx, b: *Bool, r: u32) void {
    const hdr = m.hdr;
    for (0..m.cols) |cu| {
        const c: u32 = @intCast(cu);
        const i = r * m.cols + c;
        const mb = &m.mbs[i];
        if (m.seg.update_map) {
            m.segments[i] = b.tree(&tables.segment_tree, &m.seg.tree_probs);
        } else if (hdr.key) m.segments[i] = 0;
        mb.segment = m.segments[i];
        mb.skip = if (hdr.skip_enabled) b.read(hdr.prob_skip) == 1 else false;
        if (hdr.key) {
            keyModes(m, b, mb, r, c);
        } else if (b.read(hdr.prob_intra) == 1) {
            interModes(m, b, mb, r, c);
        } else {
            mb.y_mode = b.tree(&tables.y_mode_tree, &m.probs.y_mode);
            if (mb.y_mode == common.B_PRED) {
                for (&mb.b_modes) |*mode| mode.* = b.tree(&tables.b_mode_tree, &tables.b_mode_probs);
            } else mb.b_modes = @splat(impliedMode(mb.y_mode));
            mb.uv_mode = b.tree(&tables.uv_mode_tree, &m.probs.uv_mode);
            mb.ref = common.INTRA;
            mb.mv = .{};
        }
    }
}

/// A key frame's modes, its subblock modes by those above and to the
/// left: outside the frame B_DC_PRED.
fn keyModes(m: *const Ctx, b: *Bool, mb: *MbInfo, r: u32, c: u32) void {
    mb.y_mode = b.tree(&tables.kf_y_mode_tree, &tables.kf_y_mode_probs);
    if (mb.y_mode == common.B_PRED) {
        const above: ?*const MbInfo = if (r > 0) &m.mbs[(r - 1) * m.cols + c] else null;
        const left: ?*const MbInfo = if (c > 0) &m.mbs[r * m.cols + c - 1] else null;
        for (0..16) |i| {
            const a = if (i >= 4) mb.b_modes[i - 4] else if (above) |n| n.b_modes[i + 12] else common.B_DC_PRED;
            const l = if (i & 3 != 0) mb.b_modes[i - 1] else if (left) |n| n.b_modes[i + 3] else common.B_DC_PRED;
            mb.b_modes[i] = b.tree(&tables.b_mode_tree, &tables.kf_b_mode_probs[a][l]);
        }
    } else mb.b_modes = @splat(impliedMode(mb.y_mode));
    mb.uv_mode = b.tree(&tables.uv_mode_tree, &tables.kf_uv_mode_probs);
    mb.ref = common.INTRA;
    mb.mv = .{};
}

/// How far a vector may point past the frame: a macroblock's width
/// beyond its edges, in quarter samples.
const Bounds = struct {
    left: i32,
    right: i32,
    top: i32,
    bottom: i32,

    fn clamp(bd: Bounds, v: Mv) Mv {
        return .{
            .x = @truncate(@max(bd.left, @min(bd.right, @as(i32, v.x)))),
            .y = @truncate(@max(bd.top, @min(bd.bottom, @as(i32, v.y)))),
        };
    }
};

/// A neighbour's vector as this macroblock's reference sees it: turned
/// round when the two references' sign biases differ.
fn biased(hdr: *const common.Header, n: *const MbInfo, ref: u8) Mv {
    var v = n.mv;
    if (hdr.sign_bias[n.ref] != hdr.sign_bias[ref]) {
        v.x = -%v.x;
        v.y = -%v.y;
    }
    return v;
}

/// An inter macroblock's reference, mode and vectors.
fn interModes(m: *const Ctx, b: *Bool, mb: *MbInfo, r: u32, c: u32) void {
    const hdr = m.hdr;
    mb.ref = if (b.read(hdr.prob_last) == 1) common.GOLDEN + @as(u8, b.read(hdr.prob_golden)) else common.LAST;

    const above: ?*const MbInfo = if (r > 0) &m.mbs[(r - 1) * m.cols + c] else null;
    const left: ?*const MbInfo = if (c > 0) &m.mbs[r * m.cols + c - 1] else null;
    const above_left: ?*const MbInfo = if (r > 0 and c > 0) &m.mbs[(r - 1) * m.cols + c - 1] else null;

    // The candidates (16.3): the neighbours' vectors, alike ones counted
    // together - above and left weighing 2, above-left 1. [0] is zero's
    // count and then the best vector; [1] nearest, [2] near, [3] a third.
    var near: [4]Mv = @splat(.{});
    var cnt: [4]u8 = .{ 0, 0, 0, 0 };
    var at: usize = 0;
    if (above) |n| if (n.ref != common.INTRA) {
        if (!n.mv.isZero()) {
            at += 1;
            near[at] = biased(hdr, n, mb.ref);
        }
        cnt[at] += 2;
    };
    if (left) |n| if (n.ref != common.INTRA) {
        if (!n.mv.isZero()) {
            const v = biased(hdr, n, mb.ref);
            if (!v.eql(near[at])) {
                at += 1;
                near[at] = v;
            }
            cnt[at] += 2;
        } else cnt[0] += 2;
    };
    if (above_left) |n| if (n.ref != common.INTRA) {
        if (!n.mv.isZero()) {
            const v = biased(hdr, n, mb.ref);
            if (!v.eql(near[at])) {
                at += 1;
                near[at] = v;
            }
            cnt[at] += 1;
        } else cnt[0] += 1;
    };
    // Three apart: above-left's merged with nearest when alike.
    if (cnt[3] != 0 and near[at].eql(near[1])) cnt[1] += 1;
    cnt[3] = 0;
    if (above) |n| cnt[3] += if (n.y_mode == common.SPLITMV) 2 else 0;
    if (left) |n| cnt[3] += if (n.y_mode == common.SPLITMV) 2 else 0;
    if (above_left) |n| cnt[3] += if (n.y_mode == common.SPLITMV) 1 else 0;
    if (cnt[2] > cnt[1]) {
        const t = cnt[1];
        cnt[1] = cnt[2];
        cnt[2] = t;
        const v = near[1];
        near[1] = near[2];
        near[2] = v;
    }
    if (cnt[1] >= cnt[0]) near[0] = near[1];

    var probs: [4]u8 = undefined;
    for (&probs, 0..) |*p, i| p.* = tables.mode_contexts[cnt[i]][i];
    mb.y_mode = b.tree(&tables.mv_ref_tree, &probs);
    mb.uv_mode = mb.y_mode;

    const ci: i32 = @intCast(c);
    const ri: i32 = @intCast(r);
    const bounds: Bounds = .{
        .left = -((ci + 1) << 6),
        .right = (@as(i32, @intCast(m.cols)) - ci) << 6,
        .top = -((ri + 1) << 6),
        .bottom = (@as(i32, @intCast(m.rows)) - ri) << 6,
    };
    switch (mb.y_mode) {
        common.NEARESTMV => mb.mv = bounds.clamp(near[1]),
        common.NEARMV => mb.mv = bounds.clamp(near[2]),
        common.ZEROMV => mb.mv = .{},
        common.NEWMV => {
            const best = bounds.clamp(near[0]);
            const d = readMv(b, m.probs);
            mb.mv = .{ .x = d.x +% best.x, .y = d.y +% best.y };
        },
        else => {
            splitMvs(m, b, mb, left, above, bounds.clamp(near[0]));
            mb.mv = mb.mvs[15];
        },
    }
}

/// SPLITMV's parts and each one's vector (16.4), by the vectors left of
/// and above its first subblock.
fn splitMvs(m: *const Ctx, b: *Bool, mb: *MbInfo, left: ?*const MbInfo, above: ?*const MbInfo, best: Mv) void {
    const s = b.tree(&tables.split_mv_tree, &tables.split_mv_probs);
    mb.split = s;
    const parts = &tables.mv_partitions[s];
    for (0..tables.mv_part_count[s]) |j| {
        var k: usize = 0;
        while (parts[k] != j) k += 1;
        const l: Mv = if (k & 3 != 0) mb.mvs[k - 1] else if (left) |n| (if (n.y_mode == common.SPLITMV) n.mvs[k + 3] else n.mv) else .{};
        const a: Mv = if (k >= 4) mb.mvs[k - 4] else if (above) |n| (if (n.y_mode == common.SPLITMV) n.mvs[k + 12] else n.mv) else .{};
        const ctx: usize = if (l.eql(a))
            (if (l.isZero()) 4 else 3)
        else if (a.isZero()) 2 else if (l.isZero()) 1 else 0;
        const v: Mv = switch (b.tree(&tables.sub_mv_ref_tree, &tables.sub_mv_ref_probs[ctx])) {
            0 => l,
            1 => a,
            2 => .{},
            else => blk: {
                const d = readMv(b, m.probs);
                break :blk .{ .x = d.x +% best.x, .y = d.y +% best.y };
            },
        };
        for (k..16) |i| {
            if (parts[i] == j) mb.mvs[i] = v;
        }
    }
}

/// A vector's difference: its row, then its column (17).
fn readMv(b: *Bool, probs: *const common.Probs) Mv {
    const y = component(b, &probs.mv[0]);
    const x = component(b, &probs.mv[1]);
    return .{ .x = x, .y = y };
}

fn component(b: *Bool, p: *const [19]u8) i16 {
    const long = 9;
    var x: i16 = 0;
    if (b.read(p[0]) == 1) {
        for (0..3) |i| x += @as(i16, b.read(p[long + i])) << @intCast(i);
        var i: usize = 9;
        while (i > 3) : (i -= 1) x += @as(i16, b.read(p[long + i])) << @intCast(i);
        // Bit 3 is there only when a higher one is: the long form is 8
        // or more.
        if (x < 16 or b.read(p[long + 3]) == 1) x += 8;
    } else x = b.tree(&tables.small_mv_tree, p[2..9]);
    if (x != 0 and b.read(p[1]) == 1) x = -x;
    return x;
}

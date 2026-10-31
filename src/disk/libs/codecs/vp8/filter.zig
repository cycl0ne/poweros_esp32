// SPDX-License-Identifier: MIT
//! The loop filter (RFC 6386 15), a macroblock row at a time once the
//! row below is put together: the normal filter on every plane, or the
//! simple one on the brightness, across the macroblock edges and, where
//! the macroblock has coefficients or is predicted in parts, its
//! subblocks' edges.

const common = @import("common.zig");
const MbInfo = common.MbInfo;

/// What a macroblock is filtered with.
pub const Strength = struct {
    level: u8,
    interior: u8,
    hev: u8,
};

/// A macroblock's filter level and limits (15.1, 9.3, 9.4).
pub fn strength(hdr: *const common.Header, seg: *const common.Segmentation, deltas: *const common.Deltas, mb: *const MbInfo) Strength {
    var level: i32 = hdr.filter_level;
    if (seg.enabled) {
        level = if (seg.absolute) seg.filter[mb.segment] else level + seg.filter[mb.segment];
        level = @max(0, @min(63, level));
    }
    if (deltas.enabled) {
        level += deltas.ref[mb.ref];
        if (mb.ref == common.INTRA) {
            if (mb.y_mode == common.B_PRED) level += deltas.mode[0];
        } else if (mb.y_mode == common.ZEROMV) {
            level += deltas.mode[1];
        } else if (mb.y_mode == common.SPLITMV) {
            level += deltas.mode[3];
        } else level += deltas.mode[2];
        level = @max(0, @min(63, level));
    }
    var interior = level;
    if (hdr.sharpness != 0) {
        interior >>= if (hdr.sharpness > 4) 2 else 1;
        interior = @min(interior, 9 - @as(i32, hdr.sharpness));
    }
    interior = @max(interior, 1);
    var hev: u8 = 0;
    if (level >= 40) {
        hev = if (hdr.key) 2 else 3;
    } else if (level >= 20) {
        hev = if (hdr.key) 1 else 2;
    } else if (level >= 15) hev = 1;
    return .{ .level = @intCast(level), .interior = @intCast(interior), .hev = hev };
}

inline fn s8(v: i32) i32 {
    return @max(-128, @min(127, v));
}

inline fn u8c(v: i32) u8 {
    return @intCast(@max(0, @min(255, v)));
}

inline fn absd(a: u8, b: u8) i32 {
    return @intCast(@abs(@as(i32, a) - b));
}

/// The samples across an edge at `p`, `step` apart: p3..p0 before it,
/// q0..q3 after.
const Edge = struct {
    p: [*]u8,
    step: usize,

    inline fn at(e: Edge, comptime i: i32) *u8 {
        return if (i < 0) &(e.p - @as(usize, @intCast(-i)) * e.step)[0] else &e.p[@as(usize, @intCast(i)) * e.step];
    }
};

inline fn simpleOk(e: Edge, limit: i32) bool {
    return absd(e.at(-1).*, e.at(0).*) * 2 + (absd(e.at(-2).*, e.at(1).*) >> 1) <= limit;
}

inline fn normalOk(e: Edge, edge_limit: i32, interior: i32) bool {
    const p3 = e.at(-4).*;
    const p2 = e.at(-3).*;
    const p1 = e.at(-2).*;
    const p0 = e.at(-1).*;
    const q0 = e.at(0).*;
    const q1 = e.at(1).*;
    const q2 = e.at(2).*;
    const q3 = e.at(3).*;
    return absd(p0, q0) * 2 + (absd(p1, q1) >> 1) <= 2 * edge_limit + interior and
        absd(p3, p2) <= interior and absd(p2, p1) <= interior and absd(p1, p0) <= interior and
        absd(q3, q2) <= interior and absd(q2, q1) <= interior and absd(q1, q0) <= interior;
}

inline fn highVariance(e: Edge, hev: i32) bool {
    return absd(e.at(-2).*, e.at(-1).*) > hev or absd(e.at(1).*, e.at(0).*) > hev;
}

/// The common adjustment: p0 and q0, and p1 and q1 too when the outer
/// taps were not used.
inline fn common4(e: Edge, outer: bool) void {
    const p1: i32 = e.at(-2).*;
    const p0: i32 = e.at(-1).*;
    const q0: i32 = e.at(0).*;
    const q1: i32 = e.at(1).*;
    var a = 3 * (q0 - p0);
    if (outer) a += s8(p1 - q1);
    a = s8(a);
    const f1 = s8(a + 4) >> 3;
    const f2 = s8(a + 3) >> 3;
    e.at(-1).* = u8c(p0 + f2);
    e.at(0).* = u8c(q0 - f1);
    if (!outer) {
        const d = (f1 + 1) >> 1;
        e.at(-2).* = u8c(p1 + d);
        e.at(1).* = u8c(q1 - d);
    }
}

inline fn mbEdge(e: Edge) void {
    const p2: i32 = e.at(-3).*;
    const p1: i32 = e.at(-2).*;
    const p0: i32 = e.at(-1).*;
    const q0: i32 = e.at(0).*;
    const q1: i32 = e.at(1).*;
    const q2: i32 = e.at(2).*;
    const w = s8(s8(p1 - q1) + 3 * (q0 - p0));
    var a = s8((27 * w + 63) >> 7);
    e.at(-1).* = u8c(p0 + a);
    e.at(0).* = u8c(q0 - a);
    a = s8((18 * w + 63) >> 7);
    e.at(-2).* = u8c(p1 + a);
    e.at(1).* = u8c(q1 - a);
    a = s8((9 * w + 63) >> 7);
    e.at(-3).* = u8c(p2 + a);
    e.at(2).* = u8c(q2 - a);
}

/// `n` samples along an edge at `p`: across it `step` apart, along it
/// `along` apart.
fn mbFilter(p: [*]u8, step: usize, along: usize, n: usize, st: Strength) void {
    const edge_limit: i32 = @as(i32, st.level) + 2;
    for (0..n) |i| {
        const e: Edge = .{ .p = p + i * along, .step = step };
        if (!normalOk(e, edge_limit, st.interior)) continue;
        if (highVariance(e, st.hev)) common4(e, true) else mbEdge(e);
    }
}

fn subFilter(p: [*]u8, step: usize, along: usize, n: usize, st: Strength) void {
    for (0..n) |i| {
        const e: Edge = .{ .p = p + i * along, .step = step };
        if (normalOk(e, st.level, st.interior)) common4(e, highVariance(e, st.hev));
    }
}

fn simpleFilter(p: [*]u8, step: usize, along: usize, limit: i32) void {
    for (0..16) |i| {
        const e: Edge = .{ .p = p + i * along, .step = step };
        if (simpleOk(e, limit)) common4(e, true);
    }
}

/// Macroblock (`r`, `c`) of `f` filtered with `st`.
pub fn macroblock(f: *common.Frame, simple: bool, st: Strength, inner: bool, r: u32, c: u32) void {
    if (st.level == 0) return;
    const s = f.stride[0];
    const y = f.planes[0] + r * 16 * s + c * 16;
    if (simple) {
        const mb_limit: i32 = (@as(i32, st.level) + 2) * 2 + st.interior;
        const b_limit: i32 = @as(i32, st.level) * 2 + st.interior;
        if (c > 0) simpleFilter(y, 1, s, mb_limit);
        if (inner) for ([_]usize{ 4, 8, 12 }) |x| simpleFilter(y + x, 1, s, b_limit);
        if (r > 0) simpleFilter(y, s, 1, mb_limit);
        if (inner) for ([_]usize{ 4, 8, 12 }) |x| simpleFilter(y + x * s, s, 1, b_limit);
        return;
    }
    const cs = f.stride[1];
    const u = f.planes[1] + r * 8 * cs + c * 8;
    const v = f.planes[2] + r * 8 * cs + c * 8;
    if (c > 0) {
        mbFilter(y, 1, s, 16, st);
        mbFilter(u, 1, cs, 8, st);
        mbFilter(v, 1, cs, 8, st);
    }
    if (inner) {
        for ([_]usize{ 4, 8, 12 }) |x| subFilter(y + x, 1, s, 16, st);
        subFilter(u + 4, 1, cs, 8, st);
        subFilter(v + 4, 1, cs, 8, st);
    }
    if (r > 0) {
        mbFilter(y, s, 1, 16, st);
        mbFilter(u, cs, 1, 8, st);
        mbFilter(v, cs, 1, 8, st);
    }
    if (inner) {
        for ([_]usize{ 4, 8, 12 }) |x| subFilter(y + x * s, s, 1, 16, st);
        subFilter(u + 4 * cs, cs, 1, 8, st);
        subFilter(v + 4 * cs, cs, 1, 8, st);
    }
}

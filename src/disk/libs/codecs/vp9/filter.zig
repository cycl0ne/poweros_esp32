// SPDX-License-Identifier: MIT
//! The loop filter (8.8): the edges of each superblock's blocks and
//! transform blocks smoothed, superblock by superblock in raster order,
//! vertical edges first, then horizontal ones.

const common = @import("common.zig");
const tables = @import("tables.zig");
const parse = @import("parse.zig");
const Frame = common.Frame;

/// A filter level's limits (8.8.4), before scaling to the bit depth.
const Limits = struct { limit: u8, blimit: u8, thresh: u8 };

pub const Filter = struct {
    frame: *Frame,
    out: *const parse.Out,
    limits: [64]Limits = undefined,

    pub fn init(f: *Frame, out: *const parse.Out, sharpness: u8) Filter {
        var lf: Filter = .{ .frame = f, .out = out };
        const shift: u3 = if (sharpness > 4) 2 else if (sharpness > 0) 1 else 0;
        for (&lf.limits, 0..) |*l, lvl| {
            var limit: u32 = @intCast(lvl >> shift);
            if (sharpness > 0) limit = @min(limit, 9 - @as(u32, sharpness));
            limit = @max(limit, 1);
            l.* = .{ .limit = @intCast(limit), .blimit = @intCast(2 * (lvl + 2) + limit), .thresh = @intCast(lvl >> 4) };
        }
        return lf;
    }

    /// Superblock row `row` filtered.
    pub fn sbRow(lf: *const Filter, comptime P: type, row: u32) void {
        const sb_cols = (lf.out.mi_cols + 7) >> 3;
        for (0..sb_cols) |c| {
            for (0..3) |plane| {
                lf.pass(P, plane, 0, row * 8, @intCast(c * 8));
                lf.pass(P, plane, 1, row * 8, @intCast(c * 8));
            }
        }
    }

    /// One pass of the superblock loop filter (8.8.2), in units of four
    /// samples along each edge: what decides the filtering stays the
    /// same over them.
    fn pass(lf: *const Filter, comptime P: type, plane: usize, comptime dir: u1, row: u32, col: u32) void {
        const f = lf.frame;
        const out = lf.out;
        const sub_x: u5 = if (plane > 0) f.ss_x else 0;
        const sub_y: u5 = if (plane > 0) f.ss_y else 0;
        const sub = if (dir == 0) sub_x else sub_y;
        const edges = @as(u32, 16) >> sub;
        const len = @as(u32, 64) >> (if (dir == 0) sub_y else sub_x);
        const mi_cols = out.mi_cols;
        const mi_rows = out.mi_rows;
        const stride = f.stride[plane];
        const pl = f.plane(P, plane);
        const bd: u5 = @intCast(f.bit_depth - 8);
        for (0..edges) |e| {
            const edge: u32 = @intCast(e);
            var i: u32 = 0;
            while (i < len) : (i += 4) {
                const x = if (dir == 0) col * 8 + edge * (@as(u32, 4) << sub_x) else col * 8 + (i << sub_x);
                const y = if (dir == 0) row * 8 + (i << sub_y) else row * 8 + edge * (@as(u32, 4) << sub_y);
                if (x >= 8 * mi_cols or y >= 8 * mi_rows) continue;
                if ((dir == 0 and x == 0) or (dir == 1 and y == 0)) continue;
                const loop_col = ((x >> 3) >> sub_x) << sub_x;
                const loop_row = ((y >> 3) >> sub_y) << sub_y;
                const b = &out.blocks[out.grid[loop_row * mi_cols + loop_col]];
                const lvl = b.filter_level;
                if (lvl == 0) continue;
                const tx = if (plane > 0) parse.Parse.uvTxSize(b, f.ss_x, f.ss_y) else b.tx_size;
                const sb_size = if (sub == 0) b.size else @max(common.BLOCK_16X16, b.size);
                const block_edge = if (dir == 0)
                    x % (8 * @as(u32, tables.num_8x8_wide[sb_size])) == 0
                else
                    y % (8 * @as(u32, tables.num_8x8_high[sb_size])) == 0;
                const tx_edge = if (dir == 1 and sub_x == 1 and mi_cols & 1 == 1 and edge & 1 == 1 and x + 8 >= mi_cols * 8)
                    false
                else
                    edge % (@as(u32, 1) << @intCast(tx)) == 0;
                const is_intra = b.ref_frame[0] <= common.INTRA_FRAME;
                if (!block_edge and !(tx_edge and (is_intra or !b.skip))) continue;
                // The filter size (8.8.3).
                const is32 = edge % 8 == 0;
                var size: u8 = if (tx == common.TX_4X4 and is32) common.TX_8X8 else @min(common.TX_16X16, tx);
                if (size == common.TX_16X16) {
                    if (dir == 0 and sub_x == 1 and (x >> 3) == mi_cols - 1) size = common.TX_8X8;
                    if (dir == 1 and sub_y == 1 and (y >> 3) == mi_rows - 1) size = common.TX_8X8;
                }
                const l = lf.limits[lvl];
                const px = x >> sub_x;
                const py = y >> sub_y;
                const step: usize = if (dir == 0) 1 else stride;
                const along: usize = if (dir == 0) stride else 1;
                const at = pl + py * stride + px;
                for (0..4) |k| {
                    sample(P, at + k * along, step, size, @as(i32, l.limit) << bd, @as(i32, l.blimit) << bd, @as(i32, l.thresh) << bd, bd);
                }
            }
        }
    }
};

/// The samples across one edge filtered (8.8.5): `q` is q0, `step`
/// apart from the next one.
inline fn sample(comptime P: type, q: [*]P, step: usize, size: u8, limit: i32, blimit: i32, thresh: i32, bd: u5) void {
    const p: [*]P = q - 4 * step;
    // s[4 + i] is the sample i away from q0: p0 is s[3], q0 s[4].
    const p3: i32 = p[0];
    const p2: i32 = p[step];
    const p1: i32 = p[2 * step];
    const p0: i32 = p[3 * step];
    const q0: i32 = q[0];
    const q1: i32 = q[step];
    const q2: i32 = q[2 * step];
    const q3: i32 = q[3 * step];
    if (@abs(p3 - p2) > limit or @abs(p2 - p1) > limit or @abs(p1 - p0) > limit or
        @abs(q1 - q0) > limit or @abs(q2 - q1) > limit or @abs(q3 - q2) > limit or
        @abs(p0 - q0) * 2 + @abs(p1 - q1) / 2 > blimit) return;
    const one: i32 = @as(i32, 1) << bd;
    const flat = size >= common.TX_8X8 and @abs(p1 - p0) <= one and @abs(q1 - q0) <= one and
        @abs(p2 - p0) <= one and @abs(q2 - q0) <= one and @abs(p3 - p0) <= one and @abs(q3 - q0) <= one;
    if (!flat) {
        const hev = @abs(p1 - p0) > thresh or @abs(q1 - q0) > thresh;
        narrow(P, q, step, hev, bd);
        return;
    }
    if (size == common.TX_16X16) {
        const p7: i32 = (q - 8 * step)[0];
        const p6: i32 = (q - 7 * step)[0];
        const p5: i32 = (q - 6 * step)[0];
        const p4: i32 = (q - 5 * step)[0];
        const q4: i32 = q[4 * step];
        const q5: i32 = q[5 * step];
        const q6: i32 = q[6 * step];
        const q7: i32 = q[7 * step];
        if (@abs(p7 - p0) <= one and @abs(q7 - q0) <= one and @abs(p6 - p0) <= one and @abs(q6 - q0) <= one and
            @abs(p5 - p0) <= one and @abs(q5 - q0) <= one and @abs(p4 - p0) <= one and @abs(q4 - q0) <= one)
        {
            wide(P, q, step, 7);
            return;
        }
    }
    wide(P, q, step, 3);
}

fn narrow(comptime P: type, q: [*]P, step: usize, hev: bool, bd: u5) void {
    const lo: i32 = -(@as(i32, 1) << (bd + 7));
    const hi: i32 = (@as(i32, 1) << (bd + 7)) - 1;
    const off: i32 = @as(i32, 0x80) << bd;
    const ps1 = @as(i32, (q - 2 * step)[0]) - off;
    const ps0 = @as(i32, (q - step)[0]) - off;
    const qs0 = @as(i32, q[0]) - off;
    const qs1 = @as(i32, q[step]) - off;
    var filter: i32 = if (hev) clamp(ps1 - qs1, lo, hi) else 0;
    filter = clamp(filter + 3 * (qs0 - ps0), lo, hi);
    const filter1 = clamp(filter + 4, lo, hi) >> 3;
    const filter2 = clamp(filter + 3, lo, hi) >> 3;
    q[0] = @intCast(clamp(qs0 - filter1, lo, hi) + off);
    (q - step)[0] = @intCast(clamp(ps0 + filter2, lo, hi) + off);
    if (!hev) {
        const f = (filter1 + 1) >> 1;
        q[step] = @intCast(clamp(qs1 - f, lo, hi) + off);
        (q - 2 * step)[0] = @intCast(clamp(ps1 + f, lo, hi) + off);
    }
}

/// The wide filter of `n` taps each side (8.8.5.3).
inline fn wide(comptime P: type, q: [*]P, step: usize, comptime n: comptime_int) void {
    const log2 = if (n == 3) 3 else 4;
    var s: [2 * n + 2]i32 = undefined;
    // s[k] is the sample k - (n + 1) away from q0.
    inline for (0..2 * n + 2) |k| s[k] = (q - (n + 1) * step + k * step)[0];
    var out: [2 * n]i32 = undefined;
    inline for (0..2 * n) |o| {
        const i: i32 = @as(i32, o) - n;
        var t: i32 = s[@intCast(i + n + 1)];
        inline for (0..2 * n + 1) |jj| {
            const j: i32 = @as(i32, jj) - n;
            const pp: i32 = @max(-(n + 1), @min(n, i + j));
            t += s[@intCast(pp + n + 1)];
        }
        out[o] = (t + (1 << (log2 - 1))) >> log2;
    }
    inline for (0..2 * n) |o| (q - n * step + o * step)[0] = @intCast(out[o]);
}

fn clamp(v: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(hi, v));
}

// SPDX-License-Identifier: MPL-2.0
//! Shapes with smooth edges (`RPTAG_Smooth`).
//!
//! A shape is known two ways: by whether a point is inside it, and by the
//! span of each row a hard-edged fill would take. Each row is walked once.
//! The spans of the row and of the two beside it say which pixels are
//! surely inside - those go down as solid runs, exactly as a hard fill
//! puts them, through the pen or the fill style - which are surely outside,
//! and which are on the edge. Only an edge pixel is looked at more closely:
//! sixteen points of it on a four by four grid are asked whether they are
//! inside, and the pixel is laid over what is there by how many were.
//!
//! The grid is in eighths of a pixel, and a pixel covers its own square:
//! pixel (x, y) is everything from x to x + 1 across and y to y + 1 down.
//! A ring is a shape with a hole - a second shape taken away whole - and a
//! wedge is a shape cut by a sweep of degrees, so every curve this library
//! fills is one of the three.
//!
//! The work is on the edge: a shape's inside costs what a hard fill costs,
//! and each edge pixel sixteen questions.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _draw = @import("_draw.zig");
const _round = @import("_round.zig");
const Rect = graphics.Rect;
const RastPort = _draw.RastPort;

/// Eighths of a pixel: the grid the inside questions are asked on.
const unit: i64 = 8;

/// A rounded rectangle, or a plain one with radius 0: `box` half-open,
/// its corners quarter circles of `radius`.
pub const RoundBox = struct {
    box: Rect,
    radius: i32,

    pub fn inside(s: RoundBox, sx: i64, sy: i64) bool {
        const left = unit * s.box.min_x;
        const top = unit * s.box.min_y;
        const right = unit * s.box.max_x;
        const bottom = unit * s.box.max_y;
        if (sx < left or sx >= right or sy < top or sy >= bottom) return false;
        const r = unit * s.radius;
        if (r == 0) return true;
        // The nearest point of the box less its corners: inside the shape
        // when within the radius of it.
        const nx = @max(left + r, @min(sx, right - r));
        const ny = @max(top + r, @min(sy, bottom - r));
        const dx = sx - nx;
        const dy = sy - ny;
        return dx * dx + dy * dy <= r * r;
    }

    pub fn ready(s: RoundBox) RoundBox {
        return s;
    }

    /// Whether a whole pixel is surely in or out: not worked out here.
    pub fn state(_: RoundBox, _: i32, _: i32) PixelState {
        return .edge;
    }

    pub fn span(s: RoundBox, y: i32) ?[2]i32 {
        if (y < s.box.min_y or y >= s.box.max_y) return null;
        const i = _round.rowInset(s.box, s.radius, y);
        return .{ s.box.min_x + i, s.box.max_x - i };
    }
};

/// Where a whole pixel is against a shape's edge: every sample point of
/// it inside, every one outside, or some of each.
pub const PixelState = enum { in, out, edge };

/// How far from a pixel's middle its sample points lie, at most, in
/// eighths: they are at 1, 3, 5 and 7 across and down, so 3 and 3 from
/// the middle, which is under 4.25 - rounded up to whole eighths.
const sample_reach: i64 = 5;

/// An ellipse, or a circle with `rx` equal to `ry`: centred on the middle
/// of pixel (`cx`, `cy`) and reaching the far side of the pixels `rx` and
/// `ry` away, as the hard-edged fills do.
pub const Oval = struct {
    cx: i32,
    cy: i32,
    rx: i32,
    ry: i32,
    /// What `inside` asks with, worked out once by `ready`: the middle and
    /// the squared half-axes in eighths, and their product.
    mx: i64 = 0,
    my: i64 = 0,
    aa: i64 = 0,
    bb: i64 = 0,
    aabb: i64 = 0,
    /// A circle's radius in eighths, and the squares of it less and more
    /// the reach of a pixel's samples: the bounds `state` compares with.
    a: i64 = 0,
    surely_in: i64 = 0,
    surely_out: i64 = 0,

    /// The oval with what every `inside` needs worked out.
    pub fn ready(s: Oval) Oval {
        var r = s;
        const a = unit * s.rx + unit / 2;
        const b = unit * s.ry + unit / 2;
        r.mx = unit * s.cx + unit / 2;
        r.my = unit * s.cy + unit / 2;
        r.aa = a * a;
        r.bb = b * b;
        r.aabb = r.aa * r.bb;
        r.a = a;
        if (a > sample_reach) r.surely_in = (a - sample_reach) * (a - sample_reach);
        r.surely_out = (a + sample_reach) * (a + sample_reach);
        return r;
    }

    /// Whether every sample of pixel (`x`, `y`) is inside, every one
    /// outside, or some of each - for a circle, by its middle's distance
    /// alone: a middle that far in has all its samples in, one that far out
    /// all of them out. An ellipse is always asked sample by sample.
    pub fn state(s: Oval, x: i32, y: i32) PixelState {
        if (s.rx != s.ry) return .edge;
        const dx = unit * @as(i64, x) + unit / 2 - s.mx;
        const dy = unit * @as(i64, y) + unit / 2 - s.my;
        const d = dx * dx + dy * dy;
        if (d <= s.surely_in) return .in;
        if (d > s.surely_out) return .out;
        return .edge;
    }

    /// Whether a point is inside; asked of a `ready` oval. A circle near
    /// enough is asked in 32 bits - its squared distance against its
    /// squared radius - which is the same question, cheaper.
    pub fn inside(s: Oval, sx: i64, sy: i64) bool {
        const dx = sx - s.mx;
        const dy = sy - s.my;
        if (s.rx == s.ry and @abs(dx) < near and @abs(dy) < near and s.aa < near * near) {
            const x: u32 = @intCast(@abs(dx));
            const y: u32 = @intCast(@abs(dy));
            return x * x + y * y <= @as(u32, @intCast(s.aa));
        }
        return dx * dx * s.bb + dy * dy * s.aa <= s.aabb;
    }

    /// How far in eighths a circle's 32-bit question reaches: two squares
    /// of this and a square radius under it fit in 32 bits.
    const near: i64 = 1 << 15;

    pub fn span(s: Oval, y: i32) ?[2]i32 {
        const dy = y - s.cy;
        if (s.rx < 0 or s.ry < 0 or @abs(dy) > s.ry) return null;
        const half = _round.halfAcross(s.rx, s.ry, dy);
        return .{ s.cx - half, s.cx + half + 1 };
    }
};

/// One side of a box's bevel: the pixels nearer the top or the left edge
/// than the bottom or the right are the light side, the rest the dark.
/// The change runs down the diagonal through the top-right and the
/// bottom-left corner - through the middle of a rounded corner's quarter
/// circle - however long or short the box is. A pixel is decided at its
/// middle, so the change is hard; one exactly on the diagonal is light in
/// the box's left half and dark in its right, so the two diagonals mirror
/// each other.
pub const Side = struct {
    box: Rect,
    light: bool,

    /// Whether pixel (`x`, `y`) is on this side.
    pub fn holds(s: Side, x: i32, y: i32) bool {
        // In half pixels, from the pixel's middle.
        const mx = 2 * x + 1;
        const my = 2 * y + 1;
        const near_start = @min(my - 2 * s.box.min_y, mx - 2 * s.box.min_x);
        const near_end = @min(2 * s.box.max_y - my, 2 * s.box.max_x - mx);
        const light = near_start < near_end or (near_start == near_end and mx < s.box.min_x + s.box.max_x);
        return light == s.light;
    }

    /// Where a row's run from `x0` to `x1` turns from light to dark: the
    /// light side of a row is always its start.
    pub fn split(s: Side, x0: i32, x1: i32, y: i32) i32 {
        const light = Side{ .box = s.box, .light = true };
        var low = x0;
        var high = x1;
        while (low < high) {
            const middle = low + @divFloor(high - low, 2);
            if (light.holds(middle, y)) low = middle + 1 else high = middle;
        }
        return low;
    }
};

/// A shape less a hole, cut to a sweep and to one side of a bevel: what
/// one call fills.
pub fn Cut(comptime Outer: type, comptime Hole: type) type {
    return struct {
        outer: Outer,
        hole: ?Hole = null,
        /// The sweep, in degrees, about `centre`; null for the whole of it.
        sweep: ?[2]i32 = null,
        /// The middle of the sweep, in eighths of a pixel.
        centre: [2]i64 = .{ 0, 0 },
        /// The side of a bevel it is cut to; null for both.
        side: ?Side = null,
        /// The sweep's edges, worked out once by `ready`.
        edges: _draw.Sweep = .{},

        const Self = @This();

        /// The shape with what every `inside` needs worked out: its
        /// shapes' and its sweep's.
        pub fn ready(s: Self) Self {
            var r = s;
            r.outer = s.outer.ready();
            if (s.hole) |h| r.hole = h.ready();
            if (s.sweep) |sweep| r.edges = _draw.Sweep.of(sweep[0], sweep[1]);
            return r;
        }

        /// How much of pixel (`x`, `y`) the shape covers, 0 to 16: each
        /// edge is first asked about the whole pixel, and only an edge that
        /// runs through it is asked about the sixteen points of it on a
        /// four by four grid. Every point is asked what `inside` asks.
        fn cover(s: Self, x: i32, y: i32) u32 {
            const outer = s.outer.state(x, y);
            if (outer == .out) return 0;
            const hole: PixelState = if (s.hole) |h| h.state(x, y) else .out;
            if (hole == .in) return 0;
            const cut = s.cutState(x, y);
            if (cut == .out) return 0;
            const cut_in = cut == .in;
            if (outer == .in and hole == .out and cut_in) return 16;
            var count: u32 = 0;
            var j: i64 = 0;
            while (j < 4) : (j += 1) {
                const sy = unit * @as(i64, y) + 2 * j + 1;
                var i: i64 = 0;
                while (i < 4) : (i += 1) {
                    const sx = unit * @as(i64, x) + 2 * i + 1;
                    if (outer == .edge and !s.outer.inside(sx, sy)) continue;
                    if (hole == .edge and s.hole.?.inside(sx, sy)) continue;
                    if (!cut_in and !s.cutInside(sx, sy)) continue;
                    count += 1;
                }
            }
            return count;
        }

        /// The cut's part of `inside`: on the side, and in the sweep.
        fn cutInside(s: Self, sx: i64, sy: i64) bool {
            if (s.side) |side| if (!side.holds(@intCast(@divFloor(sx, unit)), @intCast(@divFloor(sy, unit)))) return false;
            if (s.sweep != null) {
                const dx: i32 = @intCast(sx - s.centre[0]);
                const dy: i32 = @intCast(s.centre[1] - sy);
                if (!s.edges.holds(dx, dy)) return false;
            }
            return true;
        }

        /// Whether a whole pixel is surely in the sweep and on the side:
        /// all four of its corners are in the sweep, and its middle is on
        /// the side.
        fn cutHolds(s: Self, x: i32, y: i32) bool {
            return s.cutState(x, y) == .in;
        }

        /// Where a whole pixel is against the cut. The side is decided by
        /// the pixel's middle, so a pixel is wholly on it or off it. Against
        /// the sweep: in when its four corners are; out when they all lie in
        /// what a sweep of more than half a turn leaves out, which is a wedge
        /// and holds the whole pixel when it holds its corners; else some of
        /// each.
        fn cutState(s: Self, x: i32, y: i32) PixelState {
            if (s.side) |side| if (!side.holds(x, y)) return .out;
            if (s.sweep == null) return .in;
            const corners = [_][2]i64{ .{ 0, 0 }, .{ unit, 0 }, .{ 0, unit }, .{ unit, unit } };
            var held: u32 = 0;
            for (corners) |c| {
                const dx: i32 = @intCast(unit * x + c[0] - s.centre[0]);
                const dy: i32 = @intCast(s.centre[1] - (unit * y + c[1]));
                if (s.edges.holds(dx, dy)) held += 1;
            }
            if (held == corners.len) return .in;
            if (held == 0 and !s.edges.narrow) return .out;
            return .edge;
        }
    };
}

/// How much of pixel (`x`, `y`) a shape covers, 0 to 16.
fn coverage(shape: anytype, x: i32, y: i32) u32 {
    return shape.cover(x, y);
}

/// The pixel's own colour - the fill style's for a fill that has one, the
/// pen otherwise - laid over what is there by how much of it the shape
/// covers.
fn edgePixel(rp: *RastPort, x: i32, y: i32, covered: u32, styled: bool, bound: *Rect, any: *bool) void {
    if (covered == 0) return;
    const piece = _draw.pieceAt(rp, x, y) orelse return;
    const pen = if (styled) _draw.fillColour(rp, x, y, piece.surface.format) else rp.fg_pen;
    const alpha = (pen >> 24) * covered / 16;
    _draw.plotOver(piece, x, y, (pen & 0x00FF_FFFF) | alpha << 24);
    _draw.grow(bound, y, any);
}

/// The widest and narrowest of three rows' spans: what is surely inside a
/// row is inside the narrowest, and nothing reaches past the widest.
const Band = struct {
    wide: ?[2]i32 = null,
    narrow: ?[2]i32 = null,

    fn of(spans: [3]?[2]i32) Band {
        var band = Band{};
        var all = true;
        for (spans) |maybe| {
            const s = maybe orelse {
                all = false;
                continue;
            };
            band.wide = if (band.wide) |w| .{ @min(w[0], s[0]), @max(w[1], s[1]) } else s;
            band.narrow = if (band.narrow) |n| .{ @max(n[0], s[0]), @min(n[1], s[1]) } else s;
        }
        if (!all) band.narrow = null;
        // A pixel at the end of a span may be only partly in; one more on
        // each side is left to the closer look.
        if (band.wide) |w| band.wide = .{ w[0] - 1, w[1] + 1 };
        if (band.narrow) |n| band.narrow = if (n[1] - n[0] > 2) .{ n[0] + 1, n[1] - 1 } else null;
        return band;
    }

    fn holds(span: ?[2]i32, x: i32) bool {
        const s = span orelse return false;
        return x >= s[0] and x < s[1];
    }
};

/// Fill a shape with smooth edges, rows `top` to `bottom` inclusive.
///
/// INPUTS:
/// - `gb` - the library, to hand the rows on.
/// - `rp` - the RastPort: its pen or fill style, its clip.
/// - `shape` - a `Cut` of the shape, its hole and its sweep.
/// - `top` - the first row it can reach.
/// - `bottom` - the last.
/// - `as_fill` - true for a fill, which takes the fill style; false for an
///   outline, which keeps the pen.
pub fn fill(gb: *GraphicsBase, rp: *RastPort, unready: anytype, top: i32, bottom: i32, as_fill: bool) void {
    // Everything each of the many inside questions would work out again,
    // worked out once.
    const shape = unready.ready();
    const styled = as_fill and _draw.styled(rp);
    var bound = Rect{};
    var any = false;
    var y = top;
    while (y <= bottom) : (y += 1) {
        const outer = Band.of(.{ shape.outer.span(y - 1), shape.outer.span(y), shape.outer.span(y + 1) });
        const reach = outer.wide orelse continue;
        const hole: Band = if (shape.hole) |h| Band.of(.{ h.span(y - 1), h.span(y), h.span(y + 1) }) else .{};

        // Walked across once: a run of pixels surely in goes down whole,
        // a pixel surely out is passed over, and the rest are looked at.
        var run_from: ?i32 = null;
        var x = reach[0];
        while (x <= reach[1]) : (x += 1) {
            const at_end = x == reach[1];
            const sure_in = !at_end and Band.holds(outer.narrow, x) and !Band.holds(hole.wide, x) and shape.cutHolds(x, y);
            if (sure_in) {
                if (run_from == null) run_from = x;
                continue;
            }
            if (run_from) |from| {
                if (as_fill) _draw.fillShapeSpan(rp, from, x, y, &bound, &any) else _draw.fillSpan(rp, from, x, y, &bound, &any);
                run_from = null;
            }
            if (at_end) break;
            if (Band.holds(hole.narrow, x)) continue;
            edgePixel(rp, x, y, coverage(shape, x, y), styled, &bound, &any);
        }
    }
    if (any) _draw.handOn(gb, rp, bound.min_y, bound.max_y);
}

/// One pixel of a smooth line, in the pen, laid over what is there by
/// `amount` out of 256.
fn linePixel(rp: *RastPort, x: i32, y: i32, amount: u32, bound: *Rect, any: *bool) void {
    if (amount == 0) return;
    const piece = _draw.pieceAt(rp, x, y) orelse return;
    const alpha = (rp.fg_pen >> 24) * @min(amount, 256) / 256;
    _draw.plotOver(piece, x, y, (rp.fg_pen & 0x00FF_FFFF) | alpha << 24);
    _draw.grow(bound, y, any);
}

/// A line a pixel wide with smooth edges: at each step along its longer
/// direction the ink is shared between the two pixels the line passes
/// between, by how near it passes to each - which is what keeps a slanted
/// line from coming out as steps.
///
/// INPUTS:
/// - `gb` - the library, to hand the rows on.
/// - `rp` - the RastPort: its pen and its clip.
/// - `x0`, `y0` - where the line starts.
/// - `x1`, `y1` - where it ends; both ends are drawn.
pub fn line(gb: *GraphicsBase, rp: *RastPort, x0: i32, y0: i32, x1: i32, y1: i32) void {
    var bound = Rect{};
    var any = false;
    const steep = @abs(y1 - y0) > @abs(x1 - x0);
    // Walked along the longer direction, low end first.
    var a0 = if (steep) y0 else x0;
    var b0 = if (steep) x0 else y0;
    var a1 = if (steep) y1 else x1;
    var b1 = if (steep) x1 else y1;
    if (a0 > a1) {
        const ta = a0;
        a0 = a1;
        a1 = ta;
        const tb = b0;
        b0 = b1;
        b1 = tb;
    }
    const run: i64 = a1 - a0;
    // Where the line is across, in 256ths of a pixel, at each step.
    const slope: i64 = if (run == 0) 0 else @divTrunc((@as(i64, b1) - b0) * 256, run);
    var across: i64 = @as(i64, b0) * 256;
    var a = a0;
    while (a <= a1) : (a += 1) {
        const whole: i32 = @intCast(@divFloor(across, 256));
        const part: u32 = @intCast(@mod(across, 256));
        if (steep) {
            linePixel(rp, whole, a, 256 - part, &bound, &any);
            linePixel(rp, whole + 1, a, part, &bound, &any);
        } else {
            linePixel(rp, a, whole, 256 - part, &bound, &any);
            linePixel(rp, a, whole + 1, part, &bound, &any);
        }
        across += slope;
    }
    if (any) _draw.handOn(gb, rp, bound.min_y, bound.max_y);
}

// SPDX-License-Identifier: MPL-2.0
//! Outlines wider than a pixel (`RPTAG_LineWidth`).
//!
//! **A closed shape's width grows inward**: a rectangle, a rounded one, a
//! circle, an ellipse and an arc are drawn as the ring between the shape
//! and the same shape `width` smaller, so a border inside its box never
//! makes the box bigger. The ring is filled a row at a time - on each row
//! the outer shape's span less the inner shape's - which leaves no gaps,
//! where one-pixel outlines nested inside each other would leave them on
//! every curve. A wide closed outline is solid in the pen: the line
//! pattern is a pattern along a one-pixel line.
//!
//! **A line is a square brush** `width` across dragged along it, so it has
//! square ends and is centred on the path - a line has no inside to grow
//! into. It keeps the line pattern: each step of the pattern is a brush
//! put down or not.
//!
//! Every pixel goes through the clip and the pen as any other does, and
//! the rows written are handed on to the display at the end.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _draw = @import("_draw.zig");
const _round = @import("_round.zig");
const _smooth = @import("_smooth.zig");
const Rect = graphics.Rect;
const RastPort = _draw.RastPort;

/// What a drawing so far has written, to hand on at the end.
const Written = struct {
    bound: Rect = .{},
    any: bool = false,

    fn span(w: *Written, rp: *RastPort, x0: i32, x1: i32, y: i32) void {
        _draw.fillSpan(rp, x0, x1, y, &w.bound, &w.any);
    }

    fn done(w: *Written, gb: *GraphicsBase, rp: *RastPort) void {
        if (w.any) _draw.handOn(gb, rp, w.bound.min_y, w.bound.max_y);
    }
};

/// One row of a ring: the outer span less the inner one, or the whole of
/// the outer span on a row the inner shape does not reach - of one side
/// of a bevel only, when `side` names one.
fn ringRow(rp: *RastPort, w: *Written, y: i32, outer_left: i32, outer_right: i32, inner: ?[2]i32, side: ?_smooth.Side) void {
    const hole = inner orelse return sideSpan(rp, w, outer_left, outer_right, y, side);
    sideSpan(rp, w, outer_left, @min(hole[0], outer_right), y, side);
    sideSpan(rp, w, @max(hole[1], outer_left), outer_right, y, side);
}

/// The part of a run on `side`: its start for the light side, the rest
/// for the dark.
fn sideSpan(rp: *RastPort, w: *Written, x0: i32, x1: i32, y: i32, side: ?_smooth.Side) void {
    const s = side orelse return w.span(rp, x0, x1, y);
    if (x1 <= x0) return;
    const turn = s.split(x0, x1, y);
    if (s.light) w.span(rp, x0, turn, y) else w.span(rp, turn, x1, y);
}

/// A rectangle's outline `width` thick, inside `area`.
pub fn rect(gb: *GraphicsBase, rp: *RastPort, area: Rect, width: i32) void {
    roundRect(gb, rp, area, 0, width, null);
}

/// A rounded rectangle's outline `width` thick, inside `area`. The inner
/// edge is the same shape `width` in, its radius `width` smaller. With a
/// `side`, only that side of it as a bevel.
pub fn roundRect(gb: *GraphicsBase, rp: *RastPort, area: Rect, radius: u32, width: i32, side: ?_smooth.Side) void {
    if (area.isEmpty()) return;
    var w = Written{};
    const r = @min(_round.fits(area, radius), _round.radius_max);
    const inner = Rect{ .min_x = area.min_x + width, .min_y = area.min_y + width, .max_x = area.max_x - width, .max_y = area.max_y - width };
    const ri = if (inner.isEmpty()) 0 else @min(_round.fits(inner, @intCast(@max(r - width, 0))), _round.radius_max);
    if (rp.smooth and r > 0) {
        const S = _smooth.Cut(_smooth.RoundBox, _smooth.RoundBox);
        var shape = S{ .outer = .{ .box = area, .radius = r }, .side = side };
        if (!inner.isEmpty()) shape.hole = .{ .box = inner, .radius = ri };
        _smooth.fill(gb, rp, shape, area.min_y, area.max_y - 1, false);
        return;
    }

    var y = area.min_y;
    while (y < area.max_y) : (y += 1) {
        const o = _round.rowInset(area, r, y);
        const hole: ?[2]i32 = if (inner.isEmpty() or y < inner.min_y or y >= inner.max_y) null else blk: {
            const i = _round.rowInset(inner, ri, y);
            break :blk .{ inner.min_x + i, inner.max_x - i };
        };
        ringRow(rp, &w, y, area.min_x + o, area.max_x - o, hole, side);
    }
    w.done(gb, rp);
}

/// A circle's outline `width` thick, inside the circle of `radius`.
pub fn circle(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, radius: i32, width: i32) void {
    ellipse(gb, rp, cx, cy, radius, radius, width);
}

/// An ellipse's outline `width` thick, inside the ellipse of `rx` by
/// `ry`.
pub fn ellipse(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, rx: i32, ry: i32, width: i32) void {
    if (rx < 0 or ry < 0) return;
    var w = Written{};
    const irx = rx - width;
    const iry = ry - width;
    if (rp.smooth) {
        const S = _smooth.Cut(_smooth.Oval, _smooth.Oval);
        var shape = S{ .outer = .{ .cx = cx, .cy = cy, .rx = rx, .ry = ry } };
        if (irx >= 0 and iry >= 0) shape.hole = .{ .cx = cx, .cy = cy, .rx = irx, .ry = iry };
        _smooth.fill(gb, rp, shape, cy - ry, cy + ry, false);
        return;
    }
    var dy: i32 = -ry;
    while (dy <= ry) : (dy += 1) {
        const ox = _round.halfAcross(rx, ry, dy);
        const hole: ?[2]i32 = if (irx < 0 or iry < 0 or @abs(dy) > iry) null else blk: {
            // The inner shape whole, its edge included, as the outer one
            // is: the ring is what lies outside it.
            const ix = _round.halfAcross(irx, iry, dy);
            break :blk .{ cx - ix, cx + ix + 1 };
        };
        ringRow(rp, &w, cy + dy, cx - ox, cx + ox + 1, hole, null);
    }
    w.done(gb, rp);
}

/// An arc of a circle `width` thick, inside the circle of `radius`, over
/// the sweep `from` to `to` in whole degrees.
pub fn arc(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, radius: i32, from: i32, to: i32, width: i32) void {
    if (radius < 0) return;
    var w = Written{};
    const inner = radius - width;
    if (rp.smooth) {
        const S = _smooth.Cut(_smooth.Oval, _smooth.Oval);
        var shape = S{
            .outer = .{ .cx = cx, .cy = cy, .rx = radius, .ry = radius },
            .sweep = .{ from, to },
            .centre = .{ 8 * @as(i64, cx) + 4, 8 * @as(i64, cy) + 4 },
        };
        if (inner >= 0) shape.hole = .{ .cx = cx, .cy = cy, .rx = inner, .ry = inner };
        _smooth.fill(gb, rp, shape, cy - radius, cy + radius, false);
        return;
    }
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        const ox = _round.halfAcross(radius, radius, dy);
        var dx: i32 = -ox;
        while (dx <= ox) : (dx += 1) {
            if (inner >= 0 and dx * dx + dy * dy <= inner * inner) continue;
            if (!_draw.inSweep(dx, -dy, from, to)) continue;
            const x = cx + dx;
            const y = cy + dy;
            const piece = _draw.pieceAt(rp, x, y) orelse continue;
            _draw.plot(rp, piece, x, y);
            _draw.grow(&w.bound, y, &w.any);
        }
    }
    w.done(gb, rp);
}

/// A line `width` across from one point to another: a square brush put
/// down at every step of the line where the pattern says to.
pub fn line(gb: *GraphicsBase, rp: *RastPort, x0: i32, y0: i32, x1: i32, y1: i32, width: i32) void {
    var w = Written{};
    // The brush's reach either side of the path; an even width leans
    // right and down by a pixel.
    const before = @divTrunc(width - 1, 2);
    const after = width - 1 - before;

    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    var x = x0;
    var y = y0;
    var step: u32 = rp.pattern_step;
    while (true) {
        switch (_draw.inkAt(rp, step)) {
            .nothing => {},
            .foreground, .background => |ink| {
                var row = y - before;
                while (row <= y + after) : (row += 1) {
                    var col = x - before;
                    while (col <= x + after) : (col += 1) {
                        const piece = _draw.pieceAt(rp, col, row) orelse continue;
                        if (ink == .foreground) _draw.plot(rp, piece, col, row) else _draw.plotBack(rp, piece, col, row);
                    }
                    _draw.grow(&w.bound, row, &w.any);
                }
            },
        }
        step +%= 1;
        if (x == x1 and y == y1) break;
        const twice = 2 * err;
        if (twice >= dy) {
            err += dy;
            x += sx;
        }
        if (twice <= dx) {
            err += dx;
            y += sy;
        }
    }
    rp.pattern_step = step;
    w.done(gb, rp);
}

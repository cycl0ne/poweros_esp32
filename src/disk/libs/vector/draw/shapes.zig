// SPDX-License-Identifier: MIT
//! Shapes added to a path in one go, as cubic curves: SVG's elliptical
//! arc, a rectangle with its corners rounded, an ellipse. Since 1.1.
//!
//! **An arc** is worked out as SVG 1.1's implementation notes (F.6) do:
//! from its two ends, radii, angle and flags to the ellipse's centre and
//! the angles it goes between, the radii made larger where they cannot
//! reach from one end to the other, and then a cubic curve for every
//! quarter turn or less of it.

const std = @import("std");
const sdk = @import("sdk");
const vector = sdk.vector;
const P = vector.Point;
const Path = @import("path.zig").Path;

/// The control point distance that makes four cubic curves a circle.
pub const kappa: f32 = 0.5522848;
const pi: f32 = 3.14159265;

/// SVG's arc from the current point to `to`: the ellipse `rx` across and
/// `ry` down, turned by `angle` degrees, the large or the small way
/// round, sweeping the way angles rise or the other.
pub fn arcTo(path: *Path, rx_in: f32, ry_in: f32, angle: f32, large: bool, sweep: bool, to: P) void {
    const from = path.current() orelse return;
    if (from.x == to.x and from.y == to.y) return;
    var rx = @abs(rx_in);
    var ry = @abs(ry_in);
    if (!(rx > 0) or !(ry > 0)) return path.lineTo(to);
    const phi = angle * (pi / 180);
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);
    // F.6.5.1: the middle between the ends, in the ellipse's own axes.
    const dx2 = (from.x - to.x) / 2;
    const dy2 = (from.y - to.y) / 2;
    const x1 = cos_phi * dx2 + sin_phi * dy2;
    const y1 = -sin_phi * dx2 + cos_phi * dy2;
    // F.6.6: radii too small for the ends made just large enough.
    const lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
    if (lambda > 1) {
        const s = @sqrt(lambda);
        rx *= s;
        ry *= s;
    }
    // F.6.5.2-3: the centre.
    const rx2 = rx * rx;
    const ry2 = ry * ry;
    const below = rx2 * y1 * y1 + ry2 * x1 * x1;
    const above = rx2 * ry2 - below;
    var k: f32 = if (below > 0) @sqrt(@max(above / below, 0)) else 0;
    if (large == sweep) k = -k;
    const cx1 = k * rx * y1 / ry;
    const cy1 = -k * ry * x1 / rx;
    const centre = P{
        .x = cos_phi * cx1 - sin_phi * cy1 + (from.x + to.x) / 2,
        .y = sin_phi * cx1 + cos_phi * cy1 + (from.y + to.y) / 2,
    };
    // F.6.5.5-6: where it starts on the ellipse, and how far it turns.
    const ux = (x1 - cx1) / rx;
    const uy = (y1 - cy1) / ry;
    const vx = (-x1 - cx1) / rx;
    const vy = (-y1 - cy1) / ry;
    const start = std.math.atan2(uy, ux);
    var turn = std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    if (!sweep and turn > 0) turn -= 2 * pi;
    if (sweep and turn < 0) turn += 2 * pi;
    const quarters = @abs(turn) / (pi / 2);
    const pieces: u32 = @intFromFloat(@min(@max(@ceil(quarters - 0.001), 1), 4));
    const step = turn / @as(f32, @floatFromInt(pieces));
    const handle = 4.0 / 3.0 * @tan(step / 4);
    const ellipse = Ellipse{ .centre = centre, .rx = rx, .ry = ry, .cos_phi = cos_phi, .sin_phi = sin_phi };
    var theta = start;
    for (0..pieces) |i| {
        const next = theta + step;
        const a = ellipse.at(theta);
        const b = ellipse.at(next);
        const da = ellipse.along(theta);
        const db = ellipse.along(next);
        const end = if (i == pieces - 1) to else b;
        path.cubicTo(
            .{ .x = a.x + handle * da.x, .y = a.y + handle * da.y },
            .{ .x = b.x - handle * db.x, .y = b.y - handle * db.y },
            end,
        );
        theta = next;
    }
}

const Ellipse = struct {
    centre: P,
    rx: f32,
    ry: f32,
    cos_phi: f32,
    sin_phi: f32,

    /// The point at angle `theta` of the ellipse.
    fn at(e: Ellipse, theta: f32) P {
        const x = e.rx * @cos(theta);
        const y = e.ry * @sin(theta);
        return .{ .x = e.centre.x + e.cos_phi * x - e.sin_phi * y, .y = e.centre.y + e.sin_phi * x + e.cos_phi * y };
    }

    /// Which way it goes there, as fast as the angle rises.
    fn along(e: Ellipse, theta: f32) P {
        const x = -e.rx * @sin(theta);
        const y = e.ry * @cos(theta);
        return .{ .x = e.cos_phi * x - e.sin_phi * y, .y = e.sin_phi * x + e.cos_phi * y };
    }
};

/// A closed rectangle, as SVG's `rect` is drawn: from its top left going
/// right, its corners rounded `rx` across and `ry` down - each held to
/// half the side - or square when either is 0. Nothing for a width or a
/// height of 0 or less.
pub fn addRect(path: *Path, rect: vector.Rect, rx_in: f32, ry_in: f32) void {
    const w = rect.width;
    const h = rect.height;
    if (!(w > 0) or !(h > 0)) return;
    const x = rect.x;
    const y = rect.y;
    const rx = @min(@max(rx_in, 0), w / 2);
    const ry = @min(@max(ry_in, 0), h / 2);
    if (!(rx > 0) or !(ry > 0)) {
        path.moveTo(.{ .x = x, .y = y });
        path.lineTo(.{ .x = x + w, .y = y });
        path.lineTo(.{ .x = x + w, .y = y + h });
        path.lineTo(.{ .x = x, .y = y + h });
        path.close();
        return;
    }
    const kx = rx * kappa;
    const ky = ry * kappa;
    const right = x + w;
    const bottom = y + h;
    path.moveTo(.{ .x = x + rx, .y = y });
    path.lineTo(.{ .x = right - rx, .y = y });
    path.cubicTo(.{ .x = right - rx + kx, .y = y }, .{ .x = right, .y = y + ry - ky }, .{ .x = right, .y = y + ry });
    path.lineTo(.{ .x = right, .y = bottom - ry });
    path.cubicTo(.{ .x = right, .y = bottom - ry + ky }, .{ .x = right - rx + kx, .y = bottom }, .{ .x = right - rx, .y = bottom });
    path.lineTo(.{ .x = x + rx, .y = bottom });
    path.cubicTo(.{ .x = x + rx - kx, .y = bottom }, .{ .x = x, .y = bottom - ry + ky }, .{ .x = x, .y = bottom - ry });
    path.lineTo(.{ .x = x, .y = y + ry });
    path.cubicTo(.{ .x = x, .y = y + ry - ky }, .{ .x = x + rx - kx, .y = y }, .{ .x = x + rx, .y = y });
    path.close();
}

/// A closed ellipse round `centre`, as SVG's `ellipse` is drawn: from
/// its rightmost point, the way angles rise. Nothing for a radius of 0
/// or less.
pub fn addEllipse(path: *Path, centre: P, rx: f32, ry: f32) void {
    if (!(rx > 0) or !(ry > 0)) return;
    const cx = centre.x;
    const cy = centre.y;
    const kx = rx * kappa;
    const ky = ry * kappa;
    path.moveTo(.{ .x = cx + rx, .y = cy });
    path.cubicTo(.{ .x = cx + rx, .y = cy + ky }, .{ .x = cx + kx, .y = cy + ry }, .{ .x = cx, .y = cy + ry });
    path.cubicTo(.{ .x = cx - kx, .y = cy + ry }, .{ .x = cx - rx, .y = cy + ky }, .{ .x = cx - rx, .y = cy });
    path.cubicTo(.{ .x = cx - rx, .y = cy - ky }, .{ .x = cx - kx, .y = cy - ry }, .{ .x = cx, .y = cy - ry });
    path.cubicTo(.{ .x = cx + kx, .y = cy - ry }, .{ .x = cx + rx, .y = cy - ky }, .{ .x = cx + rx, .y = cy });
    path.close();
}

// --- tests ---------------------------------------------------------------------

const testing = std.testing;
const test_memory = @import("memory.zig").test_memory;
const bounds = @import("bounds.zig").bounds;

fn expectNear(want: f32, got: f32) !void {
    try testing.expectApproxEqAbs(want, got, 0.01);
}

test "a half circle by an arc: from one end to the other through the top" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = 0, .y = 10 });
    // Radius 10 round (10, 10), the way angles rise - clockwise on the
    // screen, y going down - so over the top.
    arcTo(path, 10, 10, 0, false, true, .{ .x = 20, .y = 10 });
    try testing.expectEqual(P{ .x = 20, .y = 10 }, path.current().?);
    const box = bounds(path, .{}).?;
    try expectNear(0, box.x);
    try expectNear(0, box.y);
    try expectNear(20, box.width);
    try expectNear(10, box.height);
}

test "radii too small to reach are made large enough, and the large flag goes the long way" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = 0, .y = 0 });
    // Radius 1 cannot span 20: it becomes 10, a half circle either way.
    arcTo(path, 1, 1, 0, false, true, .{ .x = 20, .y = 0 });
    var box = bounds(path, .{}).?;
    try expectNear(10, box.height);
    try expectNear(-10, box.y);
    path.clear();
    // Radius 10 between ends 10 apart: three quarters and more the large way.
    path.moveTo(.{ .x = 0, .y = 0 });
    arcTo(path, 10, 10, 0, true, true, .{ .x = 10, .y = 0 });
    box = bounds(path, .{}).?;
    try testing.expect(box.height > 18);
    // An arc of no radius is a line.
    path.clear();
    path.moveTo(.{ .x = 0, .y = 0 });
    arcTo(path, 0, 5, 0, false, false, .{ .x = 4, .y = 3 });
    try testing.expectEqual(@as(usize, 2), path.verbs.len);
}

test "a rounded rectangle and an ellipse keep to their bounds" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    addRect(path, .{ .x = 2, .y = 3, .width = 10, .height = 6 }, 20, 2);
    const box = bounds(path, .{}).?;
    try expectNear(2, box.x);
    try expectNear(3, box.y);
    try expectNear(10, box.width);
    try expectNear(6, box.height);
    path.clear();
    addEllipse(path, .{ .x = 5, .y = 5 }, 4, 2);
    const oval = bounds(path, .{}).?;
    try expectNear(1, oval.x);
    try expectNear(3, oval.y);
    try expectNear(8, oval.width);
    try expectNear(4, oval.height);
    // Nothing of no size.
    path.clear();
    addRect(path, .{ .width = 0, .height = 5 }, 0, 0);
    addEllipse(path, .{}, 3, 0);
    try testing.expectEqual(@as(usize, 0), path.verbs.len);
}

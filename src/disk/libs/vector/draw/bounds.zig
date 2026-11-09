// SPDX-License-Identifier: MIT
//! A path's bounds through a matrix: of its curves, not of their control
//! points - a curve's own turning points found where it stops going one
//! way - so they are SVG's bounding box, which `objectBoundingBox`
//! gradients are laid over. Since 1.1.

const sdk = @import("sdk");
const vector = sdk.vector;
const P = vector.Point;
const Matrix = vector.Matrix;
const Path = @import("path.zig").Path;

/// Null for a path with no point. Every point counts, a contour's move
/// too, as SVG counts it.
pub fn bounds(path: *const Path, matrix: Matrix) ?vector.Rect {
    var box = Box{};
    var walk = path.walk();
    var at = P{};
    var start = P{};
    while (walk.next()) |segment| {
        const pts = segment.points;
        switch (segment.verb) {
            .move => {
                at = matrix.apply(pts[0]);
                start = at;
                box.add(at);
            },
            .line => {
                at = matrix.apply(pts[0]);
                box.add(at);
            },
            .quad => {
                const q = matrix.apply(pts[0]);
                const end = matrix.apply(pts[1]);
                // The same curve as a cubic one.
                const c1 = P{ .x = at.x + (q.x - at.x) * 2 / 3, .y = at.y + (q.y - at.y) * 2 / 3 };
                const c2 = P{ .x = end.x + (q.x - end.x) * 2 / 3, .y = end.y + (q.y - end.y) * 2 / 3 };
                box.cubic(at, c1, c2, end);
                at = end;
            },
            .cubic => {
                const end = matrix.apply(pts[2]);
                box.cubic(at, matrix.apply(pts[0]), matrix.apply(pts[1]), end);
                at = end;
            },
            .close => at = start,
        }
    }
    if (!box.any) return null;
    return .{ .x = box.low.x, .y = box.low.y, .width = box.high.x - box.low.x, .height = box.high.y - box.low.y };
}

const Box = struct {
    any: bool = false,
    low: P = .{},
    high: P = .{},

    fn add(box: *Box, p: P) void {
        if (p.x != p.x or p.y != p.y) return;
        if (!box.any) {
            box.* = .{ .any = true, .low = p, .high = p };
            return;
        }
        box.low = .{ .x = @min(box.low.x, p.x), .y = @min(box.low.y, p.y) };
        box.high = .{ .x = @max(box.high.x, p.x), .y = @max(box.high.y, p.y) };
    }

    /// A cubic curve: its end, and its points where x or y turns.
    fn cubic(box: *Box, p0: P, p1: P, p2: P, p3: P) void {
        box.add(p3);
        var turns: [4]f32 = undefined;
        var n: usize = 0;
        n += turning(p0.x, p1.x, p2.x, p3.x, turns[n..]);
        n += turning(p0.y, p1.y, p2.y, p3.y, turns[n..]);
        for (turns[0..n]) |t| {
            const u = 1 - t;
            const a = u * u * u;
            const b = 3 * u * u * t;
            const c = 3 * u * t * t;
            const d = t * t * t;
            box.add(.{
                .x = a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                .y = a * p0.y + b * p1.y + c * p2.y + d * p3.y,
            });
        }
    }
};

/// Where between 0 and 1 a cubic's coordinate stops rising or falling:
/// the roots of its derivative, a t² + b t + c, inside.
fn turning(v0: f32, v1: f32, v2: f32, v3: f32, out: []f32) usize {
    const a = -v0 + 3 * v1 - 3 * v2 + v3;
    const b = 2 * (v0 - 2 * v1 + v2);
    const c = v1 - v0;
    var n: usize = 0;
    if (@abs(a) < 1e-12) {
        if (@abs(b) < 1e-12) return 0;
        n += inside(-c / b, out[n..]);
        return n;
    }
    const disc = b * b - 4 * a * c;
    if (disc < 0) return 0;
    const root = @sqrt(disc);
    n += inside((-b + root) / (2 * a), out[n..]);
    n += inside((-b - root) / (2 * a), out[n..]);
    return n;
}

fn inside(t: f32, out: []f32) usize {
    if (!(t > 0 and t < 1)) return 0;
    out[0] = t;
    return 1;
}

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;
const test_memory = @import("memory.zig").test_memory;

test "a curve's bounds are where it goes, not its control points; and through a matrix" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    try testing.expect(bounds(path, .{}) == null);
    path.moveTo(.{ .x = 0, .y = 0 });
    // Control points at y 40: the curve itself reaches 30.
    path.cubicTo(.{ .x = 0, .y = 40 }, .{ .x = 10, .y = 40 }, .{ .x = 10, .y = 0 });
    const box = bounds(path, .{}).?;
    try testing.expectApproxEqAbs(@as(f32, 30), box.height, 0.001);
    try testing.expectEqual(@as(f32, 10), box.width);
    const moved = bounds(path, Matrix.translate(5, -1).then(Matrix.scale(2, 1))).?;
    try testing.expectEqual(@as(f32, 5), moved.x);
    try testing.expectEqual(@as(f32, -1), moved.y);
    try testing.expectEqual(@as(f32, 20), moved.width);
}

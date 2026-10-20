// SPDX-License-Identifier: MPL-2.0
//! From clip space to a triangle ready for the tiles: clipping, the
//! viewport, the snap to subpixels, the facing, and the edges.
//!
//! A vertex comes in clip space - x, y, z and w after the transform -
//! with the values it carries beside, `count` of them. What is visible
//! has -w <= x, y <= w and 0 <= z <= w. A triangle wholly outside one of
//! those is dropped. One that crosses the near plane (z = 0) is cut
//! there: what is behind the eye would divide by a w of nothing or less.
//! The sides are not cut at the viewport but at a guard band far beyond
//! it, where the subpixel numbers would run out; between the two the
//! tiles clip by drawing only their own pixels.
//!
//! Positions are snapped to 1/256 of a pixel (Q16.8) before the edges
//! are made from them, so the edges are exact integers: two triangles
//! that share an edge share it to the bit, and the top-left rule gives
//! each pixel on it to exactly one of them.

const std = @import("std");
const bins = @import("bins.zig");
const Edge = bins.Edge;

/// How far from the viewport's middle, in pixels, the sides are cut.
/// The edges' numbers stay well inside 64 bits that way.
const guard_pixels: f32 = 16384;

/// The near plane's w, in place of 0: no vertex is projected with less.
const least_w: f32 = 1.0 / 65536.0;

/// How a viewport maps clip space onto the surface: the pixel x and y of
/// its top left and its size. x = -1 is its left, y = -1 its top; a
/// negative height turns it upside down.
pub const Viewport = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

/// Which way round a triangle on the surface is the front: its vertices
/// in this order as seen on the screen.
pub const Winding = enum { clockwise, counter_clockwise };

/// Which triangles are not drawn.
pub const Cull = enum { none, back, front };

/// A vertex in clip space and the values it carries.
pub fn ClipVertex(comptime count: usize) type {
    return struct {
        position: [4]f32,
        values: [count]f32,

        const Self = @This();

        /// Part of the way from `from` to `to`.
        fn between(from: Self, to: Self, t: f32) Self {
            var made: Self = undefined;
            for (&made.position, from.position, to.position) |*p, a, b| p.* = a + (b - a) * t;
            for (&made.values, from.values, to.values) |*v, a, b| v.* = a + (b - a) * t;
            return made;
        }
    };
}

/// The planes a triangle is cut by, as how far inside a vertex is: 0 or
/// more is in.
const ClipPlane = enum(u3) {
    near,
    left,
    right,
    top,
    bottom,

    fn distance(plane: ClipPlane, p: [4]f32, guard: Guard) f32 {
        return switch (plane) {
            .near => p[2],
            .left => p[0] - guard.left * p[3],
            .right => guard.right * p[3] - p[0],
            .top => p[1] - guard.top * p[3],
            .bottom => guard.bottom * p[3] - p[1],
        };
    }
};

/// The guard band in clip space: where x / w and y / w are cut.
pub const Guard = struct {
    left: f32,
    right: f32,
    top: f32,
    bottom: f32,

    pub fn of(viewport: Viewport) Guard {
        const half_width = @abs(viewport.width) / 2;
        const half_height = @abs(viewport.height) / 2;
        const across = guard_pixels / @max(half_width, 1);
        const down = guard_pixels / @max(half_height, 1);
        return .{ .left = -across, .right = across, .top = -down, .bottom = down };
    }
};

/// What a vertex is outside of: a bit for each side of the view and for
/// the near plane, and one for the guard band, which says it has to be
/// cut.
pub fn outcode(p: [4]f32, guard: Guard) u8 {
    var code: u8 = 0;
    if (p[0] < -p[3]) code |= 1;
    if (p[0] > p[3]) code |= 2;
    if (p[1] < -p[3]) code |= 4;
    if (p[1] > p[3]) code |= 8;
    if (p[2] < 0) code |= 16;
    if (p[2] > p[3]) code |= 32;
    if (p[3] < least_w or p[0] < guard.left * p[3] or p[0] > guard.right * p[3] or p[1] < guard.top * p[3] or p[1] > guard.bottom * p[3]) code |= 64;
    return code;
}

/// The bits of `outcode` that say a vertex has to be cut.
pub const must_cut: u8 = 16 | 64;

/// The most vertices a triangle cut by every plane can have.
pub const most_cut = 3 + 5;

/// A triangle cut by the near plane and the guard band: the polygon left,
/// its vertices into `out`, how many. Fewer than 3 is nothing left.
pub fn cut(comptime V: type, triangle: [3]V, guard: Guard, out: *[most_cut]V) usize {
    var polygon: [most_cut]V = undefined;
    @memcpy(polygon[0..3], &triangle);
    var count: usize = 3;
    for ([_]ClipPlane{ .near, .left, .right, .top, .bottom }) |plane| {
        var kept: [most_cut]V = undefined;
        var made: usize = 0;
        for (0..count) |i| {
            const from = polygon[i];
            const to = polygon[(i + 1) % count];
            const d_from = plane.distance(from.position, guard);
            const d_to = plane.distance(to.position, guard);
            if (d_from >= 0) {
                kept[made] = from;
                made += 1;
            }
            if ((d_from >= 0) != (d_to >= 0)) {
                kept[made] = V.between(from, to, d_from / (d_from - d_to));
                made += 1;
            }
        }
        if (made < 3) return 0;
        polygon = kept;
        count = made;
    }
    @memcpy(out[0..count], polygon[0..count]);
    return count;
}

/// A vertex on the surface: its position in 1/256ths of a pixel, its
/// depth (z / w, 0 to 1) and 1 / w.
pub const Projected = struct {
    x: i64,
    y: i64,
    z: f32,
    inverse_w: f32,
};

pub fn project(p: [4]f32, viewport: Viewport) Projected {
    const inverse_w = 1 / @max(p[3], least_w);
    const x = viewport.x + (p[0] * inverse_w + 1) * viewport.width / 2;
    const y = viewport.y + (p[1] * inverse_w + 1) * viewport.height / 2;
    return .{
        .x = @intFromFloat(@round(x * 256)),
        .y = @intFromFloat(@round(y * 256)),
        .z = std.math.clamp(p[2] * inverse_w, 0, 1),
        .inverse_w = inverse_w,
    };
}

/// A triangle on the surface, ready for its own values to be set up: its
/// edges, the pixels it can cover, twice its area in 1/65536ths of a
/// pixel, and the order of its vertices that makes the edges point in -
/// the second and third swapped from how they came, if `swapped`.
pub const Triangle = struct {
    edges: [3]Edge,
    /// The edges' `c` without the top-left rule's nudge: for the values
    /// set up over the triangle, which have to be exact at the vertices.
    exact_c: [3]i64,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    area: i64,
    swapped: bool,

    /// What goes with the vertices as they came - the vertices, their
    /// values - in the order of the edges.
    pub fn inOrder(made: *const Triangle, of: anytype) @TypeOf(of.*) {
        var ordered = of.*;
        if (made.swapped) std.mem.swap(@TypeOf(of[0]), &ordered[1], &ordered[2]);
        return ordered;
    }
};

/// What is left of the triangle `v` on the surface within `area` - its
/// edges, its pixels and its area - or null: nothing of it in the area,
/// no area at all, or facing the way that is culled. Made for each
/// pipeline's culling, in the pipeline's setup: once a triangle.
pub inline fn onSurface(v: [3]Projected, comptime cull: Cull, comptime front: Winding, area: [4]i32) ?Triangle {
    var p = v;
    // Twice the area. Positive is clockwise on the surface, whose y runs
    // down.
    var twice = (p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[1].y - p[0].y) * (p[2].x - p[0].x);
    if (twice == 0) return null;
    const clockwise = twice > 0;
    switch (cull) {
        .none => {},
        .back => if (clockwise != (front == .clockwise)) return null,
        .front => if (clockwise == (front == .clockwise)) return null,
    }
    const swapped = !clockwise;
    if (swapped) {
        std.mem.swap(Projected, &p[1], &p[2]);
        twice = -twice;
    }

    // The pixels whose centres the box holds, cut to the area.
    const min_x = @min(p[0].x, p[1].x, p[2].x);
    const max_x = @max(p[0].x, p[1].x, p[2].x);
    const min_y = @min(p[0].y, p[1].y, p[2].y);
    const max_y = @max(p[0].y, p[1].y, p[2].y);
    const left = @max(@divFloor(min_x - 128 + 255, 256), area[0]);
    const top = @max(@divFloor(min_y - 128 + 255, 256), area[1]);
    const right = @min(@divFloor(max_x - 128, 256) + 1, area[2]);
    const bottom = @min(@divFloor(max_y - 128, 256) + 1, area[3]);
    if (left >= right or top >= bottom) return null;

    var made = Triangle{
        .edges = undefined,
        .exact_c = undefined,
        .left = @intCast(left),
        .top = @intCast(top),
        .right = @intCast(right),
        .bottom = @intCast(bottom),
        .area = twice,
        .swapped = swapped,
    };
    for (0..3) |i| {
        // The edge opposite vertex i runs from the next vertex to the one
        // after.
        const from = p[(i + 1) % 3];
        const to = p[(i + 2) % 3];
        const dx = to.x - from.x;
        const dy = to.y - from.y;
        // At pixel (x, y) the centre is (256x + 128, 256y + 128).
        const c = dx * (128 - from.y) - dy * (128 - from.x);
        // Clockwise on a surface whose y runs down, a top edge runs right
        // and a left edge runs up: a pixel exactly on any other is the
        // neighbour's.
        const top_left = (dy == 0 and dx > 0) or dy < 0;
        made.edges[i] = .of(-256 * dy, 256 * dx, if (top_left) c else c - 1);
        made.exact_c[i] = c;
    }
    return made;
}

/// A value over the triangle, as a plane: `at(x, y)` is the value at
/// pixel (x, y)'s centre, mixed from the vertices' as the triangle's
/// own barycentric weights say.
pub const Linear = struct {
    origin: f64,
    dx: f64,
    dy: f64,

    /// The plane through `values`, one a vertex in the order of the
    /// edges (`Triangle.inOrder`).
    pub fn of(made: *const Triangle, values: [3]f64) Linear {
        // The weight of vertex i is its opposite edge over the area.
        const per_area = 1 / @as(f64, @floatFromInt(made.area));
        var plane = Linear{ .origin = 0, .dx = 0, .dy = 0 };
        for (0..3) |i| {
            const value = values[i] * per_area;
            plane.origin += @as(f64, @floatFromInt(made.exact_c[i])) * value;
            plane.dx += @as(f64, @floatFromInt(made.edges[i].a)) * value;
            plane.dy += @as(f64, @floatFromInt(made.edges[i].b)) * value;
        }
        return plane;
    }

    pub inline fn at(plane: Linear, x: f64, y: f64) f64 {
        return plane.origin + plane.dx * x + plane.dy * y;
    }
};

/// A plane in f32 for the tiles, from the pixel at the top left of the
/// triangle's box: at pixel (x, y) it is `origin + dx * (x - left) + dy *
/// (y - top)`. Its numbers stay small there, where f32 holds them best.
pub const Plane = struct {
    origin: f32,
    dx: f32,
    dy: f32,

    pub fn of(linear: Linear, made: *const Triangle) Plane {
        return .{
            .origin = @floatCast(linear.at(@floatFromInt(made.left), @floatFromInt(made.top))),
            .dx = @floatCast(linear.dx),
            .dy = @floatCast(linear.dy),
        };
    }
};

/// A triangle's depth - z / w, 0 to 1 - as the 0 to 65535 of a Z16
/// buffer, over the pixels. Kept as a plane in whole units, half a unit
/// up so that cutting off the fraction rounds, and worked out once a run
/// (`at`); along the run it goes up by `step`, in 1/2^24ths of a unit.
///
/// The plane is in f64: at a pixel inside the triangle it mixes the
/// vertices' depths with weights from 0 to 1, so it is between them and
/// in the buffer's range, to far less than a unit. `step` is the change
/// from a pixel to the next, as large as it can be between two pixels
/// inside: a triangle that changes faster has one pixel a row at most, and
/// never steps.
pub const Depth = struct {
    plane: Linear,
    step: i64,

    /// 1/2^24ths of a unit.
    pub const fraction = 24;
    const units: f64 = 65535;
    const most_step: f64 = units * (1 << fraction);

    /// The depth of `made`, whose vertices are `vertices` as they came.
    pub fn of(made: *const Triangle, vertices: *const [3]Projected) Depth {
        var values: [3]f64 = undefined;
        for (&values, made.inOrder(vertices)) |*value, vertex| value.* = vertex.z * units;
        var plane = Linear.of(made, values);
        plane.origin += 0.5;
        return .{
            .plane = plane,
            .step = @intFromFloat(std.math.clamp(plane.dx * (1 << fraction), -most_step, most_step)),
        };
    }

    /// At pixel (x, y)'s centre, in 1/2^24ths of a unit: its whole units,
    /// `>> fraction`, are 0 to 65535.
    pub inline fn at(depth: Depth, x: u32, y: u32) i64 {
        const value = depth.plane.at(@floatFromInt(x), @floatFromInt(y));
        return @intFromFloat(std.math.clamp(value, 0, units + 0.5) * (1 << fraction));
    }
};

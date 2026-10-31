// SPDX-License-Identifier: MIT
//! Tessellation, on the cores whichever device draws: each patch's levels
//! asked of the control function, the vertices made as those levels say and
//! worked by the evaluation function, and what comes of it handed back to the
//! driver as a draw's vertices and corners.
//!
//! A triangle or a square is made of rings, each inside the last: the outer
//! one cut as the outer levels say, the others as the inner, and between two
//! rings triangles that use up both.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const shader = facet.shader;
const ExecBase = sdk.interface.exec.ExecBase;
const _vertices = @import("_vertices.zig");
const Pipeline = @import("../pipeline/_pipeline.zig").Pipeline;

/// The highest level there is.
pub const most_level = 64;

/// A level as the pieces it makes: 1 for anything below it, NaN too.
fn whole(level: f32) u32 {
    if (!(level > 1)) return 1;
    return @intFromFloat(@ceil(@min(level, most_level)));
}

/// What a patch comes to, counted, or written where `coordinates` and `into`
/// say.
const Sink = struct {
    vertices: u32 = 0,
    corners: u32 = 0,
    coordinates: ?[*][3]f32 = null,
    into: ?[*]u32 = null,
    clockwise: bool = false,

    fn vertex(sink: *Sink, u: f32, v: f32, w: f32) void {
        if (sink.coordinates) |coordinates| coordinates[sink.vertices] = .{ u, v, w };
        sink.vertices += 1;
    }

    fn line(sink: *Sink, a: u32, b: u32) void {
        if (sink.into) |into| into[sink.corners..][0..2].* = .{ a, b };
        sink.corners += 2;
    }

    /// Three vertices that go round against the clock on the coordinates.
    fn triangle(sink: *Sink, a: u32, b: u32, c: u32) void {
        if (sink.into) |into| into[sink.corners..][0..3].* = if (sink.clockwise) .{ a, c, b } else .{ a, b, c };
        sink.corners += 3;
    }
};

/// The vertices of a ring, one edge after another round it, each edge's last
/// the next one's first. Of no vertices but one, if its edges have no length.
const Ring = struct {
    start: u32,
    total: u32 = 0,
    first: [4]u32 = @splat(0),
    segments: [4]u32 = @splat(0),

    fn at(ring: *const Ring, edge: usize, k: u32) u32 {
        if (ring.total == 0) return ring.start;
        return ring.start + (ring.first[edge] + k) % ring.total;
    }
};

/// An edge of a ring, one way or the other.
const Run = struct {
    ring: *const Ring,
    edge: usize,
    reversed: bool = false,

    fn segments(along: Run) u32 {
        return along.ring.segments[along.edge];
    }

    fn at(along: Run, k: u32) u32 {
        return along.ring.at(along.edge, if (along.reversed) along.segments() - k else k);
    }
};

/// Triangles between two runs along each other, `inner` on the left of
/// `outer`: each step takes the next vertex of whichever is further behind.
fn stitch(sink: *Sink, outer: Run, inner: Run) void {
    const a = outer.segments();
    const b = inner.segments();
    var k: u32 = 0;
    var j: u32 = 0;
    while (k < a or j < b) {
        if (k < a and (j >= b or (k + 1) * b <= (j + 1) * a)) {
            sink.triangle(outer.at(k), outer.at(k + 1), inner.at(j));
            k += 1;
        } else {
            sink.triangle(inner.at(j), outer.at(k), inner.at(j + 1));
            j += 1;
        }
    }
}

fn parts(k: u32, of: u32) f32 {
    return @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(of));
}

/// Ring `r` of a triangle whose inner level is `inner`, its edges - where w,
/// then u, then v is 0 - cut as `segments` says. Its corners lie where lines
/// square to the edges, `r` pieces of `inner` from a corner, meet.
fn triangleRing(sink: *Sink, r: u32, inner: u32, segments: [3]u32) Ring {
    var ring = Ring{ .start = sink.vertices };
    const near = parts(2 * r, 3 * inner);
    const far = 1 - 2 * near;
    const corners = [3][3]f32{ .{ far, near, near }, .{ near, far, near }, .{ near, near, far } };
    for (segments, 0..) |count, edge| {
        ring.first[edge] = ring.total;
        ring.segments[edge] = count;
        const from = corners[edge];
        const to = corners[(edge + 1) % 3];
        for (0..count) |k| {
            const t = parts(@intCast(k), count);
            sink.vertex(from[0] + (to[0] - from[0]) * t, from[1] + (to[1] - from[1]) * t, from[2] + (to[2] - from[2]) * t);
        }
        ring.total += count;
    }
    if (ring.total == 0) sink.vertex(far, near, near);
    return ring;
}

fn triangles(sink: *Sink, levels: *const shader.Levels) void {
    // Edge w = 0 first, as a ring goes: from u's corner to v's.
    const outer = [3]u32{ whole(levels.outer[2]), whole(levels.outer[0]), whole(levels.outer[1]) };
    var inner = whole(levels.inner[0]);
    if (inner == 1 and (outer[0] > 1 or outer[1] > 1 or outer[2] > 1)) inner = 2;
    var outside = triangleRing(sink, 0, inner, outer);
    var r: u32 = 1;
    while (r <= inner / 2) : (r += 1) {
        const count = inner - 2 * r;
        const inside = triangleRing(sink, r, inner, .{ count, count, count });
        for (0..3) |edge| stitch(sink, .{ .ring = &outside, .edge = edge }, .{ .ring = &inside, .edge = edge });
        outside = inside;
    }
    if (inner % 2 == 1) sink.triangle(outside.at(0, 0), outside.at(1, 0), outside.at(2, 0));
}

/// Ring `r` of a square whose inner levels are `m` along u and `n` along v:
/// its edges - v low, u high, v high, u low - cut as `segments` says.
fn quadRing(sink: *Sink, r: u32, m: u32, n: u32, segments: [4]u32) Ring {
    var ring = Ring{ .start = sink.vertices };
    const low_u = parts(r, m);
    const low_v = parts(r, n);
    const high_u = 1 - low_u;
    const high_v = 1 - low_v;
    const corners = [4][2]f32{ .{ low_u, low_v }, .{ high_u, low_v }, .{ high_u, high_v }, .{ low_u, high_v } };
    for (segments, 0..) |count, edge| {
        ring.first[edge] = ring.total;
        ring.segments[edge] = count;
        const from = corners[edge];
        const to = corners[(edge + 1) % 4];
        for (0..count) |k| {
            const t = parts(@intCast(k), count);
            sink.vertex(from[0] + (to[0] - from[0]) * t, from[1] + (to[1] - from[1]) * t, 0);
        }
        ring.total += count;
    }
    if (ring.total == 0) sink.vertex(low_u, low_v, 0);
    return ring;
}

fn quads(sink: *Sink, levels: *const shader.Levels) void {
    // Edge v = 0 first, as a ring goes.
    const outer = [4]u32{ whole(levels.outer[1]), whole(levels.outer[2]), whole(levels.outer[3]), whole(levels.outer[0]) };
    var m = whole(levels.inner[0]);
    var n = whole(levels.inner[1]);
    if (m > 1 or n > 1 or outer[0] > 1 or outer[1] > 1 or outer[2] > 1 or outer[3] > 1) {
        m = @max(m, 2);
        n = @max(n, 2);
    }
    var outside = quadRing(sink, 0, m, n, outer);
    const smaller = @min(m, n);
    var r: u32 = 1;
    while (r <= smaller / 2) : (r += 1) {
        const along_u = m - 2 * r;
        const along_v = n - 2 * r;
        const inside = quadRing(sink, r, m, n, .{ along_u, along_v, along_u, along_v });
        for (0..4) |edge| stitch(sink, .{ .ring = &outside, .edge = edge }, .{ .ring = &inside, .edge = edge });
        outside = inside;
    }
    // What is left inside the last ring, one piece wide.
    if (smaller % 2 == 1) {
        if (outside.segments[1] == 1) {
            stitch(sink, .{ .ring = &outside, .edge = 0 }, .{ .ring = &outside, .edge = 2, .reversed = true });
        } else {
            stitch(sink, .{ .ring = &outside, .edge = 1 }, .{ .ring = &outside, .edge = 3, .reversed = true });
        }
    }
}

fn isolines(sink: *Sink, levels: *const shader.Levels) void {
    const lines = whole(levels.outer[0]);
    const pieces = whole(levels.outer[1]);
    for (0..lines) |l| {
        const first = sink.vertices;
        for (0..pieces + 1) |k| sink.vertex(parts(@intCast(k), pieces), parts(@intCast(l), lines), 0);
        for (0..pieces) |k| sink.line(first + @as(u32, @intCast(k)), first + @as(u32, @intCast(k)) + 1);
    }
}

/// Whether a patch is drawn at all: an outer level its domain uses at or
/// below 0, or NaN, leaves it out.
fn drawn(domain: shader.Domain, levels: *const shader.Levels) bool {
    const used: usize = switch (domain) {
        .triangles => 3,
        .quads => 4,
        .isolines => 2,
    };
    for (levels.outer[0..used]) |level| {
        if (!(level > 0)) return false;
    }
    return true;
}

fn generate(sink: *Sink, domain: shader.Domain, levels: *const shader.Levels) void {
    if (!drawn(domain, levels)) return;
    switch (domain) {
        .triangles => triangles(sink, levels),
        .quads => quads(sink, levels),
        .isolines => isolines(sink, levels),
    }
}

/// What a draw's patches came to, in memory of its own.
pub const Made = struct {
    memory: *anyopaque,
    vertices: [*]f32,
    vertex_count: u32,
    indices: [*]u32,
    corner_count: u32,
    /// Room for `_vertices.widen`, where it is drawn wide.
    wide_vertices: [*]f32,
    wide_indices: [*]u32,

    pub fn corners(made: *const Made) []const u32 {
        return made.indices[0..made.corner_count];
    }

    pub fn free(made: *const Made, sys: *ExecBase) void {
        sys.FreeVec(made.memory);
    }
};

/// `corners` of the vertices in `points`, the vertex function's, as patches
/// of the pipeline's, made into what is drawn. Null for nothing to draw, more
/// than `most_vertices`, or no memory.
pub fn run(sys: *ExecBase, pipeline: *const Pipeline, resources: *const shader.Resources, points: [*]const f32, corners: []const u32, instance: u32, most_vertices: u32) ?Made {
    const tessellated = pipeline.tessellated.?;
    const count = corners.len / tessellated.points;
    if (count == 0) return null;
    const point_stride = 4 + tessellated.vertex_varyings;
    const stride = 4 + pipeline.varyings;
    const domain = tessellated.way.domain;

    const levels_memory = sys.AllocVec(count * @sizeOf(shader.Levels), exec.MEMF_ANY) orelse return null;
    defer sys.FreeVec(levels_memory);
    const levels: [*]shader.Levels = @ptrCast(@alignCast(levels_memory));

    var sized = Sink{};
    for (0..count) |number| {
        const patch = patchOf(tessellated.points, points, point_stride, corners, number, instance, resources);
        levels[number] = .{};
        // A patch with a vertex that is not there is left out.
        var whole_patch = true;
        for (corners[number * tessellated.points..][0..tessellated.points]) |corner| {
            if (corner == _vertices.no_corner) whole_patch = false;
        }
        if (whole_patch) {
            tessellated.control(&patch, &levels[number]);
        } else {
            levels[number].outer = @splat(0);
        }
        generate(&sized, domain, &levels[number]);
        if (sized.vertices >= most_vertices) return null;
    }
    if (sized.vertices == 0) return null;

    const wide: _vertices.Wide = if (_vertices.widens(pipeline)) _vertices.mostWide(pipeline, sized.corners) else .{};
    const coordinates_bytes = @as(usize, sized.vertices) * @sizeOf([3]f32);
    const vertices_bytes = @as(usize, sized.vertices) * stride * @sizeOf(f32);
    const corners_bytes = @as(usize, sized.corners) * @sizeOf(u32);
    const wide_vertices_bytes = @as(usize, wide.vertices) * stride * @sizeOf(f32);
    const wide_indices_bytes = @as(usize, wide.indices) * @sizeOf(u32);
    const memory = sys.AllocVec(coordinates_bytes + vertices_bytes + corners_bytes + wide_vertices_bytes + wide_indices_bytes, exec.MEMF_ANY) orelse return null;
    const base: [*]u8 = @ptrCast(memory);
    const coordinates: [*][3]f32 = @ptrCast(@alignCast(base));
    const vertices: [*]f32 = @ptrCast(@alignCast(base + coordinates_bytes));
    const indices: [*]u32 = @ptrCast(@alignCast(base + coordinates_bytes + vertices_bytes));

    var sink = Sink{ .coordinates = coordinates, .into = indices, .clockwise = tessellated.way.clockwise };
    for (0..count) |number| {
        const first = sink.vertices;
        generate(&sink, domain, &levels[number]);
        const made = sink.vertices - first;
        if (made == 0) continue;
        const patch = patchOf(tessellated.points, points, point_stride, corners, number, instance, resources);
        const evaluations = shader.Evaluations{
            .patch = &patch,
            .levels = &levels[number],
            .coordinates = coordinates + first,
            .count = made,
            .outputs = vertices + @as(usize, first) * stride,
            .output_stride = stride,
        };
        tessellated.evaluation(&evaluations);
    }
    return .{
        .memory = memory,
        .vertices = vertices,
        .vertex_count = sink.vertices,
        .indices = indices,
        .corner_count = sink.corners,
        .wide_vertices = @ptrCast(@alignCast(base + coordinates_bytes + vertices_bytes + corners_bytes)),
        .wide_indices = @ptrCast(@alignCast(base + coordinates_bytes + vertices_bytes + corners_bytes + wide_vertices_bytes)),
    };
}

fn patchOf(size: u32, points: [*]const f32, point_stride: u32, corners: []const u32, number: usize, instance: u32, resources: *const shader.Resources) shader.Patch {
    return .{
        .points = points,
        .point_stride = point_stride,
        .corners = corners[number * size..].ptr,
        .count = size,
        .number = @intCast(number),
        .instance = instance,
        .resources = resources,
    };
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

/// What a domain comes to at these levels, written down.
fn madeOf(domain: shader.Domain, levels: shader.Levels, coordinates: [][3]f32, into: []u32) Sink {
    var sink = Sink{ .coordinates = coordinates.ptr, .into = into.ptr };
    generate(&sink, domain, &levels);
    return sink;
}

/// Every triangle goes round against the clock, and they add up to the whole
/// domain, in u and v.
fn expectCovers(domain: shader.Domain, levels: shader.Levels, whole_area: f32) !void {
    var coordinates: [20000][3]f32 = undefined;
    var into: [60000]u32 = undefined;
    const sink = madeOf(domain, levels, &coordinates, &into);
    var area: f32 = 0;
    var k: usize = 0;
    while (k < sink.corners) : (k += 3) {
        const a = coordinates[into[k]];
        const b = coordinates[into[k + 1]];
        const c = coordinates[into[k + 2]];
        const doubled = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
        try testing.expect(doubled >= -1e-4);
        area += doubled / 2;
    }
    try testing.expectApproxEqAbs(whole_area, area, 1e-3);
}

test "a triangle at level one is itself; a square two triangles" {
    var coordinates: [8][3]f32 = undefined;
    var into: [16]u32 = undefined;
    var sink = madeOf(.triangles, .{}, &coordinates, &into);
    try testing.expectEqual(@as(u32, 3), sink.vertices);
    try testing.expectEqual(@as(u32, 3), sink.corners);
    sink = madeOf(.quads, .{}, &coordinates, &into);
    try testing.expectEqual(@as(u32, 4), sink.vertices);
    try testing.expectEqual(@as(u32, 6), sink.corners);
}

test "whatever the levels, the triangles fill the domain, all one way round" {
    const values = [_]f32{ 1, 2, 3, 4, 5, 7, 8, 16, 33 };
    for (values) |inner| for (values) |outer| {
        try expectCovers(.triangles, .{ .outer = .{ outer, 3, 1, 1 }, .inner = .{ inner, 1 } }, 0.5);
        try expectCovers(.triangles, .{ .outer = .{ 2, outer, outer, 1 }, .inner = .{ inner, 1 } }, 0.5);
        try expectCovers(.quads, .{ .outer = .{ outer, 1, 5, 2 }, .inner = .{ inner, outer } }, 1);
        try expectCovers(.quads, .{ .outer = .{ 1, outer, 2, outer }, .inner = .{ outer, inner } }, 1);
    };
}

test "an edge is cut as its outer level says" {
    var coordinates: [2000][3]f32 = undefined;
    var into: [6000]u32 = undefined;
    const sink = madeOf(.quads, .{ .outer = .{ 3, 5, 2, 7 }, .inner = .{ 4, 4 } }, &coordinates, &into);
    var on_edges = [4]u32{ 0, 0, 0, 0 };
    for (coordinates[0..sink.vertices]) |at| {
        if (at[0] == 0) on_edges[0] += 1;
        if (at[1] == 0) on_edges[1] += 1;
        if (at[0] == 1) on_edges[2] += 1;
        if (at[1] == 1) on_edges[3] += 1;
    }
    // Each edge's pieces and one, the corners on two.
    try testing.expectEqual([4]u32{ 4, 6, 3, 8 }, on_edges);
}

test "isolines: as many lines of as many pieces, not the last v" {
    var coordinates: [100][3]f32 = undefined;
    var into: [200]u32 = undefined;
    const sink = madeOf(.isolines, .{ .outer = .{ 3, 4, 0, 0 } }, &coordinates, &into);
    try testing.expectEqual(@as(u32, 15), sink.vertices);
    try testing.expectEqual(@as(u32, 24), sink.corners);
    for (coordinates[0..sink.vertices]) |at| try testing.expect(at[1] < 1);
}

test "a patch with an outer level at or below nothing is left out" {
    var coordinates: [8][3]f32 = undefined;
    var into: [16]u32 = undefined;
    try testing.expectEqual(@as(u32, 0), madeOf(.triangles, .{ .outer = .{ 0, 4, 4, 1 } }, &coordinates, &into).vertices);
    try testing.expectEqual(@as(u32, 0), madeOf(.quads, .{ .outer = .{ 1, 1, 1, -1 } }, &coordinates, &into).vertices);
    try testing.expectEqual(@as(u32, 0), madeOf(.isolines, .{ .outer = .{ std.math.nan(f32), 1, 1, 1 } }, &coordinates, &into).vertices);
}

test "clockwise, a triangle's corners go the other way" {
    var into: [3]u32 = undefined;
    var sink = Sink{ .into = &into, .clockwise = true };
    sink.triangle(1, 2, 3);
    try testing.expectEqual([3]u32{ 1, 3, 2 }, into);
}

// SPDX-License-Identifier: MIT
//! A stroke as pieces, every one wound the same way: a quadrilateral a
//! segment, a triangle or quadrilateral at each corner (bevel or miter)
//! or a disc (round), and at an open contour's ends a square or a disc.
//! Where pieces overlap their windings add up and the non-zero rule makes
//! one shape of them. lottie.datatype's stroker, moved here (from its
//! raster.zig) when vector.library 1.0 was made.
//!
//! The pieces are made in the path's own units and handed to a `Sink`,
//! which takes them to pixels: a stroke drawn through a matrix that
//! stretches one way comes out stretched, as SVG draws it.

const sdk = @import("sdk");
const vector = sdk.vector;
const P = vector.Point;
const coverage_ = @import("coverage.zig");
const add = coverage_.add;
const sub = coverage_.sub;
const times = coverage_.times;

pub const Join = enum { miter, round, bevel };
pub const Cap = enum { butt, round, square };

pub const How = struct {
    /// Half the width, in the path's units.
    half: f32,
    join: Join = .miter,
    cap: Cap = .butt,
    /// The longest miter, in half widths.
    miter_limit: f32 = 4,

    pub fn of(stroke: *const vector.Stroke) How {
        return .{
            .half = stroke.width / 2,
            .join = switch (stroke.join) {
                vector.JOIN_ROUND => .round,
                vector.JOIN_BEVEL => .bevel,
                else => .miter,
            },
            .cap = switch (stroke.cap) {
                vector.CAP_ROUND => .round,
                vector.CAP_SQUARE => .square,
                else => .butt,
            },
            .miter_limit = stroke.miter_limit,
        };
    }
};

/// Where the pieces go: taken to pixels and added to the coverage.
pub const Sink = struct {
    coverage: *coverage_.Coverage,
    matrix: vector.Matrix,
    /// The matrix is the identity: the pieces are pixels already.
    identity: bool,
    /// How much the matrix scales a length: how many sides a disc needs.
    scale: f32,

    pub fn of(coverage: *coverage_.Coverage, matrix: vector.Matrix) Sink {
        return .{ .coverage = coverage, .matrix = matrix, .identity = matrix.isIdentity(), .scale = matrix.size() };
    }

    fn piece(sink: *Sink, points: []const P) void {
        if (sink.identity) return sink.coverage.piece(points);
        var moved: [64]P = undefined;
        for (points, 0..) |p, i| moved[i] = sink.matrix.apply(p);
        sink.coverage.piece(moved[0..points.len]);
    }

    fn disc(sink: *Sink, centre: P, radius: f32) void {
        if (radius * sink.scale <= 0.05) return;
        var sides: u32 = @intFromFloat(@ceil(radius * sink.scale * 2));
        sides = @min(@max(sides, 8), 64);
        var points: [64]P = undefined;
        for (0..sides) |i| {
            const angle = @as(f32, @floatFromInt(i)) * (2 * 3.14159265) / @as(f32, @floatFromInt(sides));
            points[i] = .{ .x = centre.x + radius * @cos(angle), .y = centre.y + radius * @sin(angle) };
        }
        sink.piece(points[0..sides]);
    }
};

/// A flattened contour stroked.
pub fn contour(sink: *Sink, all: []const P, closed: bool, how: How) void {
    // A point on the last one is passed over.
    var first: ?P = null;
    var first_direction: P = .{ .x = 0, .y = 0 };
    var previous: ?P = null;
    var direction: P = .{ .x = 0, .y = 0 };
    var segments: u32 = 0;
    for (all) |p| {
        const from = previous orelse {
            previous = p;
            first = p;
            continue;
        };
        const along = unit(sub(p, from)) orelse continue;
        segment(sink, from, p, along, how.half);
        if (segments > 0) corner(sink, from, direction, along, how) else first_direction = along;
        segments += 1;
        direction = along;
        previous = p;
    }
    const start = first orelse return;
    const last = previous.?;
    if (segments == 0) {
        if (how.cap == .round) sink.disc(start, how.half);
        return;
    }
    if (closed) {
        if (unit(sub(start, last))) |along| {
            segment(sink, last, start, along, how.half);
            corner(sink, last, direction, along, how);
            corner(sink, start, along, first_direction, how);
        } else {
            corner(sink, start, direction, first_direction, how);
        }
        return;
    }
    end(sink, start, times(first_direction, -1), how);
    end(sink, last, direction, how);
}

fn segment(sink: *Sink, from: P, to: P, along: P, half: f32) void {
    const normal = P{ .x = -along.y * half, .y = along.x * half };
    sink.piece(&.{ add(from, normal), add(to, normal), sub(to, normal), sub(from, normal) });
}

/// The corner at `at` between a segment going `in` and one going `out`.
fn corner(sink: *Sink, at: P, in: P, out: P, how: How) void {
    const dot = in.x * out.x + in.y * out.y;
    const cross = in.x * out.y - in.y * out.x;
    // Almost straight on: a bevel fills what little gap there is.
    const join: Join = if (dot > 0.95) .bevel else how.join;
    const half = how.half;
    var n1 = P{ .x = -in.y * half, .y = in.x * half };
    var n2 = P{ .x = -out.y * half, .y = out.x * half };
    switch (join) {
        .round => sink.disc(at, half),
        .bevel => {
            if (@abs(cross) < 1e-6) return;
            sink.piece(&.{ at, add(at, n1), add(at, n2) });
            sink.piece(&.{ at, sub(at, n1), sub(at, n2) });
        },
        .miter => {
            if (@abs(cross) < 1e-6) return;
            // The outer side is the one the path turns away from.
            if (cross > 0) {
                n1 = times(n1, -1);
                n2 = times(n2, -1);
            }
            const miter = times(add(n1, n2), 1 / (1 + dot));
            const length = @sqrt(miter.x * miter.x + miter.y * miter.y);
            if (length <= how.miter_limit * half) {
                sink.piece(&.{ at, add(at, n1), add(at, miter), add(at, n2) });
            } else {
                sink.piece(&.{ at, add(at, n1), add(at, n2) });
            }
        },
    }
}

/// An open end at `at`, the contour leaving it going `away`.
fn end(sink: *Sink, at: P, away: P, how: How) void {
    switch (how.cap) {
        .butt => {},
        .round => sink.disc(at, how.half),
        .square => {
            const normal = P{ .x = -away.y * how.half, .y = away.x * how.half };
            const out = add(at, times(away, how.half));
            sink.piece(&.{ add(at, normal), add(out, normal), sub(out, normal), sub(at, normal) });
        },
    }
}

fn unit(v: P) ?P {
    const length = @sqrt(v.x * v.x + v.y * v.y);
    if (length < 1e-3) return null;
    return times(v, 1 / length);
}

// SPDX-License-Identifier: MIT
//! The gradient tool's shading: the colour at each pixel of a gradient
//! dragged from one point to another.
//!
//! A straight gradient changes along the drag: a pixel takes the colour
//! of the point on the drag's line it lies across from, so the colour is
//! the same along every line square to the drag. A round one changes
//! with the distance from the drag's start, the drag's length its
//! radius. Before the start it is the start's colour, past the end the
//! end's. The colour is mixed a channel at a time, alpha among them,
//! in steps of 1/4096 of the way.

const picture_zig = @import("picture.zig");
const Pixel = picture_zig.Pixel;
const Point = @import("shapes.zig").Point;

/// The steps of the way from the start to the end.
pub const one = 4096;

pub const Shade = struct {
    from: Point,
    /// The drag, from its start to its end, and its length squared.
    across: [2]i64,
    length2: i64,
    start: Pixel,
    end: Pixel,
    round: bool,

    /// The shading of a drag from `from` to `to`, `start` at its start
    /// and `end` at its end; null for a drag that went nowhere.
    pub fn of(from: Point, to: Point, start: Pixel, end: Pixel, round: bool) ?Shade {
        const across = [2]i64{ to[0] - from[0], to[1] - from[1] };
        const length2 = across[0] * across[0] + across[1] * across[1];
        if (length2 == 0) return null;
        return .{ .from = from, .across = across, .length2 = length2, .start = start, .end = end, .round = round };
    }

    /// How far along the way the pixel at (`x`, `y`) is, 0 to `one`.
    pub fn along(shade: *const Shade, x: i32, y: i32) u32 {
        const dx: i64 = x - shade.from[0];
        const dy: i64 = y - shade.from[1];
        if (shade.round) {
            const ratio = @as(f32, @floatFromInt(dx * dx + dy * dy)) / @as(f32, @floatFromInt(shade.length2));
            return @intFromFloat(@min(@sqrt(ratio), 1.0) * one);
        }
        const projected = dx * shade.across[0] + dy * shade.across[1];
        if (projected <= 0) return 0;
        if (projected >= shade.length2) return one;
        return @intCast(@divTrunc(projected * one, shade.length2));
    }

    /// The colour at (`x`, `y`).
    pub fn at(shade: *const Shade, x: i32, y: i32) Pixel {
        return mix(shade.start, shade.end, shade.along(x, y));
    }
};

/// `start` and `end` mixed, `way` of `one` towards `end`.
pub fn mix(start: Pixel, end: Pixel, way: u32) Pixel {
    var made: Pixel = 0;
    for ([_]u5{ 0, 8, 16, 24 }) |shift| {
        const from = (start >> shift) & 0xFF;
        const to = (end >> shift) & 0xFF;
        made |= ((from * (one - way) + to * way + one / 2) / one) << shift;
    }
    return made;
}

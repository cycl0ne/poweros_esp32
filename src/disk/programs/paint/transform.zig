// SPDX-License-Identifier: MIT
//! The free transform's geometry: the box of pixels lifted from a layer,
//! scaled, turned and moved (`Shape`); where its corners and handles are
//! in the picture; which part of it a press takes (`gripAt`); how a drag
//! changes it (`dragged`); the area it covers; and the matrix that
//! paintfx.library's TransformPixels takes, from a pixel of the picture
//! back to the lifted pixels.
//!
//! A shape is its lifted size, its centre in the picture, its size there
//! and its turn, clockwise in whole degrees - the view's y runs down, so
//! a turn by `a` takes (x, y) to (x cos a - y sin a, x sin a + y cos a).
//! The sines come from a table made as the program is built. A corner
//! dragged keeps the opposite corner where it is, a side the opposite
//! side; with Shift a corner keeps the proportions and a turn goes in
//! steps of 15 degrees.
//!
//! The view draws the shape's frame over the picture (`Frame`): its
//! edges dashed in black and white as the selection's outline is, and a
//! white square edged in black at each handle. A frame is worked out in
//! the view's pixels once a flush, and each row made asks it for the
//! spans it marks on that row (`Marks`).

const sdk = @import("sdk");
const paintfx = sdk.paintfx;
const picture_zig = @import("picture.zig");
const Area = picture_zig.Area;

/// A point in the picture, in pixels, its pixels' corners whole.
pub const Spot = [2]f32;

/// The steps a turn goes in with Shift held.
pub const turn_step = 15;

pub const Shape = struct {
    /// The lifted pixels' size.
    width: u32,
    height: u32,
    /// Where its middle is in the picture.
    centre: Spot,
    /// Its size there, at least a pixel each way.
    shown: Spot,
    /// Turned clockwise, 0 to 359 degrees.
    degrees: u32 = 0,

    /// The shape of `lifted` as it is.
    pub fn of(lifted: Area) Shape {
        const width: f32 = @floatFromInt(lifted.width());
        const height: f32 = @floatFromInt(lifted.height());
        return .{
            .width = lifted.width(),
            .height = lifted.height(),
            .centre = .{ @as(f32, @floatFromInt(lifted.min_x)) + width / 2, @as(f32, @floatFromInt(lifted.min_y)) + height / 2 },
            .shown = .{ width, height },
        };
    }

    /// Whether it is the lifted box as it was.
    pub fn same(shape: Shape, other: Shape) bool {
        return shape.centre[0] == other.centre[0] and shape.centre[1] == other.centre[1] and
            shape.shown[0] == other.shown[0] and shape.shown[1] == other.shown[1] and shape.degrees == other.degrees;
    }

    /// The point `spot` - from the middle, before the turn - in the
    /// picture.
    pub fn place(shape: Shape, spot: Spot) Spot {
        const cos = cosine(shape.degrees);
        const sin = sine(shape.degrees);
        return .{ shape.centre[0] + spot[0] * cos - spot[1] * sin, shape.centre[1] + spot[0] * sin + spot[1] * cos };
    }

    /// A point of the picture from the middle, before the turn.
    pub fn local(shape: Shape, point: Spot) Spot {
        const cos = cosine(shape.degrees);
        const sin = sine(shape.degrees);
        const across = point[0] - shape.centre[0];
        const down = point[1] - shape.centre[1];
        return .{ across * cos + down * sin, -across * sin + down * cos };
    }

    /// The handles in the picture: the corners from the top left round,
    /// then the middles of the top, the right, the bottom and the left.
    pub fn handles(shape: Shape) [8]Spot {
        var made: [8]Spot = undefined;
        for (&made, handle_places) |*handle, where| handle.* = shape.place(.{ where[0] * shape.shown[0] / 2, where[1] * shape.shown[1] / 2 });
        return made;
    }

    /// The least area of whole pixels it covers.
    pub fn area(shape: Shape) Area {
        const corners = shape.handles();
        var least = corners[0];
        var most = corners[0];
        for (corners[1..4]) |corner| {
            least = .{ @min(least[0], corner[0]), @min(least[1], corner[1]) };
            most = .{ @max(most[0], corner[0]), @max(most[1], corner[1]) };
        }
        return .{
            .min_x = downTo(least[0]),
            .min_y = downTo(least[1]),
            .max_x = upTo(most[0]),
            .max_y = upTo(most[1]),
        };
    }

    /// TransformPixels' matrix filling the picture's pixels from (`left`,
    /// `top`) on from the lifted ones: a pixel's centre in the picture
    /// taken back from the middle, turned back, scaled back.
    pub fn matrix(shape: Shape, left: i32, top: i32) paintfx.Matrix {
        const cos = cosine(shape.degrees);
        const sin = sine(shape.degrees);
        const across = @as(f32, @floatFromInt(shape.width)) / shape.shown[0];
        const down = @as(f32, @floatFromInt(shape.height)) / shape.shown[1];
        const from_x = @as(f32, @floatFromInt(left)) - shape.centre[0];
        const from_y = @as(f32, @floatFromInt(top)) - shape.centre[1];
        return .{
            .xx = fixed(cos * across),
            .xy = fixed(sin * across),
            .yx = fixed(-sin * down),
            .yy = fixed(cos * down),
            .dx = fixed((cos * from_x + sin * from_y) * across + @as(f32, @floatFromInt(shape.width)) / 2),
            .dy = fixed((-sin * from_x + cos * from_y) * down + @as(f32, @floatFromInt(shape.height)) / 2),
        };
    }
};

/// A handle's square reaches this many view pixels from its middle.
pub const handle_half = 3;

/// A shape's frame in the view.
pub const Frame = struct {
    /// The corners, from the top left round, in view pixels.
    corners: [4]Spot,
    /// The handles' middles, in the order of `Shape.handles`.
    handles: [8][2]i32,

    /// The frame of `shape` in a view where the picture's (0, 0) is at
    /// `origin` and a picture pixel is `zoom` view pixels a side.
    pub fn of(shape: Shape, origin: Spot, zoom: f32) Frame {
        var made: Frame = undefined;
        for (shape.handles(), 0..) |spot, index| {
            const at = Spot{ origin[0] + spot[0] * zoom, origin[1] + spot[1] * zoom };
            if (index < 4) made.corners[index] = at;
            made.handles[index] = .{ downTo(at[0] + 0.5), downTo(at[1] + 0.5) };
        }
        return made;
    }

    /// What the frame marks on the view's row `y`.
    pub fn marks(frame: *const Frame, y: i32) Marks {
        var made = Marks{};
        const top: f32 = @floatFromInt(y);
        const bottom = top + 1;
        for (frame.corners, 0..) |start, index| {
            const end = frame.corners[(index + 1) % 4];
            const low = @min(start[1], end[1]);
            const high = @max(start[1], end[1]);
            if (high < top or low >= bottom) continue;
            // Where the edge comes into the row and where it leaves it;
            // a level edge is all in it.
            var first = start[0];
            var last = end[0];
            if (high > low) {
                const slope = (end[0] - start[0]) / (end[1] - start[1]);
                first = start[0] + slope * (@max(low, top) - start[1]);
                last = start[0] + slope * (@min(high, bottom) - start[1]);
            }
            made.add(.{ .min = downTo(@min(first, last)), .max = downTo(@max(first, last)) + 1, .kind = .edge });
        }
        for (frame.handles) |handle| {
            const down = y - handle[1];
            if (down < -handle_half or down > handle_half) continue;
            const rim = down == -handle_half or down == handle_half;
            made.add(.{ .min = handle[0] - handle_half, .max = handle[0] + handle_half + 1, .kind = if (rim) .rim else .handle });
        }
        return made;
    }
};

/// The spans a frame marks on one row of the view, the handles' after
/// the edges', so they are laid over them.
pub const Marks = struct {
    spans: [12]Span = undefined,
    count: u8 = 0,

    pub const Span = struct {
        min: i32,
        max: i32,
        /// An edge's dash, a handle's black rim row, or a handle's row:
        /// white with a black pixel at each end.
        kind: enum { edge, rim, handle },
    };

    fn add(marks: *Marks, span: Span) void {
        if (marks.count == marks.spans.len) return;
        marks.spans[marks.count] = span;
        marks.count += 1;
    }

    /// The marks laid over `out`, the view's row `y` from `min_x` on.
    pub fn lay(marks: *const Marks, out: []u32, y: i32, min_x: i32) void {
        const max_x = min_x + @as(i32, @intCast(out.len));
        for (marks.spans[0..marks.count]) |span| {
            var x = @max(span.min, min_x);
            const end = @min(span.max, max_x);
            while (x < end) : (x += 1) {
                const black = switch (span.kind) {
                    .edge => ((x + y) >> 2) & 1 == 0,
                    .rim => true,
                    .handle => x == span.min or x == span.max - 1,
                };
                out[@intCast(x - min_x)] = if (black) 0xFF000000 else 0xFFFFFFFF;
            }
        }
    }
};

/// Where each handle is, in halves of the shape's size from its middle.
const handle_places = [8]Spot{
    .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 },
    .{ 0, -1 },  .{ 1, 0 },  .{ 0, 1 }, .{ -1, 0 },
};

/// What a press takes: a handle - the corners from the top left round,
/// then the middles of the top, the right, the bottom and the left - the
/// whole shape to move, or, outside it, the turn.
pub const Grip = enum(u8) { top_left, top_right, bottom_right, bottom_left, top, right, bottom, left, move, turn };

/// The grip at `point`, a handle within `reach` of it first.
pub fn gripAt(shape: Shape, point: Spot, reach: f32) Grip {
    for (shape.handles(), 0..) |handle, index| {
        if (@abs(handle[0] - point[0]) <= reach and @abs(handle[1] - point[1]) <= reach) return @enumFromInt(index);
    }
    const inside = shape.local(point);
    if (@abs(inside[0]) <= shape.shown[0] / 2 and @abs(inside[1]) <= shape.shown[1] / 2) return .move;
    return .turn;
}

/// `start` dragged by `grip` from `from` to `to`; `keep` (Shift held)
/// keeps a corner's proportions and turns in steps.
pub fn dragged(start: Shape, grip: Grip, from: Spot, to: Spot, keep: bool) Shape {
    var shape = start;
    switch (grip) {
        .move => shape.centre = .{ start.centre[0] + to[0] - from[0], start.centre[1] + to[1] - from[1] },
        .turn => {
            const was = angleOf(.{ from[0] - start.centre[0], from[1] - start.centre[1] });
            const now = angleOf(.{ to[0] - start.centre[0], to[1] - start.centre[1] });
            var degrees = (start.degrees + 360 + now - was) % 360;
            if (keep) degrees = (degrees + turn_step / 2) / turn_step * turn_step % 360;
            shape.degrees = degrees;
        },
        else => {
            const where = handle_places[@intFromEnum(grip)];
            const half = Spot{ start.shown[0] / 2, start.shown[1] / 2 };
            // The opposite handle stays; the dragged one goes to the
            // pointer, along its side only for a side's middle.
            const stays = Spot{ -where[0] * half[0], -where[1] * half[1] };
            const pointer = start.local(to);
            var across = if (where[0] != 0) pointer[0] - stays[0] else start.shown[0];
            var down = if (where[1] != 0) pointer[1] - stays[1] else start.shown[1];
            if (keep and where[0] != 0 and where[1] != 0) {
                const times = @max(@abs(across) / start.shown[0], @abs(down) / start.shown[1]);
                across = sign(across, where[0]) * start.shown[0] * times;
                down = sign(down, where[1]) * start.shown[1] * times;
            }
            shape.shown = .{ @max(1, @abs(across)), @max(1, @abs(down)) };
            const middle = Spot{
                if (where[0] != 0) stays[0] + across / 2 else 0,
                if (where[1] != 0) stays[1] + down / 2 else 0,
            };
            shape.centre = start.place(middle);
        },
    }
    return shape;
}

/// The sign of `value`, or of `otherwise` when it is 0.
fn sign(value: f32, otherwise: f32) f32 {
    if (value > 0) return 1;
    if (value < 0) return -1;
    return if (otherwise < 0) -1 else 1;
}

/// The whole degree a line from the middle to `towards` points at,
/// clockwise from the right: the one whose direction it leans on most.
pub fn angleOf(towards: Spot) u32 {
    var best: u32 = 0;
    var most: f32 = -1e30;
    var degree: u32 = 0;
    while (degree < 360) : (degree += 1) {
        const lean = towards[0] * cosine(degree) + towards[1] * sine(degree);
        if (lean > most) {
            most = lean;
            best = degree;
        }
    }
    return best;
}

pub fn sine(degree: u32) f32 {
    return sines[degree % 360];
}

pub fn cosine(degree: u32) f32 {
    return sines[(degree + 90) % 360];
}

/// The sines of whole degrees, worked out as the program is built.
const sines = table: {
    @setEvalBranchQuota(20000);
    var made: [360]f32 = undefined;
    for (&made, 0..) |*entry, degree| {
        const radians = @as(f64, @floatFromInt(degree)) * 3.14159265358979323846 / 180.0;
        entry.* = @floatCast(@round(@sin(radians) * 1e9) / 1e9);
    }
    break :table made;
};

/// A number as 16.16, rounded, held inside what a matrix holds.
fn fixed(value: f32) i32 {
    const scaled = @max(-2147483520.0, @min(2147483520.0, value * 65536.0));
    const near: i32 = @intFromFloat(@abs(scaled) + 0.5);
    return if (scaled < 0) -near else near;
}

/// The whole number at or below `value`, held to what an area holds;
/// worked out by cutting off the fraction, which every chip does itself.
fn downTo(value: f32) i32 {
    const held = @max(-1e9, @min(1e9, value));
    const cut: i32 = @intFromFloat(held);
    return if (@as(f32, @floatFromInt(cut)) > held) cut - 1 else cut;
}

/// The whole number at or above `value`.
fn upTo(value: f32) i32 {
    const held = @max(-1e9, @min(1e9, value));
    const cut: i32 = @intFromFloat(held);
    return if (@as(f32, @floatFromInt(cut)) < held) cut + 1 else cut;
}

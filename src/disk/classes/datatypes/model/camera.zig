// SPDX-License-Identifier: MIT
//! Where model.datatype looks at a model from: round the middle of its box,
//! turned by the pointer, as near as the wheel says.
//!
//! The camera looks at the middle of the box from far enough back that
//! the whole of it - the ball round the box - fits in the view either
//! way, at `fov` across the narrower side. `yaw` turns the model round
//! the upright, `pitch` tips it towards or away from the eye, and `zoom`
//! multiplies how far back the camera stands: below 1 nearer, above 1
//! further.
//!
//! A model's file is the usual way round - x right, y up, z towards the
//! eye - and facet.library's clip space has z going away from it, so z is
//! turned over first: the model is seen as it was made, not in a mirror.
//!
//! The light comes from above and to the left of the eye and moves with
//! it, so the side looked at is the lit one however the model is turned.
//! It is given to the vertex function in the model's own space, where the
//! normals are: one turn back for the light rather than one for every
//! normal.

const std = @import("std");

/// 4 x 4, column after column, as facet.library's shaders take it
/// (`shader.transform`).
pub const Matrix = [16]f32;

/// How wide the view is across its narrower side, in radians.
pub const fov: f32 = 0.8;

/// How much light falls where the light does not reach.
pub const ambient: f32 = 0.25;

/// Where the camera is: what the pointer and the wheel change.
pub const Camera = struct {
    yaw: f32 = start_yaw,
    pitch: f32 = start_pitch,
    zoom: f32 = 1,

    /// A little from the right and above, so that a model shows it has
    /// sides and a top before it is turned. A `yaw` above 0 turns its
    /// right side towards the eye, a `pitch` below 0 its top.
    pub const start_yaw: f32 = 0.6;
    pub const start_pitch: f32 = -0.35;

    /// The most `pitch` goes either way: just short of straight down or
    /// up, where turning round the upright would spin the view instead.
    pub const most_pitch: f32 = 1.5;
    pub const least_zoom: f32 = 0.05;
    pub const most_zoom: f32 = 20;
};

/// What a frame is drawn with: the transform into clip space, and the way
/// to the light in the model's own space, one long.
pub const View = struct {
    transform: Matrix,
    light: [3]f32,
};

/// The view of the box from `low` to `high` through `camera`, into a view
/// `aspect` wide for each unit of its height.
pub fn view(low: [3]f32, high: [3]f32, camera: Camera, aspect: f32) View {
    const middle = [3]f32{ (low[0] + high[0]) / 2, (low[1] + high[1]) / 2, (low[2] + high[2]) / 2 };
    const half = [3]f32{ (high[0] - low[0]) / 2, (high[1] - low[1]) / 2, (high[2] - low[2]) / 2 };
    var radius = @sqrt(half[0] * half[0] + half[1] * half[1] + half[2] * half[2]);
    if (!(radius > 0) or std.math.isInf(radius)) radius = 1;

    // The narrower way across decides how far back the ball fits.
    const tall = @tan(fov / 2);
    const across = std.math.atan(tall * aspect) * 2;
    const narrow = @min(fov, across);
    const distance = radius / @sin(narrow / 2) * camera.zoom;
    const far = distance + radius * 1.05;
    const near = @max(distance - radius * 1.05, far / 1000);
    const vertical = if (aspect < 1) across_to_vertical(fov, aspect) else fov;

    const turn = turning(camera.yaw, camera.pitch);
    // Into the eye's space: the middle to the origin, z turned over,
    // turned, and pushed back.
    var model: Matrix = identity;
    for (0..3) |col| for (0..3) |row| {
        // The column of z is turned over with z.
        const sign: f32 = if (col == 2) -1 else 1;
        model[col * 4 + row] = turn[col * 3 + row] * sign;
    };
    for (0..3) |row| {
        var moved: f32 = 0;
        for (0..3) |col| moved -= model[col * 4 + row] * middle[col];
        model[12 + row] = moved;
    }
    model[14] += distance;

    // Towards the light in the eye's space, back through the turn and
    // the turning over of z.
    const eye_light = normalized(.{ -0.4, 0.6, -1 });
    var light: [3]f32 = undefined;
    for (0..3) |col| {
        var sum: f32 = 0;
        for (0..3) |row| sum += turn[col * 3 + row] * eye_light[row];
        light[col] = if (col == 2) -sum else sum;
    }
    return .{ .transform = multiply(perspective(vertical, aspect, near, far), model), .light = light };
}

/// The vertical angle that makes `horizontal` the angle across a view
/// `aspect` wide for each unit of its height.
fn across_to_vertical(horizontal: f32, aspect: f32) f32 {
    return std.math.atan(@tan(horizontal / 2) / aspect) * 2;
}

/// Turned round the upright by `yaw`, then tipped by `pitch`: 3 x 3,
/// column after column.
fn turning(yaw: f32, pitch: f32) [9]f32 {
    const cy = @cos(yaw);
    const sy = @sin(yaw);
    const cp = @cos(pitch);
    const sp = @sin(pitch);
    // pitch round x after yaw round y: Rx * Ry.
    return .{
        cy, sp * sy,  -cp * sy,
        0,  cp,       sp,
        sy, -sp * cy, cp * cy,
    };
}

pub const identity: Matrix = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

/// What facet.library's clip space takes: x right, y down the screen,
/// depth 0 near to 1 far, w the distance along the view.
fn perspective(vertical: f32, aspect: f32, near: f32, far: f32) Matrix {
    const f = 1 / @tan(vertical / 2);
    var m: Matrix = @splat(0);
    m[0] = f / aspect;
    m[5] = -f;
    m[10] = far / (far - near);
    m[11] = 1;
    m[14] = -near * far / (far - near);
    return m;
}

fn multiply(a: Matrix, b: Matrix) Matrix {
    var out: Matrix = undefined;
    for (0..4) |col| for (0..4) |row| {
        var sum: f32 = 0;
        for (0..4) |k| sum += a[k * 4 + row] * b[col * 4 + k];
        out[col * 4 + row] = sum;
    };
    return out;
}

fn normalized(v: [3]f32) [3]f32 {
    const length = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

const testing = std.testing;

fn clip(m: Matrix, p: [3]f32) [4]f32 {
    var out: [4]f32 = undefined;
    for (&out, 0..) |*o, row| o.* = m[row] * p[0] + m[4 + row] * p[1] + m[8 + row] * p[2] + m[12 + row];
    return out;
}

test "the middle of the box in the middle of the view, all of the box inside it, either way round" {
    const low = [3]f32{ -3, 10, 4 };
    const high = [3]f32{ 5, 12, 20 };
    for ([_]f32{ 0.5, 1, 16.0 / 9.0 }) |aspect| {
        for ([_]Camera{ .{}, .{ .yaw = 2.5, .pitch = -1.2 }, .{ .yaw = 0, .pitch = 0 } }) |camera| {
            const made = view(low, high, camera, aspect);
            const middle = clip(made.transform, .{ 1, 11, 12 });
            try testing.expectApproxEqAbs(@as(f32, 0), middle[0] / middle[3], 1e-4);
            try testing.expectApproxEqAbs(@as(f32, 0), middle[1] / middle[3], 1e-4);
            for (0..8) |corner| {
                const p = [3]f32{
                    if (corner & 1 != 0) high[0] else low[0],
                    if (corner & 2 != 0) high[1] else low[1],
                    if (corner & 4 != 0) high[2] else low[2],
                };
                const c = clip(made.transform, p);
                try testing.expect(c[3] > 0);
                try testing.expect(@abs(c[0]) <= c[3] and @abs(c[1]) <= c[3]);
                try testing.expect(c[2] >= 0 and c[2] <= c[3]);
            }
        }
    }
}

test "seen as made: up is up, right is right, and the near side lit" {
    // Straight on: x right on the screen, y up it (down in clip space),
    // and z towards the eye nearer than the middle.
    const made = view(.{ -1, -1, -1 }, .{ 1, 1, 1 }, .{ .yaw = 0, .pitch = 0 }, 1);
    const right = clip(made.transform, .{ 1, 0, 0 });
    const up = clip(made.transform, .{ 0, 1, 0 });
    const front = clip(made.transform, .{ 0, 0, 1 });
    const back = clip(made.transform, .{ 0, 0, -1 });
    try testing.expect(right[0] / right[3] > 0);
    try testing.expect(up[1] / up[3] < 0);
    try testing.expect(front[3] < back[3]);
    // The light: from above, from the left, from the eye's side.
    try testing.expect(made.light[1] > 0 and made.light[0] < 0 and made.light[2] > 0);
    try testing.expectApproxEqAbs(@as(f32, 1), made.light[0] * made.light[0] + made.light[1] * made.light[1] + made.light[2] * made.light[2], 1e-5);
}

test "nearer and further: the wheel's zoom moves the camera, not the middle" {
    const near = view(.{ -1, -1, -1 }, .{ 1, 1, 1 }, .{ .zoom = 0.5 }, 1);
    const far = view(.{ -1, -1, -1 }, .{ 1, 1, 1 }, .{ .zoom = 2 }, 1);
    const corner_near = clip(near.transform, .{ 1, 1, 1 });
    const corner_far = clip(far.transform, .{ 1, 1, 1 });
    try testing.expect(@abs(corner_near[0] / corner_near[3]) > @abs(corner_far[0] / corner_far[3]));
}

test "where it starts: its right side and its top turned towards the eye" {
    const made = view(.{ -1, -1, -1 }, .{ 1, 1, 1 }, .{}, 1);
    const middle = clip(made.transform, .{ 0, 0, 0 });
    const right = clip(made.transform, .{ 1, 0, 0 });
    const top = clip(made.transform, .{ 0, 1, 0 });
    try testing.expect(right[3] < middle[3]);
    try testing.expect(top[3] < middle[3]);
}

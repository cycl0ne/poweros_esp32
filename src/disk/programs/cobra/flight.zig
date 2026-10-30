// SPDX-License-Identifier: MIT
//! How the ship flies and how it is seen: all from the time alone. The world
//! goes with the ship, which weaves about its middle, banks into each turn and
//! rolls right over every so often; the eye goes round it, nearer and further.
//!
//! As ELITE has it, +x is right, +y up and +z ahead. Everything repeats after
//! `cycle` seconds, so that the time can start over without a jump.

const std = @import("std");

pub const Matrix = [16]f32;

pub const cycle: f32 = 1200;
/// How fast the ship goes, in the ship's units a second: what the dust shows.
pub const speed: f32 = 900;
/// The dust lies in a box of this side, repeated all round the eye.
pub const dust_box: f32 = 1200;
/// Nothing nearer than this is seen, nothing further than `far`.
pub const near: f32 = 40;
pub const far: f32 = 3000;

const roll_every: f32 = 24;
const roll_starts: f32 = 20;
const roll_takes: f32 = 3;
const tan_half_height: f32 = 0.364;

/// So many times round in a cycle, at `t`: whole numbers repeat with it.
fn wave(times: f32, t: f32) f32 {
    return @sin(angle(times, t));
}

fn angle(times: f32, t: f32) f32 {
    return times * t * 2 * std.math.pi / cycle;
}

/// `a` * `b`, column after column.
pub fn multiply(a: Matrix, b: Matrix) Matrix {
    var out: Matrix = undefined;
    for (0..4) |column| for (0..4) |row| {
        var sum: f32 = 0;
        for (0..4) |k| sum += a[k * 4 + row] * b[column * 4 + k];
        out[column * 4 + row] = sum;
    };
    return out;
}

fn normalized(v: [3]f32) [3]f32 {
    const length = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

/// Turned by `yaw` to the right, `pitch` up and `roll` about the nose, at `at`.
pub fn placed(yaw: f32, pitch: f32, roll: f32, at: [3]f32) Matrix {
    const cy = @cos(yaw);
    const sy = @sin(yaw);
    const cp = @cos(pitch);
    const sp = @sin(pitch);
    const cr = @cos(roll);
    const sr = @sin(roll);
    const nose = [3]f32{ sy * cp, sp, cy * cp };
    const flat_right = [3]f32{ cy, 0, -sy };
    const flat_up = cross(nose, flat_right);
    return .{
        flat_right[0] * cr + flat_up[0] * sr, flat_right[1] * cr + flat_up[1] * sr, flat_right[2] * cr + flat_up[2] * sr, 0,
        flat_up[0] * cr - flat_right[0] * sr, flat_up[1] * cr - flat_right[1] * sr, flat_up[2] * cr - flat_right[2] * sr, 0,
        nose[0],                              nose[1],                              nose[2],                              0,
        at[0],                                at[1],                                at[2],                                1,
    };
}

/// `v` in the space a matrix of whole turning takes from: back along it.
pub fn back(m: Matrix, v: [3]f32) [3]f32 {
    return .{ m[0] * v[0] + m[1] * v[1] + m[2] * v[2], m[4] * v[0] + m[5] * v[1] + m[6] * v[2], m[8] * v[0] + m[9] * v[1] + m[10] * v[2] };
}

/// From what the eye sees, x right, y up and z away, to clip space, whose y
/// goes down.
pub fn projection(aspect: f32) Matrix {
    const high = 1 / tan_half_height;
    const depth = far / (far - near);
    return .{
        high / aspect, 0,     0,             0,
        0,             -high, 0,             0,
        0,             0,     depth,         1,
        0,             0,     -near * depth, 0,
    };
}

/// All of the picture at one moment.
pub const Moment = struct {
    /// The ship, in the world.
    ship: Matrix,
    eye: [3]f32,
    /// From the world to what the eye sees, and the same turning alone.
    view: Matrix,
    sky: Matrix,
};

/// The roll it makes every so often: one whole turn, slowly in and out.
fn rollOver(t: f32) f32 {
    const into = (@mod(t, roll_every) - roll_starts) / roll_takes;
    const done = std.math.clamp(into, 0, 1);
    return done * done * (3 - 2 * done) * 2 * std.math.pi;
}

pub fn momentAt(t: f32) Moment {
    // Where it weaves to, and how fast sideways and up.
    const x_times: f32 = 96;
    const y_times: f32 = 70;
    const x_far: f32 = 90;
    const y_far: f32 = 45;
    const at = [3]f32{ x_far * wave(x_times, t), y_far * wave(y_times, t + 1), 0 };
    const x_speed = x_far * @cos(angle(x_times, t)) * x_times * 2 * std.math.pi / cycle;
    const y_speed = y_far * @cos(angle(y_times, t + 1)) * y_times * 2 * std.math.pi / cycle;
    // As if it went at a third of the speed: the turns are to be seen.
    const yaw = std.math.atan(x_speed * 3 / speed);
    const pitch = std.math.atan(y_speed * 3 / speed);
    const roll = -yaw * 2 + rollOver(t);
    const ship = placed(yaw, pitch, roll, at);

    const around = 3.6 + angle(25, t);
    const up = 0.08 + 0.32 * wave(39, t);
    const distance = 470 + 130 * wave(19, t);
    const target = [3]f32{ at[0] * 0.55, at[1] * 0.55, 0 };
    const eye = [3]f32{
        target[0] + distance * @cos(up) * @sin(around),
        target[1] + distance * @sin(up),
        target[2] + distance * @cos(up) * @cos(around),
    };
    const ahead = normalized(.{ target[0] - eye[0], target[1] - eye[1], target[2] - eye[2] });
    const right = normalized(cross(.{ 0, 1, 0 }, ahead));
    const top = cross(ahead, right);
    return .{
        .ship = ship,
        .eye = eye,
        .view = .{
            right[0],        top[0],        ahead[0],        0,
            right[1],        top[1],        ahead[1],        0,
            right[2],        top[2],        ahead[2],        0,
            -dot(right, eye), -dot(top, eye), -dot(ahead, eye), 1,
        },
        .sky = .{
            right[0], top[0], ahead[0], 0,
            right[1], top[1], ahead[1], 0,
            right[2], top[2], ahead[2], 0,
            0,        0,      0,        1,
        },
    };
}

/// How bright the engines burn, from 0.7 to 1: a quick unsteady flicker.
pub fn flicker(t: f32) f32 {
    return 0.85 + 0.15 * wave(7066, t) * wave(11650, t);
}

/// The planet's slow turning about its leaning axis.
pub fn planetTurn(t: f32) Matrix {
    return placed(angle(4, t), 0.4, 0, .{ 0, 0, 0 });
}

/// `v` brought into the box around 0, `dust_box` a side.
pub inline fn wrapped(v: f32) f32 {
    return v - dust_box * @floor(v / dust_box + 0.5);
}

const testing = std.testing;

test "a matrix times its inverse turning comes back" {
    const m = placed(0.3, 0.2, 1.1, .{ 0, 0, 0 });
    const v = [3]f32{ 1, 2, 3 };
    const there = [3]f32{
        m[0] * v[0] + m[4] * v[1] + m[8] * v[2],
        m[1] * v[0] + m[5] * v[1] + m[9] * v[2],
        m[2] * v[0] + m[6] * v[1] + m[10] * v[2],
    };
    const again = back(m, there);
    for (v, again) |a, b| try testing.expectApproxEqAbs(a, b, 0.0001);
}

test "unturned, the ship's nose is ahead, its top up and its right right" {
    const m = placed(0, 0, 0, .{ 1, 2, 3 });
    try testing.expectEqual(@as(f32, 1), m[0]);
    try testing.expectApproxEqAbs(@as(f32, 1), m[5], 0.0001);
    try testing.expectEqual(@as(f32, 1), m[10]);
    try testing.expectEqual(@as(f32, 3), m[14]);
}

test "a yaw to the right points the nose to the right, a pitch up points it up" {
    try testing.expect(placed(0.5, 0, 0, .{ 0, 0, 0 })[8] > 0.4);
    try testing.expect(placed(0, 0.5, 0, .{ 0, 0, 0 })[9] > 0.4);
}

test "what is ahead of the eye is in front, the right on the right, the top at the top" {
    const m = momentAt(0);
    const clip = multiply(projection(1), m.sky);
    // The eye's own right, up and ahead, through the turning and the projection.
    const right = [3]f32{ m.sky[0], m.sky[4], m.sky[8] };
    const top = [3]f32{ m.sky[1], m.sky[5], m.sky[9] };
    const ahead = [3]f32{ m.sky[2], m.sky[6], m.sky[10] };
    const through = struct {
        fn of(c: Matrix, v: [3]f32) [4]f32 {
            var out: [4]f32 = undefined;
            for (&out, 0..) |*each, k| each.* = c[k] * v[0] + c[4 + k] * v[1] + c[8 + k] * v[2] + c[12 + k];
            return out;
        }
    };
    try testing.expect(through.of(clip, right)[0] > 0);
    try testing.expect(through.of(clip, top)[1] < 0);
    try testing.expect(through.of(clip, ahead)[3] > 0);
}

test "the near and far planes come to 0 and 1" {
    const p = projection(1);
    try testing.expectApproxEqAbs(@as(f32, 0), (p[10] * near + p[14]) / near, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), (p[10] * far + p[14]) / far, 0.0001);
}

test "the eye never comes into the ship, and always looks at it" {
    var t: f32 = 0;
    while (t < cycle) : (t += 0.25) {
        const m = momentAt(t);
        const to = [3]f32{ m.ship[12] - m.eye[0], m.ship[13] - m.eye[1], m.ship[14] - m.eye[2] };
        const distance = @sqrt(dot(to, to));
        // The ship reaches 128 + a little from its middle.
        try testing.expect(distance > 200);
        const ahead = [3]f32{ m.sky[2], m.sky[6], m.sky[10] };
        try testing.expect(dot(to, ahead) / distance > 0.9);
    }
}

test "the flight has no jump where it starts over" {
    const first = momentAt(0);
    const last = momentAt(cycle);
    for (first.ship, last.ship) |a, b| try testing.expectApproxEqAbs(a, b, 0.01);
    for (first.eye, last.eye) |a, b| try testing.expectApproxEqAbs(a, b, 0.5);
}

test "no frame's turn is sudden" {
    var t: f32 = 0;
    var before = momentAt(0).ship;
    while (t < 60) : (t += 1.0 / 60.0) {
        const now = momentAt(t).ship;
        for (0..12) |k| try testing.expectApproxEqAbs(before[k], now[k], 0.06);
        before = now;
    }
}

test "it rolls right over, and is the right way up again" {
    try testing.expectEqual(@as(f32, 0), rollOver(19));
    try testing.expectApproxEqAbs(std.math.pi, rollOver(21.5), 0.001);
    try testing.expectApproxEqAbs(2 * std.math.pi, rollOver(23.5), 0.001);
    try testing.expectEqual(@as(f32, 0), rollOver(24));
}

test "the dust stays in its box" {
    for ([_]f32{ -5000, -600, -1, 0, 1, 599, 601, 5000 }) |v| {
        const at = wrapped(v);
        try testing.expect(at >= -dust_box / 2 and at <= dust_box / 2);
        try testing.expectApproxEqAbs(@as(f32, 0), @mod(at - v, dust_box), 0.01);
    }
}

test "the engines burn between their bounds" {
    var t: f32 = 0;
    while (t < 5) : (t += 0.013) {
        try testing.expect(flicker(t) >= 0.69 and flicker(t) <= 1.01);
    }
}

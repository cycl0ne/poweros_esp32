// SPDX-License-Identifier: MIT
//! The ship: the Cobra Mk III's numbers from ELITE (1984), its 28 corners and
//! 13 faces, with the two engines and two vents ELITE draws on its back. Its
//! nose is towards +z, its top towards +y and its right towards +x. Colours
//! and the gun's barrel, a line in ELITE, are made here.
//!
//! A face's corners go so that the cross product of its first two edges points
//! out of the ship.

const std = @import("std");

/// The corners ELITE has, and after them the eight of the gun's barrel.
pub const corners = [_][3]f32{
    .{ 32, 0, 76 },
    .{ -32, 0, 76 },
    .{ 0, 26, 24 },
    .{ -120, -3, -8 },
    .{ 120, -3, -8 },
    .{ -88, 16, -40 },
    .{ 88, 16, -40 },
    .{ 128, -8, -40 },
    .{ -128, -8, -40 },
    .{ 0, 26, -40 },
    .{ -32, -24, -40 },
    .{ 32, -24, -40 },
    .{ -36, 8, -40 },
    .{ -8, 12, -40 },
    .{ 8, 12, -40 },
    .{ 36, 8, -40 },
    .{ 36, -12, -40 },
    .{ 8, -16, -40 },
    .{ -8, -16, -40 },
    .{ -36, -12, -40 },
    .{ 0, 0, 76 },
    .{ 0, 0, 90 },
    .{ -80, -6, -40 },
    .{ -80, 6, -40 },
    .{ -88, 0, -40 },
    .{ 80, 6, -40 },
    .{ 88, 0, -40 },
    .{ 80, -6, -40 },
    // The barrel.
    .{ -1, 1, 70 },
    .{ 1, 1, 70 },
    .{ 1, -1, 70 },
    .{ -1, -1, 70 },
    .{ -1, 1, 90 },
    .{ 1, 1, 90 },
    .{ 1, -1, 90 },
    .{ -1, -1, 90 },
};

// 0xAARRGGBB. An alpha below full is how much of it shines by itself.
const nose: u32 = 0xFFD8DEE6;
const top: u32 = 0xFFB4C0D0;
const shoulder: u32 = 0xFF94A4BC;
const wing_tip: u32 = 0xFFD06A30;
const back: u32 = 0xFF4A525C;
const belly: u32 = 0xFF6E7E96;
const barrel: u32 = 0xFF70747C;
pub const engine: u32 = 0x00FFA040;
pub const vent: u32 = 0x00FF5030;

pub const Face = struct {
    at: []const u8,
    color: u32,
};

/// The ship's skin, closed.
pub const hull = [_]Face{
    .{ .at = &.{ 0, 2, 1 }, .color = nose },
    .{ .at = &.{ 1, 2, 5 }, .color = top },
    .{ .at = &.{ 0, 6, 2 }, .color = top },
    .{ .at = &.{ 1, 5, 3 }, .color = shoulder },
    .{ .at = &.{ 0, 4, 6 }, .color = shoulder },
    .{ .at = &.{ 2, 9, 5 }, .color = shoulder },
    .{ .at = &.{ 2, 6, 9 }, .color = shoulder },
    .{ .at = &.{ 3, 5, 8 }, .color = wing_tip },
    .{ .at = &.{ 4, 7, 6 }, .color = wing_tip },
    .{ .at = &.{ 5, 9, 6, 7, 11, 10, 8 }, .color = back },
    .{ .at = &.{ 1, 3, 8, 10 }, .color = belly },
    .{ .at = &.{ 0, 1, 10, 11 }, .color = belly },
    .{ .at = &.{ 0, 11, 7, 4 }, .color = belly },
};

/// What lies on the back, drawn a little behind it.
pub const decals = [_]Face{
    .{ .at = &.{ 12, 13, 18, 19 }, .color = engine },
    .{ .at = &.{ 14, 15, 16, 17 }, .color = engine },
    .{ .at = &.{ 22, 24, 23 }, .color = vent },
    .{ .at = &.{ 25, 26, 27 }, .color = vent },
};

/// The engines: where the flames start.
pub const engines = [_][4]u8{ .{ 12, 13, 18, 19 }, .{ 14, 15, 16, 17 } };

/// The barrel: not in ELITE, which draws a line from corner 20 to 21.
pub const gun = [_]Face{
    .{ .at = &.{ 28, 32, 33, 29 }, .color = barrel },
    .{ .at = &.{ 29, 33, 34, 30 }, .color = barrel },
    .{ .at = &.{ 30, 34, 35, 31 }, .color = barrel },
    .{ .at = &.{ 31, 35, 32, 28 }, .color = barrel },
    .{ .at = &.{ 32, 35, 34, 33 }, .color = barrel },
};

/// ELITE's 38 edges, each once: what is drawn with WIRE.
pub const edges = blk: {
    var list: [38][2]u8 = undefined;
    var count: usize = 0;
    // A skin's edge is in two faces, in each the other way round.
    for (hull) |face| for (face.at, 0..) |from, k| {
        const to = face.at[(k + 1) % face.at.len];
        if (from < to) {
            list[count] = .{ from, to };
            count += 1;
        }
    };
    for (decals) |face| for (face.at, 0..) |from, k| {
        list[count] = .{ from, face.at[(k + 1) % face.at.len] };
        count += 1;
    };
    list[count] = .{ 20, 21 };
    count += 1;
    if (count != list.len) @compileError("the ship's edges do not come to ELITE's 38");
    break :blk list;
};

/// The most triangles and corners all the faces make.
pub fn meshCorners() usize {
    var count: usize = 0;
    for (hull) |face| count += face.at.len;
    for (decals) |face| count += face.at.len;
    for (gun) |face| count += face.at.len;
    return count;
}

/// The way a face looks, of length 1.
pub fn normalOf(face: Face) [3]f32 {
    const a = corners[face.at[0]];
    const b = corners[face.at[1]];
    const c = corners[face.at[2]];
    const u = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const v = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    const n = [3]f32{ u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0] };
    const length = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    return .{ n[0] / length, n[1] / length, n[2] / length };
}

const testing = std.testing;

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

test "every edge of the skin is in two faces, once each way" {
    for (hull) |face| for (face.at, 0..) |from, k| {
        const to = face.at[(k + 1) % face.at.len];
        var back_again: u32 = 0;
        var same_way: u32 = 0;
        for (hull) |other| for (other.at, 0..) |p, j| {
            const q = other.at[(j + 1) % other.at.len];
            if (p == to and q == from) back_again += 1;
            if (p == from and q == to) same_way += 1;
        };
        try testing.expectEqual(@as(u32, 1), back_again);
        try testing.expectEqual(@as(u32, 1), same_way);
    };
}

test "every face looks out of the ship" {
    for (hull) |face| try testing.expect(dot(normalOf(face), corners[face.at[0]]) > 0);
    for (decals) |face| try testing.expect(normalOf(face)[2] > 0.99 or normalOf(face)[2] < -0.99);
    for (decals) |face| try testing.expect(normalOf(face)[2] < 0);
}

test "the faces lie flat, to the unit and a half ELITE's whole numbers leave" {
    for (hull) |face| {
        const n = normalOf(face);
        const height = dot(n, corners[face.at[0]]);
        for (face.at) |at| try testing.expectApproxEqAbs(height, dot(n, corners[at]), 1.5);
    }
}

test "the faces come to ELITE's normals, as far as its small numbers tell" {
    // Faces 0, 1, 7, 10 and 11 of ELITE's table, as it has them.
    const elite = [_]struct { face: usize, normal: [3]f32 }{
        .{ .face = 0, .normal = .{ 0, 62, 31 } },
        .{ .face = 1, .normal = .{ -18, 55, 16 } },
        .{ .face = 7, .normal = .{ -61, 102, 0 } },
        .{ .face = 10, .normal = .{ -7, -42, 9 } },
        .{ .face = 11, .normal = .{ 0, -30, 6 } },
    };
    for (elite) |each| {
        const length = @sqrt(dot(each.normal, each.normal));
        try testing.expect(dot(normalOf(hull[each.face]), each.normal) / length > 0.995);
    }
}

test "a wing is the mirror of the other" {
    for (corners[0..12]) |corner| {
        var mirrored = false;
        for (corners[0..12]) |other| {
            if (other[0] == -corner[0] and other[1] == corner[1] and other[2] == corner[2]) mirrored = true;
        }
        try testing.expect(mirrored);
    }
}

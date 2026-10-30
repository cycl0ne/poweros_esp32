// SPDX-License-Identifier: MIT
//! The planet's picture, made when the program starts: seas, land, ice at the
//! poles and clouds over them, from noise taken on the sphere itself, so that
//! it has no seam and is not pinched at the poles.
//!
//! Rows go from the north pole (+y) to the south, columns once round.

const std = @import("std");

pub const width = 1024;
pub const height = 512;

/// A number from 0 to 1 for a point of the lattice.
fn lattice(x: i32, y: i32, z: i32) f32 {
    var h: u32 = @bitCast(x *% 73856093 ^ y *% 19349663 ^ z *% 83492791);
    h = (h ^ h >> 13) *% 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xFFFF)) / 65535.0;
}

fn smooth(t: f32) f32 {
    return t * t * (3 - 2 * t);
}

fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Noise from 0 to 1, changing about once a unit.
fn noise(p: [3]f32) f32 {
    const fx = @floor(p[0]);
    const fy = @floor(p[1]);
    const fz = @floor(p[2]);
    const x: i32 = @intFromFloat(fx);
    const y: i32 = @intFromFloat(fy);
    const z: i32 = @intFromFloat(fz);
    const u = smooth(p[0] - fx);
    const v = smooth(p[1] - fy);
    const w = smooth(p[2] - fz);
    return mix(
        mix(mix(lattice(x, y, z), lattice(x + 1, y, z), u), mix(lattice(x, y + 1, z), lattice(x + 1, y + 1, z), u), v),
        mix(mix(lattice(x, y, z + 1), lattice(x + 1, y, z + 1), u), mix(lattice(x, y + 1, z + 1), lattice(x + 1, y + 1, z + 1), u), v),
        w,
    );
}

/// `octaves` of noise, each twice as fine and half as strong, from 0 to 1.
fn layers(p: [3]f32, octaves: u32, scale: f32) f32 {
    var sum: f32 = 0;
    var strength: f32 = 0.5;
    var at = scale;
    var total: f32 = 0;
    for (0..octaves) |_| {
        sum += noise(.{ p[0] * at + 11, p[1] * at + 17, p[2] * at + 23 }) * strength;
        total += strength;
        strength *= 0.5;
        at *= 2;
    }
    return sum / total;
}

fn between(from: f32, to: f32, t: f32) f32 {
    return std.math.clamp((t - from) / (to - from), 0, 1);
}

const Colour = [3]f32;

fn mixed(a: Colour, b: Colour, t: f32) Colour {
    return .{ mix(a[0], b[0], t), mix(a[1], b[1], t), mix(a[2], b[2], t) };
}

const sea_level: f32 = 0.5;

/// The colour of the point `p` of the sphere of radius 1, 0xFFRRGGBB.
pub fn colourAt(p: [3]f32) u32 {
    const ground = layers(p, 5, 2.2);
    const land = between(sea_level, sea_level + 0.012, ground);
    const heights = between(sea_level, sea_level + 0.2, ground);
    const sea = mixed(.{ 0.02, 0.07, 0.24 }, .{ 0.05, 0.22, 0.42 }, between(sea_level - 0.1, sea_level, ground));
    const earth = mixed(mixed(.{ 0.16, 0.34, 0.14 }, .{ 0.5, 0.42, 0.24 }, between(0.1, 0.55, heights)), .{ 0.42, 0.38, 0.34 }, between(0.6, 1, heights));
    var colour = mixed(sea, earth, land);
    const north = @abs(p[1]) + (layers(p, 2, 6) - 0.5) * 0.14;
    colour = mixed(colour, .{ 0.92, 0.95, 0.98 }, between(0.8, 0.84, north));
    const cloud = between(0.52, 0.68, layers(.{ p[0] * 1.6, p[1] * 3, p[2] * 1.6 }, 4, 2.5));
    colour = mixed(colour, .{ 1, 1, 1 }, cloud * 0.85);
    return 0xFF00_0000 |
        @as(u32, @intFromFloat(colour[0] * 255)) << 16 |
        @as(u32, @intFromFloat(colour[1] * 255)) << 8 |
        @as(u32, @intFromFloat(colour[2] * 255));
}

/// Where column `u` and row `v`, each from 0 to 1, are on the sphere.
pub fn pointAt(u: f32, v: f32) [3]f32 {
    const down = v * std.math.pi;
    const round = u * 2 * std.math.pi;
    return .{ @sin(down) * @cos(round), @cos(down), @sin(down) * @sin(round) };
}

/// The whole picture: `width` x `height` pixels, each 0xAARRGGBB.
pub fn fill(pixels: []u32) void {
    for (0..height) |row| {
        const v = (@as(f32, @floatFromInt(row)) + 0.5) / height;
        for (0..width) |column| {
            const u = (@as(f32, @floatFromInt(column)) + 0.5) / width;
            pixels[row * width + column] = colourAt(pointAt(u, v));
        }
    }
}

const testing = std.testing;

fn blueOf(colour: u32) i32 {
    return @intCast(colour & 0xFF);
}
fn redOf(colour: u32) i32 {
    return @intCast(colour >> 16 & 0xFF);
}

test "the poles are white" {
    try testing.expect(redOf(colourAt(.{ 0, 1, 0 })) > 180);
    try testing.expect(redOf(colourAt(.{ 0, -1, 0 })) > 180);
}

test "there is sea, there is land, and neither is all of it" {
    var seas: u32 = 0;
    var lands: u32 = 0;
    for (0..64) |column| for (8..24) |row| {
        const u = @as(f32, @floatFromInt(column)) / 64;
        const v = @as(f32, @floatFromInt(row)) / 32;
        const p = pointAt(u, v);
        if (layers(p, 5, 2.2) < sea_level) seas += 1 else lands += 1;
    };
    try testing.expect(seas > 64 * 16 / 8);
    try testing.expect(lands > 64 * 16 / 8);
}

test "the picture has no seam" {
    for (1..16) |k| {
        const v = @as(f32, @floatFromInt(k)) / 16;
        const a = colourAt(pointAt(0, v));
        const b = colourAt(pointAt(1, v));
        try testing.expect(@abs(redOf(a) - redOf(b)) <= 2);
        try testing.expect(@abs(blueOf(a) - blueOf(b)) <= 2);
    }
}

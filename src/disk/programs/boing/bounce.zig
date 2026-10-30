// SPDX-License-Identifier: MIT
//! How the ball moves: from wall to wall at one speed, falling and bouncing
//! back up from the floor as high each time, turning the way it is going.
//! Places are in the picture's units: 672 x 480, as boing.zig draws it.

const std = @import("std");

/// The ball's centre stays between these: its edge then touches the wall's.
pub const left: f32 = 207;
pub const right: f32 = 465;
/// Where its centre is as it touches the floor.
pub const floor: f32 = 328;
const across_speed: f32 = 110;
const gravity: f32 = 961;
/// Up from the floor: this much takes it back to about 125, by the wall's top.
const bounce_speed: f32 = 625;
/// Radians a second.
const turn_speed: f32 = 2.8;

pub const Hits = struct {
    floor: bool = false,
    wall: bool = false,
};

pub const Motion = struct {
    x: f32 = 320,
    y: f32 = 135,
    across: f32 = across_speed,
    down: f32 = 0,
    turned: f32 = 0,

    /// `seconds` on, and what the ball touched in them.
    pub fn step(motion: *Motion, seconds: f32) Hits {
        var hits = Hits{};
        motion.x += motion.across * seconds;
        if (motion.x > right) {
            motion.x = 2 * right - motion.x;
            motion.across = -across_speed;
            hits.wall = true;
        } else if (motion.x < left) {
            motion.x = 2 * left - motion.x;
            motion.across = across_speed;
            hits.wall = true;
        }
        motion.down += gravity * seconds;
        motion.y += motion.down * seconds;
        if (motion.y > floor) {
            motion.y = floor - (motion.y - floor);
            motion.down = -bounce_speed;
            hits.floor = true;
        }
        // Its front goes the way it is going: see boing.zig's turning.
        const turn = if (motion.across > 0) -turn_speed else turn_speed;
        motion.turned = @rem(motion.turned + turn * seconds, 2 * std.math.pi);
        return hits;
    }

    /// Where the ball is between the walls, as a sound's place between the
    /// speakers: -1 at the left, 1 at the right.
    pub fn pan(motion: *const Motion) f32 {
        return (motion.x - left) / (right - left) * 2 - 1;
    }
};

/// How the ball turns from old to new and back: every `every` seconds it
/// starts to, and takes the last of those seconds over it, smoothly.
pub const Morph = struct {
    every: f32,
    seconds: f32 = 0,

    const longest: f32 = 1.5;

    pub fn step(morph: *Morph, seconds: f32) void {
        morph.seconds = @rem(morph.seconds + seconds, 2 * morph.every);
    }

    /// 0 for the old ball, 1 for the new.
    pub fn round(morph: *const Morph) f32 {
        const going_back = morph.seconds >= morph.every;
        const into = if (going_back) morph.seconds - morph.every else morph.seconds;
        const takes = @min(longest, morph.every / 2);
        const t = std.math.clamp((into - (morph.every - takes)) / takes, 0, 1);
        const smooth = t * t * (3 - 2 * t);
        return if (going_back) 1 - smooth else smooth;
    }
};

const testing = std.testing;

test "the ball stays between the walls and above the floor, and comes back as high" {
    var motion = Motion{};
    var highest_after_bounce: f32 = floor;
    var bounces: u32 = 0;
    var walls: u32 = 0;
    for (0..60 * 60) |_| {
        const hits = motion.step(1.0 / 60.0);
        try testing.expect(motion.x >= left and motion.x <= right);
        try testing.expect(motion.y <= floor);
        if (hits.floor) bounces += 1;
        if (hits.wall) walls += 1;
        if (bounces > 0) highest_after_bounce = @min(highest_after_bounce, motion.y);
    }
    try testing.expect(bounces > 40 and bounces < 60);
    try testing.expect(walls > 20 and walls < 30);
    try testing.expectApproxEqAbs(@as(f32, 125), highest_after_bounce, 8);
}

test "a wall turns it round and the way it spins, and a late frame loses nothing" {
    var motion = Motion{ .x = right - 1 };
    const before = motion.turned;
    try testing.expect(!motion.step(0.001).wall);
    try testing.expect(motion.turned < before);
    const hits = motion.step(0.1);
    try testing.expect(hits.wall);
    try testing.expect(motion.across < 0);
    const turning = motion.turned;
    _ = motion.step(0.01);
    try testing.expect(motion.turned > turning);
}

test "the walls it turns at are as far from the picture's middle" {
    try testing.expectEqual(@as(f32, 672), left + right);
}

test "the morph stays old, turns new, stays new and turns back, every so many seconds" {
    var morph = Morph{ .every = 10 };
    try testing.expectEqual(@as(f32, 0), morph.round());
    morph.step(8.4);
    try testing.expectEqual(@as(f32, 0), morph.round());
    morph.step(0.85);
    try testing.expect(morph.round() > 0.4 and morph.round() < 0.6);
    morph.step(0.75);
    try testing.expectApproxEqAbs(@as(f32, 1), morph.round(), 0.001);
    morph.step(8.4);
    try testing.expectApproxEqAbs(@as(f32, 1), morph.round(), 0.001);
    morph.step(0.85);
    try testing.expect(morph.round() > 0.4 and morph.round() < 0.6);
    morph.step(0.75);
    try testing.expectApproxEqAbs(@as(f32, 0), morph.round(), 0.001);
}

test "a morph every second is not over before it starts" {
    var morph = Morph{ .every = 1 };
    morph.step(0.75);
    try testing.expect(morph.round() > 0.4 and morph.round() < 0.6);
}

test "its sound's place follows it" {
    try testing.expectEqual(@as(f32, -1), (Motion{ .x = left }).pan());
    try testing.expectEqual(@as(f32, 1), (Motion{ .x = right }).pan());
}

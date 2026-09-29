// SPDX-License-Identifier: MIT
//! The transform that turns a block of eight by eight numbers back into
//! eight by eight pixels.
//!
//! A JPEG holds a picture as how much of each of sixty-four patterns is
//! in every block: a flat one, then ever finer waves across and down.
//! Putting the block back together is adding those patterns up again,
//! each times its own number.
//!
//! **It is done as written, not as fast as it could be.** The sum comes
//! apart into a pass across the rows and a pass down the columns, which
//! is eight times less work than the whole sum and is where every
//! decoder starts; the well-known factorings that go further trade a
//! page of butterflies for another factor of five, and a picture that
//! takes a fifth of a second to open instead of a twentieth is not
//! worth a page nobody can read. The table of waves is built once, at
//! compile time.
//!
//! The numbers are fixed point: the table is scaled by 2^13, the pass
//! across takes 2^11 of that back off, and the pass down takes the rest
//! off at the end. Each shift rounds rather than cuts, because a whole
//! picture built out of numbers that were always cut downwards comes out
//! a shade too dark. The pass down adds up in sixty-four bits, because the
//! largest block a file may hold would otherwise not fit in thirty-two.

const std = @import("std");

/// How far the table is scaled up.
const scale_bits = 13;
/// What the pass across takes back off, so that the pass down starts
/// from numbers that cannot run away.
const row_bits = 11;

/// How much of the `u`th wave is at place `x`, scaled by 2^13.
const waves = makeWaves();

fn makeWaves() [8][8]i32 {
    @setEvalBranchQuota(100_000);
    var table: [8][8]i32 = undefined;
    for (0..8) |u| {
        // The flat wave counts for less, so that the transform and its
        // opposite give back what they were given.
        const weight: f64 = if (u == 0) 0.7071067811865476 else 1.0;
        for (0..8) |x| {
            const angle = (2.0 * @as(f64, @floatFromInt(x)) + 1.0) *
                @as(f64, @floatFromInt(u)) * std.math.pi / 16.0;
            const value = weight / 2.0 * @cos(angle);
            table[u][x] = @intFromFloat(@round(value * (1 << scale_bits)));
        }
    }
    return table;
}

/// A block of sixty-four numbers turned into eight rows of eight pixels,
/// written into `into` `stride` bytes apart.
///
/// The numbers are what the file held times what its table said, and the
/// pixels come out shifted up by half the range and held inside it, as
/// the format has them.
pub fn block(from: *const [64]i32, into: [*]u8, stride: usize) void {
    var across: [64]i32 = undefined;
    for (0..8) |y| {
        const row = from[y * 8 ..][0..8];
        for (0..8) |x| {
            var sum: i32 = 0;
            for (0..8) |u| sum += waves[u][x] * row[u];
            across[y * 8 + x] = (sum + (1 << (row_bits - 1))) >> row_bits;
        }
    }
    for (0..8) |x| {
        for (0..8) |y| {
            var sum: i64 = 0;
            for (0..8) |v| sum += @as(i64, waves[v][y]) * across[v * 8 + x];
            const down = 2 * scale_bits - row_bits;
            const value = ((sum + (1 << (down - 1))) >> down) + 128;
            into[y * stride + x] = clamp(value);
        }
    }
}

/// A number held inside what a byte can say.
pub fn clamp(value: i64) u8 {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return @intCast(value);
}

const testing = std.testing;

test "a block of one flat number is a flat block" {
    var from: [64]i32 = @splat(0);
    // The flat wave alone: every pixel the same, an eighth of what the
    // number says above the middle of the range.
    from[0] = 512;
    var into: [64]u8 = undefined;
    block(&from, &into, 8);
    for (into) |pixel| try testing.expectEqual(@as(u8, 192), pixel);
}

test "the first wave across runs light to dark" {
    var from: [64]i32 = @splat(0);
    from[1] = 512;
    var into: [64]u8 = undefined;
    block(&from, &into, 8);
    // Every row the same, and each pixel darker than the one before it.
    for (0..8) |y| {
        for (1..8) |x| try testing.expect(into[y * 8 + x] < into[y * 8 + x - 1]);
        try testing.expectEqual(into[0], into[y * 8]);
    }
}

test "nothing at all is the middle of the range" {
    const from: [64]i32 = @splat(0);
    var into: [64]u8 = undefined;
    block(&from, &into, 8);
    for (into) |pixel| try testing.expectEqual(@as(u8, 128), pixel);
}

test "a block runs the other way when its first number does" {
    var from: [64]i32 = @splat(0);
    from[0] = -1024;
    var into: [64]u8 = undefined;
    block(&from, &into, 8);
    for (into) |pixel| try testing.expectEqual(@as(u8, 0), pixel);
}

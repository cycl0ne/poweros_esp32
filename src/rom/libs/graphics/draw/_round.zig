// SPDX-License-Identifier: MPL-2.0
//! What a rounded rectangle is made of, shared by the fill and the
//! outline.
//!
//! A corner is a quarter of a circle, and a circle drawn by whole numbers
//! is a run of spans: for each row of the corner, how far in from the edge
//! the shape begins. Working that out once, as a table of insets from the
//! top row of the corner down, gives the fill its span ends and the
//! outline its points, and guarantees the two agree - an outline drawn
//! round a fill that disagreed by a pixel would leave a gap on one side
//! and a double line on the other.
//!
//! The inset for row `i` of a corner of radius `r` is `r - sqrt(r*r -
//! (r-1-i)*(r-1-i))`, rounded, worked out with whole numbers.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const Rect = graphics.Rect;

/// The largest radius a rectangle can carry: half its shorter side, so
/// the two corners of an edge meet rather than cross.
///
/// INPUTS:
/// - `area` - the rectangle.
/// - `radius` - what was asked for.
pub fn fits(area: Rect, radius: u32) i32 {
    const shorter = @min(area.width(), area.height());
    if (shorter <= 0) return 0;
    return @min(@as(i32, @intCast(radius)), @divTrunc(shorter, 2));
}

/// How far in from the edge the corner begins, for each row of it from
/// the top down. `into` must hold `radius` of them.
///
/// INPUTS:
/// - `radius` - the corner's radius, at most `into.len`.
/// - `into` - where the insets are written.
pub fn insets(radius: i32, into: []i32) void {
    var i: i32 = 0;
    while (i < radius) : (i += 1) {
        const up = radius - 1 - i;
        const across = isqrt(@as(u32, @intCast(radius * radius - up * up)));
        into[@intCast(i)] = radius - across;
    }
}

/// How far in from the edge row `i` of a corner of `radius` begins, from
/// the top row of the corner down: what `insets` writes into a table,
/// worked out for one row.
///
/// INPUTS:
/// - `radius` - the corner's radius.
/// - `i` - the row, 0 to `radius - 1`.
pub fn insetAt(radius: i32, i: i32) i32 {
    const up = radius - 1 - i;
    return radius - isqrt(@intCast(radius * radius - up * up));
}

/// How far in a rounded rectangle's row `y` starts: the corner's inset on
/// the rows a corner reaches, nothing between them.
///
/// INPUTS:
/// - `box` - the rectangle.
/// - `radius` - its corners' radius, already fitted to it.
/// - `y` - the row.
pub fn rowInset(box: @import("sdk").graphics.Rect, radius: i32, y: i32) i32 {
    if (radius <= 0) return 0;
    if (y < box.min_y + radius) return insetAt(radius, y - box.min_y);
    if (y >= box.max_y - radius) return insetAt(radius, box.max_y - 1 - y);
    return 0;
}

/// How far across an ellipse of `rx` by `ry` reaches on the row `dy` from
/// its centre: the hard-edged span's half.
pub fn halfAcross(rx: i32, ry: i32, dy: i32) i32 {
    if (ry <= 0) return rx;
    const a: i64 = rx;
    const b: i64 = ry;
    const d: i64 = dy;
    const across = @divTrunc(a * a * (b * b - d * d), b * b);
    return isqrt(@intCast(@max(across, 0)));
}

/// The whole-number square root: the largest `n` with `n * n <= value`.
///
/// By Newton's method on whole numbers, which settles in a handful of
/// steps for anything a radius can be and needs no floating point.
///
/// INPUTS:
/// - `value` - the number to take the root of.
pub fn isqrt(value: u32) i32 {
    if (value == 0) return 0;
    var guess: u32 = value;
    var next: u32 = (guess + 1) / 2;
    while (next < guess) {
        guess = next;
        next = (guess + value / guess) / 2;
    }
    return @intCast(guess);
}

/// The most rows of a corner this library works out at once. A radius
/// larger than this is taken down to it: a corner of 256 pixels on a
/// display of 600 rows is already half the screen, and the alternative is
/// memory for a table in a call that cannot fail.
pub const radius_max: i32 = 256;

const testing = @import("std").testing;

test "the whole-number square root lands on the root, not past it" {
    try testing.expectEqual(@as(i32, 0), isqrt(0));
    try testing.expectEqual(@as(i32, 1), isqrt(1));
    try testing.expectEqual(@as(i32, 1), isqrt(3));
    try testing.expectEqual(@as(i32, 2), isqrt(4));
    try testing.expectEqual(@as(i32, 3), isqrt(15));
    try testing.expectEqual(@as(i32, 4), isqrt(16));
    try testing.expectEqual(@as(i32, 31), isqrt(1023));
    try testing.expectEqual(@as(i32, 32), isqrt(1024));
}

test "a radius is taken down to half the shorter side" {
    const wide = Rect{ .max_x = 100, .max_y = 20 };
    try testing.expectEqual(@as(i32, 10), fits(wide, 40));
    try testing.expectEqual(@as(i32, 5), fits(wide, 5));
    try testing.expectEqual(@as(i32, 0), fits(wide, 0));
    const empty = Rect{};
    try testing.expectEqual(@as(i32, 0), fits(empty, 8));
}

test "the corner's insets go from the widest to none" {
    var table: [8]i32 = undefined;
    insets(8, &table);
    // The top row of the corner is the most inset, the bottom none.
    try testing.expect(table[0] > table[7]);
    try testing.expectEqual(@as(i32, 0), table[7]);
    // It never goes backwards on the way down.
    for (table[1..], 0..) |inset, i| try testing.expect(inset <= table[i]);
}

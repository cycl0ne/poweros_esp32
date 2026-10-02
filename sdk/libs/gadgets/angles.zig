// SPDX-License-Identifier: MIT
//! Angles for the classes that draw round things, in whole degrees and
//! without floating point: where a point at an angle lies, and the angle
//! a point lies at.
//!
//! Degrees are counted as graphics.library's `FillArc` counts them: 0 to
//! the right, increasing anticlockwise - up the screen, whose y runs down.
//! The sines are a table the compiler fills, in 1/16384ths.

/// The scale of `sine`'s answers: 1.0.
pub const one: i32 = 16384;

const sines = table: {
    @setEvalBranchQuota(20_000);
    var made: [91]i32 = undefined;
    for (&made, 0..) |*s, degree| {
        const radians: f64 = @as(f64, @floatFromInt(degree)) * 3.14159265358979323846 / 180.0;
        s.* = @intFromFloat(@round(@sin(radians) * @as(f64, @floatFromInt(one))));
    }
    break :table made;
};

/// The sine of `degrees`, any whole number of them, in 1/16384ths.
pub fn sine(degrees: i32) i32 {
    const d = @mod(degrees, 360);
    return switch (d) {
        0...90 => sines[@intCast(d)],
        91...180 => sines[@intCast(180 - d)],
        181...270 => -sines[@intCast(d - 180)],
        else => -sines[@intCast(360 - d)],
    };
}

/// The cosine of `degrees`, in 1/16384ths.
pub fn cosine(degrees: i32) i32 {
    return sine(degrees + 90);
}

/// The point `radius` from (`cx`, `cy`) at `degrees`, on the screen.
pub fn pointAt(cx: i32, cy: i32, radius: i32, degrees: i32) [2]i32 {
    const dx = @divFloor(radius * cosine(degrees) + one / 2, one);
    const dy = @divFloor(radius * sine(degrees) + one / 2, one);
    return .{ cx + dx, cy - dy };
}

/// The angle, 0 to 359, the point (`dx`, `dy`) away from a centre lies
/// at, on the screen (`dy` down). 0 for the centre itself.
pub fn angleOf(dx: i32, dy: i32) i32 {
    const x: i64 = dx;
    const y: i64 = -@as(i64, dy);
    if (x == 0 and y == 0) return 0;
    // The degree whose sine and cosine point nearest the same way: the
    // one that turns (x, y) least, found by the cross product's sign
    // across the quarter, then by halving.
    var low: i32 = 0;
    var high: i32 = 360;
    // A first guess by quarter keeps the halving inside one.
    if (y >= 0) {
        if (x >= 0) high = 90 else {
            low = 90;
            high = 180;
        }
    } else {
        if (x < 0) {
            low = 180;
            high = 270;
        } else low = 270;
    }
    while (high - low > 1) {
        const middle = low + @divTrunc(high - low, 2);
        // Positive when (x, y) is anticlockwise of the middle's direction.
        const cross = @as(i64, cosine(middle)) * y - @as(i64, sine(middle)) * x;
        if (cross >= 0) low = middle else high = middle;
    }
    // The nearer of the two.
    const cross_low = @as(i64, cosine(low)) * y - @as(i64, sine(low)) * x;
    const cross_high = @as(i64, sine(high)) * x - @as(i64, cosine(high)) * y;
    return @mod(if (cross_low <= cross_high) low else high, 360);
}

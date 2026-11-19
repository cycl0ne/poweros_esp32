// SPDX-License-Identifier: MIT
//! Paint's built-in brushes and what they put down: a round or a square
//! brush of 1 to 32 pixels, stamped at a place or along a line.
//!
//! A brush is a box `size` pixels across, held by its middle: the pixel
//! at `size / 2` across and down is the one under the pointer. A square
//! brush covers its whole box; a round one the pixels whose middles lie
//! in the circle that fits the box, so a round brush of 1 or 2 is its
//! box. A line is stamped at every pixel of it (Bresenham's steps), both
//! ends included, which leaves no gap at any slope.
//!
//! The airbrush sprays single pixels at random over a disc round the
//! place, its radius four times the brush's size - eight pixels at the
//! least - as many at a time as a sixteenth of the radius squared: about
//! one pixel in fifty of the disc.

const picture_zig = @import("picture.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;

pub const Shape = enum { round, square };

/// The largest brush.
pub const max_size = 32;

/// The sizes the Brush menu offers, smallest first; the keys that make a
/// brush smaller and larger step through them.
pub const sizes = [_]u32{ 1, 2, 3, 4, 6, 8, 12, 16, 24, 32 };

pub const Brush = struct {
    shape: Shape = .round,
    size: u32 = 1,

    /// Whether the brush covers the pixel (`dx`, `dy`) of its box.
    pub fn covers(brush: Brush, dx: u32, dy: u32) bool {
        if (brush.shape == .square or brush.size <= 2) return true;
        // Twice the distance from the box's middle to the pixel's, against
        // the box's width: whole numbers throughout.
        const size: i32 = @intCast(brush.size);
        const across = 2 * @as(i32, @intCast(dx)) + 1 - size;
        const down = 2 * @as(i32, @intCast(dy)) + 1 - size;
        return across * across + down * down <= size * size;
    }

    /// The box's top left corner when its handle is at (`x`, `y`).
    pub fn corner(brush: Brush, x: i32, y: i32) [2]i32 {
        const handle: i32 = @intCast(brush.size / 2);
        return .{ x - handle, y - handle };
    }

    /// The area the brush covers put down at (`x`, `y`).
    pub fn areaAt(brush: Brush, x: i32, y: i32) Area {
        const at = brush.corner(x, y);
        const size: i32 = @intCast(brush.size);
        return .{ .min_x = at[0], .min_y = at[1], .max_x = at[0] + size, .max_y = at[1] + size };
    }

    /// The next size up or down the list, as far as it goes.
    pub fn stepped(brush: Brush, larger: bool) Brush {
        var made = brush;
        if (larger) {
            for (sizes) |size| if (size > brush.size) {
                made.size = size;
                return made;
            };
        } else {
            var at = sizes.len;
            while (at > 0) {
                at -= 1;
                if (sizes[at] < brush.size) {
                    made.size = sizes[at];
                    return made;
                }
            }
        }
        return made;
    }
};

/// The brush put down at (`x`, `y`) in `colour`: the pixels it covers
/// inside the picture take the colour, and `changed` grows by its area.
pub fn stamp(picture: *Picture, brush: Brush, x: i32, y: i32, colour: Pixel, changed: *Area) void {
    const area = brush.areaAt(x, y);
    const cut = area.clip(picture.width, picture.height);
    if (cut.isEmpty()) return;
    var py = cut.min_y;
    while (py < cut.max_y) : (py += 1) {
        const pixels = picture.row(@intCast(py));
        var px = cut.min_x;
        while (px < cut.max_x) : (px += 1) {
            if (brush.covers(@intCast(px - area.min_x), @intCast(py - area.min_y))) pixels[@intCast(px)] = colour;
        }
    }
    changed.* = changed.add(cut);
}

/// The brush stamped at every pixel of the line from (`x0`, `y0`) to
/// (`x1`, `y1`), both ends included.
pub fn line(picture: *Picture, brush: Brush, x0: i32, y0: i32, x1: i32, y1: i32, colour: Pixel, changed: *Area) void {
    const across: i32 = if (x1 > x0) x1 - x0 else x0 - x1;
    const down: i32 = if (y1 > y0) y0 - y1 else y1 - y0;
    const step_x: i32 = if (x0 < x1) 1 else -1;
    const step_y: i32 = if (y0 < y1) 1 else -1;
    var err = across + down;
    var x = x0;
    var y = y0;
    while (true) {
        stamp(picture, brush, x, y, colour, changed);
        if (x == x1 and y == y1) return;
        const twice = 2 * err;
        if (twice >= down) {
            err += down;
            x += step_x;
        }
        if (twice <= across) {
            err += across;
            y += step_y;
        }
    }
}

/// Numbers that look random enough for a spray: xorshift, never 0.
pub const Random = struct {
    state: u32 = 0x2545_F491,

    pub fn next(random: *Random) u32 {
        var value = if (random.state == 0) 1 else random.state;
        value ^= value << 13;
        value ^= value >> 17;
        value ^= value << 5;
        random.state = value;
        return value;
    }

    /// One of 0 to `limit` - 1.
    fn below(random: *Random, limit: u32) u32 {
        return random.next() % limit;
    }
};

/// How far the airbrush reaches from the place, for this brush.
pub fn sprayRadius(brush: Brush) u32 {
    return @max(8, brush.size * 4);
}

/// How many pixels one spray puts down, for this brush.
pub fn sprayCount(brush: Brush) u32 {
    const radius = sprayRadius(brush);
    return @max(4, radius * radius / 16);
}

/// One spray of the airbrush at (`x`, `y`): `sprayCount` pixels at random
/// within `sprayRadius` of it, those outside the picture lost.
pub fn spray(picture: *Picture, brush: Brush, x: i32, y: i32, colour: Pixel, random: *Random, changed: *Area) void {
    const radius = sprayRadius(brush);
    const reach: i32 = @intCast(radius);
    const limit = reach * reach;
    var left = sprayCount(brush);
    // Places in the square round the disc, those in the disc kept.
    var tries = 2 * left;
    while (left > 0 and tries > 0) : (tries -= 1) {
        const dx: i32 = @as(i32, @intCast(random.below(2 * radius + 1))) - reach;
        const dy: i32 = @as(i32, @intCast(random.below(2 * radius + 1))) - reach;
        if (dx * dx + dy * dy > limit) continue;
        left -= 1;
        const px = x + dx;
        const py = y + dy;
        if (!picture.inside(px, py)) continue;
        picture.set(@intCast(px), @intCast(py), colour);
        changed.* = changed.add(.{ .min_x = px, .min_y = py, .max_x = px + 1, .max_y = py + 1 });
    }
}

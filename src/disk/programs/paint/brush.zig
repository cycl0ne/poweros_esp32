// SPDX-License-Identifier: MIT
//! Paint's brushes and what they put down: a round or a square brush of
//! 1 to 64 pixels, or one of the user's own - cut from the picture or
//! loaded - stamped at a place or along a line.
//!
//! A brush is a box, held by its middle: the pixel half its width across
//! and half its height down is the one under the pointer. A square brush
//! covers its whole box; a round one the pixels whose middles lie in the
//! circle that fits the box, so a round brush of 1 or 2 is its box. A
//! line is stamped at every pixel of it (Bresenham's steps), both ends
//! included, which leaves no gap at any slope.
//!
//! **A brush of one's own** is a picture: it covers what its pixels
//! cover. It goes down in its own colours, or as its shape in the
//! stroke's colour (`Mode`). Where it covers a pixel wholly it takes the
//! pixel's place, as the round and square brushes do; where it covers it
//! in part it is laid over it (`overlay`), its edge mixing into what is
//! there. `ink` is that rule, pixel by pixel, for stamping and for the
//! brush shown under the pointer alike (`Ghost`), so what is shown is
//! what goes down. It is flipped, turned a quarter, halved and doubled
//! (`transform`); halving keeps every second pixel and doubling makes
//! each pixel four, so a picture's own colours stay its own.
//!
//! The airbrush sprays single pixels at random over a disc round the
//! place, its radius four times the brush's longer side - eight pixels
//! at the least, and no more than for the largest round brush - as many
//! at a time as a sixteenth of the radius squared: about one pixel in
//! fifty of the disc.

const picture_zig = @import("picture.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;

pub const Shape = enum { round, square };

/// How a brush of one's own is put down: as it is, or its shape in the
/// stroke's colour.
pub const Mode = enum { own_colours, one_colour };

/// The largest built-in brush.
pub const max_size = 64;

/// The longest side a brush of one's own may have, grabbed, loaded or
/// doubled.
pub const max_own_side = 1024;

/// The sizes the Brush menu offers, smallest first; the keys that make a
/// brush smaller and larger step through them.
pub const sizes = [_]u32{ 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64 };

pub const Brush = struct {
    shape: Shape = .round,
    size: u32 = 1,
    /// A brush of one's own in use in place of the round or square one.
    own: ?*const Picture = null,
    mode: Mode = .own_colours,

    pub fn width(brush: Brush) u32 {
        return if (brush.own) |own| own.width else brush.size;
    }

    pub fn height(brush: Brush) u32 {
        return if (brush.own) |own| own.height else brush.size;
    }

    /// Its longer side.
    pub fn span(brush: Brush) u32 {
        return @max(brush.width(), brush.height());
    }

    /// Whether the brush covers the pixel (`dx`, `dy`) of its box.
    pub fn covers(brush: Brush, dx: u32, dy: u32) bool {
        if (brush.own) |own| return own.get(dx, dy) >> 24 != 0;
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
        return .{ x - @as(i32, @intCast(brush.width() / 2)), y - @as(i32, @intCast(brush.height() / 2)) };
    }

    /// The area the brush covers put down at (`x`, `y`).
    pub fn areaAt(brush: Brush, x: i32, y: i32) Area {
        const at = brush.corner(x, y);
        return .{ .min_x = at[0], .min_y = at[1], .max_x = at[0] + @as(i32, @intCast(brush.width())), .max_y = at[1] + @as(i32, @intCast(brush.height())) };
    }

    /// What the brush put down in `colour` makes of `under`, the
    /// picture's pixel at (`dx`, `dy`) of its box; null where it does
    /// not reach.
    pub fn ink(brush: Brush, dx: u32, dy: u32, colour: Pixel, under: Pixel) ?Pixel {
        const own = brush.own orelse return if (brush.covers(dx, dy)) colour else null;
        const pixel = own.get(dx, dy);
        const coverage = pixel >> 24;
        if (coverage == 0) return null;
        const put = switch (brush.mode) {
            .own_colours => pixel,
            .one_colour => (colour & 0x00FF_FFFF) | (((colour >> 24) * coverage + 127) / 255) << 24,
        };
        return if (coverage == 0xFF) put else overlay(put, under);
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

/// `top` laid over `under` as far as `top`'s coverage goes: the two
/// colours mixed by it, and what shows of each counted into the
/// coverage made.
pub fn overlay(top: Pixel, under: Pixel) Pixel {
    const top_cover = top >> 24;
    if (top_cover == 0xFF) return top;
    if (top_cover == 0) return under;
    // Out of 255 x 255: what shows of `top`, and of `under` through it.
    const own = top_cover * 255;
    const through = (under >> 24) * (255 - top_cover);
    const total = own + through;
    var mixed: Pixel = ((total + 127) / 255) << 24;
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const above = (top >> shift) & 0xFF;
        const below = (under >> shift) & 0xFF;
        mixed |= ((above * own + below * through + total / 2) / total) << shift;
    }
    return mixed;
}

/// The brush put down at (`x`, `y`) in `colour`: the pixels it covers
/// inside the picture inked, and `changed` grown by its area.
pub fn stamp(picture: *Picture, brush: Brush, x: i32, y: i32, colour: Pixel, changed: *Area) void {
    const area = brush.areaAt(x, y);
    const cut = area.clip(picture.width, picture.height);
    if (cut.isEmpty()) return;
    var py = cut.min_y;
    while (py < cut.max_y) : (py += 1) {
        const pixels = picture.row(@intCast(py));
        var px = cut.min_x;
        while (px < cut.max_x) : (px += 1) {
            const pixel = &pixels[@intCast(px)];
            if (brush.ink(@intCast(px - area.min_x), @intCast(py - area.min_y), colour, pixel.*)) |made| pixel.* = made;
        }
    }
    changed.* = changed.add(cut);
}

/// The brush shown where it would go down: laid over the view's rows,
/// never put into the picture.
pub const Ghost = struct {
    brush: Brush,
    colour: Pixel,
    area: Area,

    pub fn at(brush: Brush, x: i32, y: i32, colour: Pixel) Ghost {
        return .{ .brush = brush, .colour = colour, .area = brush.areaAt(x, y) };
    }

    /// Whether the picture's row `y` has some of it.
    pub fn crosses(ghost: *const Ghost, y: i32) bool {
        return y >= ghost.area.min_y and y < ghost.area.max_y;
    }

    /// The picture's pixel at (`x`, `y`), `under`, as the brush put down
    /// would leave it.
    pub fn shown(ghost: *const Ghost, x: i32, y: i32, under: Pixel) Pixel {
        const area = ghost.area;
        if (x < area.min_x or x >= area.max_x or y < area.min_y or y >= area.max_y) return under;
        return ghost.brush.ink(@intCast(x - area.min_x), @intCast(y - area.min_y), ghost.colour, under) orelse under;
    }
};

/// What can be done to a brush of one's own.
pub const Transform = enum { flip_across, flip_down, turn, halve, double };

/// The size a brush `width` by `height` has after `which`; null when
/// that is past `max_own_side`.
pub fn transformedSize(which: Transform, width: u32, height: u32) ?[2]u32 {
    const size: [2]u32 = switch (which) {
        .flip_across, .flip_down => .{ width, height },
        .turn => .{ height, width },
        .halve => .{ (width + 1) / 2, (height + 1) / 2 },
        .double => .{ width * 2, height * 2 },
    };
    if (size[0] > max_own_side or size[1] > max_own_side) return null;
    return size;
}

/// `from` made into `into`, which is the size `transformedSize` says:
/// flipped left to right or top to bottom, turned a quarter to the
/// right, halved - every second pixel each way kept - or doubled - each
/// pixel made four.
pub fn transform(which: Transform, from: *const Picture, into: *Picture) void {
    var y: u32 = 0;
    while (y < into.height) : (y += 1) {
        var x: u32 = 0;
        while (x < into.width) : (x += 1) {
            const source: [2]u32 = switch (which) {
                .flip_across => .{ from.width - 1 - x, y },
                .flip_down => .{ x, from.height - 1 - y },
                // The left column, read upwards, is the top row.
                .turn => .{ y, from.height - 1 - x },
                .halve => .{ 2 * x, 2 * y },
                .double => .{ x / 2, y / 2 },
            };
            into.set(x, y, from.get(source[0], source[1]));
        }
    }
}

/// The area of `picture`, inside it, copied into `into` - its size - as
/// a brush: the pixels of the colour `clear` left out, see-through.
pub fn grab(picture: *const Picture, area: Area, clear: Pixel, into: *Picture) void {
    var y: u32 = 0;
    while (y < into.height) : (y += 1) {
        const from = picture.row(@intCast(area.min_y + @as(i32, @intCast(y))))[@intCast(area.min_x)..];
        for (into.row(y), from[0..into.width]) |*pixel, colour| pixel.* = if (colour == clear) 0 else colour;
    }
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

/// How far the airbrush reaches from the place, for this brush: from its
/// longer side, whichever brush it is.
pub fn sprayRadius(brush: Brush) u32 {
    return @max(8, @min(brush.span(), max_size) * 4);
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

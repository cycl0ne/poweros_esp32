// SPDX-License-Identifier: MIT
//! Paint's brushes and what they put down: a round or a square brush of
//! 1 to 64 pixels, hard or soft, or one of the user's own - cut from the picture or
//! loaded - stamped at a place or along a line.
//!
//! A brush is a box, held by its middle: the pixel half its width across
//! and half its height down is the one under the pointer. A square brush
//! covers its whole box; a round one the pixels whose middles lie in the
//! circle that fits the box, so a round brush of 1 or 2 is its box. A
//! soft one fades from a part of its radius to its edge (`softness`). A
//! square brush or a brush of one's own can be turned (`rotation`): its
//! box is the box round it turned, and each pixel of that box takes what
//! lies under its middle turned back - whole numbers throughout, from a
//! table of sines worked out as the program is built.
//!
//! **The ink.** Everything goes down through an `Ink`: the picture, the
//! colour, the settings (`Settings`: opacity, flow, jitter, dither) and a
//! mask of how much paint each pixel has had in the change being made.
//! At full opacity and flow without dither a stamp replaces what it
//! covers wholly and is laid over what it covers in part (`lay`). Below
//! that, a stamp adds its coverage times the flow to the mask, and the
//! pixel gets just the paint that lifts it from the mask times the
//! opacity before to after - so a change never puts more than the
//! opacity on a pixel, however often the brush passes - and dither makes
//! that paint whole or none by a 4 by 4 pattern. The eraser is the same
//! rule taking coverage away. Jitter moves each stamp at random, up to
//! the brush's longer side. A line is stamped along its pixels
//! (Bresenham's steps), which leaves no gap at any slope: at every pixel
//! for whole paint, every quarter of the brush's longer side for paint
//! that builds up, with its end reached by `finish`.
//!
//! **Smudging** takes up the colours under the brush where a stroke
//! begins, and at each pixel along it lays them down by the brush's
//! coverage times the flow and the opacity and takes up what is there
//! then: the colours are dragged along, thinning as they go.
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
    /// How far a built-in brush fades towards its edge, in per cent of
    /// its radius: 0 a hard edge, 100 a fade from its middle.
    softness: u8 = 0,
    /// How far a square brush or a brush of one's own is turned
    /// clockwise, in degrees.
    rotation: u16 = 0,

    pub fn width(brush: Brush) u32 {
        return brush.box()[0];
    }

    pub fn height(brush: Brush) u32 {
        return brush.box()[1];
    }

    /// Its longer side.
    pub fn span(brush: Brush) u32 {
        return @max(brush.width(), brush.height());
    }

    /// Whether it is turned: a round brush is the same however far.
    fn turned(brush: Brush) bool {
        return brush.rotation % 360 != 0 and (brush.own != null or brush.shape == .square);
    }

    /// Its box: its own size, or, turned, the box round it turned.
    pub fn box(brush: Brush) [2]u32 {
        const plain: [2]u64 = if (brush.own) |own| .{ own.width, own.height } else .{ brush.size, brush.size };
        if (!brush.turned()) return .{ @intCast(plain[0]), @intCast(plain[1]) };
        const angle = brush.rotation % 360;
        const across: u64 = @abs(cosine(angle));
        const down: u64 = @abs(sine(angle));
        const turned_width = (plain[0] * across + plain[1] * down + 0xFFFF) >> 16;
        const turned_height = (plain[0] * down + plain[1] * across + 0xFFFF) >> 16;
        return .{ @intCast(@max(turned_width, 1)), @intCast(@max(turned_height, 1)) };
    }

    /// Where the middle of the pixel (`dx`, `dy`) of its box lies on the
    /// brush before it was turned: twice its distance from the middle,
    /// across and down.
    fn unturned(brush: Brush, dx: u32, dy: u32) [2]i64 {
        const sides = brush.box();
        const across = 2 * @as(i64, dx) + 1 - @as(i64, sides[0]);
        const down = 2 * @as(i64, dy) + 1 - @as(i64, sides[1]);
        if (!brush.turned()) return .{ across, down };
        const angle = brush.rotation % 360;
        const cos: i64 = cosine(angle);
        const sin: i64 = sine(angle);
        return .{ (across * cos + down * sin + 0x8000) >> 16, (down * cos - across * sin + 0x8000) >> 16 };
    }

    /// A brush of one's own's pixel at (`dx`, `dy`) of the box: turned,
    /// the one it was turned from, see-through past its edge.
    fn ownPixel(brush: Brush, own: *const Picture, dx: u32, dy: u32) Pixel {
        if (!brush.turned()) return own.get(dx, dy);
        const at = brush.unturned(dx, dy);
        const x = @divFloor(at[0] + own.width, 2);
        const y = @divFloor(at[1] + own.height, 2);
        if (x < 0 or y < 0 or x >= own.width or y >= own.height) return 0;
        return own.get(@intCast(x), @intCast(y));
    }

    /// How much of the pixel (`dx`, `dy`) of its box the brush covers, 0
    /// to 255.
    pub fn coverage(brush: Brush, dx: u32, dy: u32) u32 {
        if (brush.own) |own| return brush.ownPixel(own, dx, dy) >> 24;
        const size: i64 = brush.size;
        const softness: i64 = @min(brush.softness, 100);
        const at = brush.unturned(dx, dy);
        switch (brush.shape) {
            .round => {
                if (brush.size <= 2 and softness == 0) return 255;
                // Twice the distance from the middle, against the box's
                // width: whole numbers throughout.
                const squared = at[0] * at[0] + at[1] * at[1];
                if (squared > size * size) return 0;
                const hard = @divTrunc(size * (100 - softness), 100);
                if (squared <= hard * hard) return 255;
                return @intCast(@divTrunc(255 * (size - squareRoot(squared)), size - hard));
            },
            .square => {
                const inside = size - @max(magnitude(at[0]), magnitude(at[1]));
                if (inside < 0) return 0;
                const band = @divTrunc(size * softness, 100);
                if (inside >= band) return 255;
                return @intCast(@divTrunc(255 * inside, band));
            },
        }
    }

    /// Whether the brush covers the pixel (`dx`, `dy`) of its box at all.
    pub fn covers(brush: Brush, dx: u32, dy: u32) bool {
        return brush.coverage(dx, dy) != 0;
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

    /// What the brush puts down at the pixel (`dx`, `dy`) of its box,
    /// stroked in `colour`: a colour, whole, and how much of the pixel it
    /// covers; null where it covers nothing. A brush of one's own gives
    /// its own colours or, in one colour, the stroke's.
    pub fn tip(brush: Brush, dx: u32, dy: u32, colour: Pixel) ?Dab {
        if (brush.own) |own| {
            const pixel = brush.ownPixel(own, dx, dy);
            const cover = pixel >> 24;
            if (cover == 0) return null;
            return switch (brush.mode) {
                .own_colours => .{ .colour = pixel | 0xFF00_0000, .coverage = cover },
                .one_colour => .{ .colour = colour, .coverage = cover },
            };
        }
        const cover = brush.coverage(dx, dy);
        if (cover == 0) return null;
        return .{ .colour = colour, .coverage = cover };
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

/// What a brush puts on a pixel: a colour, whole, and how much of the
/// pixel it covers, 0 to 255.
pub const Dab = struct { colour: Pixel, coverage: u32 };

/// How a change's paint goes down.
pub const Settings = struct {
    /// The most paint the change puts on a pixel, in per cent.
    opacity: u8 = 100,
    /// How much of that a stamp gives, in per cent: below 100 the paint
    /// builds up where the brush goes again.
    flow: u8 = 100,
    /// How far each stamp is moved at random, in per cent of the brush's
    /// longer side.
    jitter: u8 = 0,
    /// Paint short of whole made whole or none by a 4 by 4 pattern.
    dither: bool = false,

    /// Whether paint goes down whole, a stamp at a time, with no mask.
    pub fn whole(settings: Settings) bool {
        return settings.opacity >= 100 and settings.flow >= 100 and !settings.dither;
    }
};

/// Paint put on, or taken off.
pub const Kind = enum { paint, erase };

/// The colour with its coverage scaled by `coverage` of 255.
fn scaled(colour: Pixel, coverage: u32) Pixel {
    return (colour & 0x00FF_FFFF) | (((colour >> 24) * coverage + 127) / 255) << 24;
}

/// `pixel` with `amount` of 255 of it taken away; nothing left is 0.
fn erased(pixel: Pixel, amount: u32) Pixel {
    const left = ((pixel >> 24) * (255 - amount) + 127) / 255;
    return if (left == 0) 0 else (pixel & 0x00FF_FFFF) | left << 24;
}

/// The order a 4 by 4 pattern's pixels take paint in, row by row.
const pattern = [16]u8{ 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

/// `amount` of paint made whole or none at the picture's (`x`, `y`).
fn dithered(amount: u32, x: i32, y: i32) u32 {
    const place: usize = @intCast((y & 3) * 4 + (x & 3));
    return if (amount > @as(u32, pattern[place]) * 16 + 8) 255 else 0;
}

/// A pixel laid: what it is now, and how much paint it has had in the
/// change.
pub const Laid = struct { pixel: Pixel, had: u8 };

/// What a dab of `colour` covering `coverage` of 255 makes of `under`,
/// the picture's pixel at (`x`, `y`), which has had `had` of paint in
/// this change. Whole paint replaces what it covers wholly and is laid
/// over what it covers in part, or takes that much away. Otherwise the
/// dab adds its coverage times the flow to what the pixel has had, and
/// the pixel gets just the paint that lifts it from that times the
/// opacity before to after - so a change never puts more than the
/// opacity on a pixel - dithered when that is asked.
pub fn lay(settings: Settings, kind: Kind, under: Pixel, colour: Pixel, coverage: u32, had: u8, x: i32, y: i32) Laid {
    if (settings.whole()) {
        const pixel = switch (kind) {
            .paint => if (coverage == 255) colour else overlay(scaled(colour, coverage), under),
            .erase => erased(under, coverage),
        };
        return .{ .pixel = pixel, .had = had };
    }
    const given = (coverage * @min(settings.flow, 100) + 50) / 100;
    const before: u32 = had;
    const after = before + (given * (255 - before) + 127) / 255;
    const opacity: u32 = @min(settings.opacity, 100);
    var shown_before = (before * opacity + 50) / 100;
    var shown_after = (after * opacity + 50) / 100;
    if (settings.dither) {
        shown_before = dithered(shown_before, x, y);
        shown_after = dithered(shown_after, x, y);
    }
    if (shown_after <= shown_before) return .{ .pixel = under, .had = @intCast(after) };
    // The part of what is left that the paint now takes.
    const step = ((shown_after - shown_before) * 255 + (255 - shown_before) / 2) / (255 - shown_before);
    const pixel = switch (kind) {
        .paint => overlay(scaled(colour, step), under),
        .erase => erased(under, step),
    };
    return .{ .pixel = pixel, .had = @intCast(after) };
}

/// What a change puts its paint down with: the picture, the colour and
/// the settings, and what it has done so far.
pub const Ink = struct {
    picture: *Picture,
    colour: Pixel,
    settings: Settings = .{},
    kind: Kind = .paint,
    /// How much paint each pixel has had in this change, a byte a pixel
    /// in the picture's order, all 0 when the change begins - `clearMask`
    /// as it ends. Unused while the settings put paint down whole;
    /// without it, every stamp is as the first.
    mask: []u8 = &.{},
    /// Where jitter takes its numbers from; none, no jitter.
    random: ?*Random = null,
    /// Pixels a line has walked in this change, so the next goes on
    /// stamping where it left off.
    walked: u32 = 0,

    /// A dab laid on the picture's pixel (`x`, `y`), which is inside it.
    pub fn put(ink: *const Ink, x: u32, y: u32, dab: Dab) void {
        const place = @as(usize, y) * ink.picture.width + x;
        const pixel = &ink.picture.pixels[place];
        const masked = !ink.settings.whole() and place < ink.mask.len;
        const laid = lay(ink.settings, ink.kind, pixel.*, dab.colour, dab.coverage, if (masked) ink.mask[place] else 0, @intCast(x), @intCast(y));
        pixel.* = laid.pixel;
        if (masked) ink.mask[place] = laid.had;
    }
};

/// The mask emptied over `area`, inside a picture `width` across, as a
/// change there ends or is drawn again.
pub fn clearMask(mask: []u8, width: u32, area: Area) void {
    if (mask.len == 0 or area.isEmpty()) return;
    var y = area.min_y;
    while (y < area.max_y) : (y += 1) {
        const start = @as(usize, @intCast(y)) * width;
        @memset(mask[start + @as(usize, @intCast(area.min_x)) .. start + @as(usize, @intCast(area.max_x))], 0);
    }
}

/// The brush put down at (`x`, `y`) - moved by the jitter - with the
/// ink: the pixels it covers inside the picture laid, and `changed`
/// grown by its area.
pub fn stamp(ink: *const Ink, brush: Brush, x: i32, y: i32, changed: *Area) void {
    var at = [2]i32{ x, y };
    if (ink.settings.jitter != 0) if (ink.random) |random| {
        const reach = brush.span() * @min(ink.settings.jitter, 100) / 100;
        for (&at) |*axis| axis.* += @as(i32, @intCast(random.below(2 * reach + 1))) - @as(i32, @intCast(reach));
    };
    const area = brush.areaAt(at[0], at[1]);
    const cut = area.clip(ink.picture.width, ink.picture.height);
    if (cut.isEmpty()) return;
    var py = cut.min_y;
    while (py < cut.max_y) : (py += 1) {
        var px = cut.min_x;
        while (px < cut.max_x) : (px += 1) {
            const dab = brush.tip(@intCast(px - area.min_x), @intCast(py - area.min_y), ink.colour) orelse continue;
            ink.put(@intCast(px), @intCast(py), dab);
        }
    }
    changed.* = changed.add(cut);
}

/// The brush shown where it would go down: laid over the view's rows,
/// never put into the picture - a stamp's worth, as a click puts down.
pub const Ghost = struct {
    brush: Brush,
    colour: Pixel,
    settings: Settings,
    kind: Kind,
    area: Area,

    pub fn at(brush: Brush, x: i32, y: i32, colour: Pixel, settings: Settings, kind: Kind) Ghost {
        return .{ .brush = brush, .colour = colour, .settings = settings, .kind = kind, .area = brush.areaAt(x, y) };
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
        const dab = ghost.brush.tip(@intCast(x - area.min_x), @intCast(y - area.min_y), ghost.colour) orelse return under;
        return lay(ghost.settings, ghost.kind, under, dab.colour, dab.coverage, 0, x, y).pixel;
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

/// The pixels of the line from (`x0`, `y0`) to (`x1`, `y1`), both ends
/// in: Bresenham's steps, which leave no gap at any slope.
const Steps = struct {
    x: i32,
    y: i32,
    x1: i32,
    y1: i32,
    across: i32,
    down: i32,
    step_x: i32,
    step_y: i32,
    err: i32,
    done: bool = false,

    fn of(x0: i32, y0: i32, x1: i32, y1: i32) Steps {
        const across: i32 = if (x1 > x0) x1 - x0 else x0 - x1;
        const down: i32 = if (y1 > y0) y0 - y1 else y1 - y0;
        return .{
            .x = x0,
            .y = y0,
            .x1 = x1,
            .y1 = y1,
            .across = across,
            .down = down,
            .step_x = if (x0 < x1) 1 else -1,
            .step_y = if (y0 < y1) 1 else -1,
            .err = across + down,
        };
    }

    fn next(steps: *Steps) ?[2]i32 {
        if (steps.done) return null;
        const at = [2]i32{ steps.x, steps.y };
        if (steps.x == steps.x1 and steps.y == steps.y1) {
            steps.done = true;
            return at;
        }
        const twice = 2 * steps.err;
        if (twice >= steps.down) {
            steps.err += steps.down;
            steps.x += steps.step_x;
        }
        if (twice <= steps.across) {
            steps.err += steps.across;
            steps.y += steps.step_y;
        }
        return at;
    }
};

/// The brush stamped along the line from (`x0`, `y0`) to (`x1`, `y1`):
/// at every pixel for whole paint, every quarter of the brush's longer
/// side for paint that builds up - so the flow means the same for any
/// size. A line that goes on from where the change's last one ended
/// does not walk that pixel again.
pub fn line(ink: *Ink, brush: Brush, x0: i32, y0: i32, x1: i32, y1: i32, changed: *Area) void {
    const every: u32 = if (ink.settings.whole()) 1 else @max(1, brush.span() / 4);
    var steps = Steps.of(x0, y0, x1, y1);
    var first = true;
    while (steps.next()) |at| {
        defer first = false;
        if (first and ink.walked != 0) continue;
        if (ink.walked % every == 0) stamp(ink, brush, at[0], at[1], changed);
        ink.walked +%= 1;
    }
}

/// The end of a stroke or an open line, at (`x`, `y`), stamped when the
/// spacing left it out, so paint that builds up reaches it too.
pub fn finish(ink: *Ink, brush: Brush, x: i32, y: i32, changed: *Area) void {
    const every: u32 = if (ink.settings.whole()) 1 else @max(1, brush.span() / 4);
    if (ink.walked != 0 and (ink.walked - 1) % every != 0) stamp(ink, brush, x, y, changed);
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
/// within `sprayRadius` of it, each laid with the ink, those outside the
/// picture lost.
pub fn spray(ink: *const Ink, brush: Brush, x: i32, y: i32, random: *Random, changed: *Area) void {
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
        if (!ink.picture.inside(px, py)) continue;
        ink.put(@intCast(px), @intCast(py), .{ .colour = ink.colour, .coverage = 255 });
        changed.* = changed.add(.{ .min_x = px, .min_y = py, .max_x = px + 1, .max_y = py + 1 });
    }
}

// --- smudging -------------------------------------------------------------------

/// The colours under the brush put at (`x`, `y`) taken up into
/// `carried`, the brush's box in size; past the picture's edge, the
/// nearest pixel in it.
pub fn takeUp(picture: *const Picture, brush: Brush, x: i32, y: i32, carried: *Picture) void {
    const corner_at = brush.corner(x, y);
    const right: i32 = @as(i32, @intCast(picture.width)) - 1;
    const bottom: i32 = @as(i32, @intCast(picture.height)) - 1;
    var dy: u32 = 0;
    while (dy < carried.height) : (dy += 1) {
        const py = @max(0, @min(bottom, corner_at[1] + @as(i32, @intCast(dy))));
        var dx: u32 = 0;
        while (dx < carried.width) : (dx += 1) {
            const px = @max(0, @min(right, corner_at[0] + @as(i32, @intCast(dx))));
            carried.set(dx, dy, picture.get(@intCast(px), @intCast(py)));
        }
    }
}

/// `from` moved `amount` of 255 of the way to `to`, every channel,
/// coverage too.
fn towards(from: Pixel, to: Pixel, amount: u32) Pixel {
    var made: Pixel = 0;
    var shift: u5 = 0;
    while (true) : (shift += 8) {
        const a: i32 = @intCast((from >> shift) & 0xFF);
        const b: i32 = @intCast((to >> shift) & 0xFF);
        const channel = a + @divTrunc((b - a) * @as(i32, @intCast(amount)) + (if (b >= a) @as(i32, 127) else -127), 255);
        made |= @as(Pixel, @intCast(channel)) << shift;
        if (shift == 24) return made;
    }
}

/// The carried colours laid down where the brush covers at (`x`, `y`),
/// by its coverage times the flow and the opacity, and what is there
/// then taken up again: the colours dragged along, thinning as they go.
pub fn smear(ink: *const Ink, brush: Brush, x: i32, y: i32, carried: *Picture, changed: *Area) void {
    const strength: u32 = @as(u32, @min(ink.settings.flow, 100)) * @min(ink.settings.opacity, 100);
    const area = brush.areaAt(x, y);
    const cut = area.clip(ink.picture.width, ink.picture.height);
    if (cut.isEmpty()) return;
    var py = cut.min_y;
    while (py < cut.max_y) : (py += 1) {
        var px = cut.min_x;
        while (px < cut.max_x) : (px += 1) {
            const dx: u32 = @intCast(px - area.min_x);
            const dy: u32 = @intCast(py - area.min_y);
            const amount = (brush.coverage(dx, dy) * strength + 5000) / 10000;
            if (amount == 0) continue;
            const now = towards(ink.picture.get(@intCast(px), @intCast(py)), carried.get(dx, dy), amount);
            ink.picture.set(@intCast(px), @intCast(py), now);
            carried.set(dx, dy, now);
        }
    }
    changed.* = changed.add(cut);
}

/// `smear` at every pixel of the line from (`x0`, `y0`) to (`x1`,
/// `y1`), the first left out when the change's last line ended there.
pub fn smearLine(ink: *Ink, brush: Brush, carried: *Picture, x0: i32, y0: i32, x1: i32, y1: i32, changed: *Area) void {
    var steps = Steps.of(x0, y0, x1, y1);
    var first = true;
    while (steps.next()) |at| {
        defer first = false;
        if (first and ink.walked != 0) continue;
        smear(ink, brush, at[0], at[1], carried, changed);
        ink.walked +%= 1;
    }
}

// --- whole numbers ----------------------------------------------------------------

/// The sines of whole degrees, times 65536, worked out as the program is
/// built.
const sines = table: {
    @setEvalBranchQuota(20000);
    var made: [360]i32 = undefined;
    for (&made, 0..) |*entry, degree| {
        const radians = @as(f64, @floatFromInt(degree)) * 3.14159265358979323846 / 180.0;
        entry.* = @intFromFloat(@round(@sin(radians) * 65536.0));
    }
    break :table made;
};

fn sine(degree: u32) i32 {
    return sines[degree % 360];
}

fn cosine(degree: u32) i32 {
    return sines[(degree + 90) % 360];
}

fn magnitude(value: i64) i64 {
    return if (value < 0) -value else value;
}

/// The largest whole number whose square is at most `value`.
fn squareRoot(value: i64) i64 {
    if (value < 2) return @max(value, 0);
    var low: i64 = 1;
    var high: i64 = @min(value, 1 << 31);
    while (low < high) {
        const middle = low + @divTrunc(high - low + 1, 2);
        if (middle * middle <= value) low = middle else high = middle - 1;
    }
    return low;
}

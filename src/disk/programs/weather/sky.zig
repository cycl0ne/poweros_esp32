// SPDX-License-Identifier: MIT
//! The weather's pictures: the sky behind everything, and the picture of
//! each kind of weather (`forecast.Sky`) - a sun or a moon, clouds, and
//! what falls from them - drawn in a square of any size.
//!
//! **A picture** is laid out in a square 100 units a side, which `Box`
//! puts where it goes. Its parts are a sun (a disk lit from its upper
//! left, its rays and a glow), a moon (a crescent: the arc of one circle
//! and the arc of a second as large where it cuts into the first), a
//! cloud (three circles over a rounded bar, in one gradient so the
//! pieces are one shape), drops, flakes, a bolt and the bars of fog. By
//! night the sun is the moon.
//!
//! **Its shadow** is the same picture in one dark colour (`Part.shadow`),
//! drawn - for every picture of the view at once - onto a layer that is
//! blurred once and put down under them (`view.zig`).
//!
//! **The sky** is a gradient down the whole picture in the weather's
//! colours, by day or by night: a sun's glow in its upper right on a fine
//! day, stars on a clear night.

const draw = @import("draw.zig");
const forecast = @import("forecast.zig");
const Sky = forecast.Sky;
const Brush = draw.Brush;
const vector = @import("sdk").vector;
const rgb = draw.rgb;

/// Which of a picture is drawn.
pub const Part = enum { picture, shadow };

/// Where a picture goes: its square's top left and side, in pixels.
pub const Box = struct {
    x: f32,
    y: f32,
    size: f32,

    fn x_(box: Box, units: f32) f32 {
        return box.x + units * box.size / 100;
    }

    fn y_(box: Box, units: f32) f32 {
        return box.y + units * box.size / 100;
    }

    fn len(box: Box, units: f32) f32 {
        return units * box.size / 100;
    }
};

/// The colours a cloud is drawn in, top to bottom.
const Tone = struct { top: u32, bottom: u32 };
const tone_light = Tone{ .top = 0xFFFFFF, .bottom = 0xD9E3EE };
const tone_night = Tone{ .top = 0xD2DAE6, .bottom = 0x97A3B6 };
const tone_grey = Tone{ .top = 0xE9EDF2, .bottom = 0xA9B5C3 };
const tone_dark = Tone{ .top = 0xB4BECB, .bottom = 0x778596 };
const tone_storm = Tone{ .top = 0x8A93A5, .bottom = 0x4A5264 };

const shadow_colour = 0x0B1424;

const rain_colour = 0x4FC3F7;
const bolt_colour = 0xFFD54F;
const bolt_edge = 0xFF9800;

/// The picture of `sky` in `box`.
pub fn picture(brush: *const Brush, sky: Sky, day: bool, box: Box, part: Part) void {
    const light: Tone = if (day) tone_light else tone_night;
    switch (sky) {
        .clear => if (day) sun(brush, box, 50, 50, 22, part) else {
            moon(brush, box, 52, 50, 28, part);
            if (part == .picture) {
                star(brush, box, 20, 26, 2.2);
                star(brush, box, 82, 22, 1.6);
                star(brush, box, 78, 80, 1.8);
            }
        },
        .few_clouds => {
            light_of(brush, day, box, 40, 38, 19, part);
            cloud(brush, box, 62, 66, 58, light, part);
        },
        .cloudy => {
            light_of(brush, day, box, 35, 34, 18, part);
            cloud(brush, box, 56, 60, 80, light, part);
        },
        .overcast => {
            cloud(brush, box, 38, 42, 62, tone_dark, part);
            cloud(brush, box, 58, 60, 78, tone_grey, part);
        },
        .fog => {
            cloud(brush, box, 50, 38, 74, tone_grey, part);
            fog(brush, box, part);
        },
        .drizzle => {
            cloud(brush, box, 50, 40, 80, tone_grey, part);
            drizzle(brush, box, part);
        },
        .rain => {
            cloud(brush, box, 50, 38, 82, tone_grey, part);
            drops(brush, box, &.{ .{ 30, 70 }, .{ 50, 74 }, .{ 70, 70 } }, part);
        },
        .heavy_rain => {
            cloud(brush, box, 50, 36, 84, tone_dark, part);
            drops(brush, box, &.{ .{ 24, 66 }, .{ 42, 70 }, .{ 60, 66 }, .{ 78, 70 }, .{ 33, 84 }, .{ 51, 88 }, .{ 69, 84 } }, part);
        },
        .freezing => {
            cloud(brush, box, 50, 38, 82, tone_grey, part);
            drops(brush, box, &.{ .{ 30, 70 }, .{ 62, 72 } }, part);
            flakes(brush, box, &.{ .{ 46, 82 }, .{ 78, 82 } }, 6, part);
        },
        .snow => {
            cloud(brush, box, 50, 38, 82, if (day) tone_light else tone_night, part);
            flakes(brush, box, &.{ .{ 30, 72 }, .{ 52, 80 }, .{ 74, 72 }, .{ 40, 92 }, .{ 64, 92 } }, 6.5, part);
        },
        .showers => {
            light_of(brush, day, box, 33, 30, 16, part);
            cloud(brush, box, 56, 52, 76, tone_grey, part);
            drops(brush, box, &.{ .{ 40, 80 }, .{ 58, 84 }, .{ 76, 80 } }, part);
        },
        .snow_showers => {
            light_of(brush, day, box, 33, 30, 16, part);
            cloud(brush, box, 56, 52, 76, if (day) tone_light else tone_night, part);
            flakes(brush, box, &.{ .{ 40, 82 }, .{ 60, 88 }, .{ 78, 80 } }, 6, part);
        },
        .thunder => {
            cloud(brush, box, 50, 36, 86, tone_storm, part);
            bolt(brush, box, part);
            drops(brush, box, &.{ .{ 26, 72 }, .{ 76, 74 } }, part);
        },
    }
}

/// The sun by day, the moon by night.
fn light_of(brush: *const Brush, day: bool, box: Box, x: f32, y: f32, radius: f32, part: Part) void {
    if (day) sun(brush, box, x, y, radius, part) else moon(brush, box, x, y, radius * 1.15, part);
}

fn shadowPaint() draw.Paint {
    return draw.solid(rgb(shadow_colour, 1));
}

fn sun(brush: *const Brush, box: Box, x_units: f32, y_units: f32, radius_units: f32, part: Part) void {
    const x = box.x_(x_units);
    const y = box.y_(y_units);
    const radius = box.len(radius_units);
    if (part == .shadow) {
        brush.circle(x, y, radius);
        brush.fill(&shadowPaint());
        return;
    }
    // The glow round it.
    const glow = [_]draw.Stop{
        .{ .offset = 0, .colour = rgb(0xFFE9A0, 0.55) },
        .{ .offset = 0.55, .colour = rgb(0xFFD54F, 0.18) },
        .{ .offset = 1, .colour = rgb(0xFFD54F, 0) },
    };
    brush.circle(x, y, radius * 2.1);
    brush.fill(&draw.radial(&glow, x, y, radius * 2.1, x, y));
    // The rays: eight, between the disk and the glow's edge.
    const ray = draw.solid(rgb(0xFFC93C, 0.95));
    const directions = [8][2]f32{ .{ 1, 0 }, .{ 0.7071, 0.7071 }, .{ 0, 1 }, .{ -0.7071, 0.7071 }, .{ -1, 0 }, .{ -0.7071, -0.7071 }, .{ 0, -1 }, .{ 0.7071, -0.7071 } };
    for (directions) |direction| {
        brush.line(x + direction[0] * radius * 1.28, y + direction[1] * radius * 1.28, x + direction[0] * radius * 1.62, y + direction[1] * radius * 1.62);
        brush.stroke(&ray, radius * 0.16);
    }
    // The disk, lit from its upper left.
    const disk = [_]draw.Stop{
        .{ .offset = 0, .colour = rgb(0xFFF8C4, 1) },
        .{ .offset = 0.6, .colour = rgb(0xFFD54F, 1) },
        .{ .offset = 1, .colour = rgb(0xFFAA00, 1) },
    };
    brush.circle(x, y, radius);
    brush.fill(&draw.radial(&disk, x, y, radius, x - radius * 0.35, y - radius * 0.35));
}

/// A crescent: round (x, y) out to `radius`, less a circle as large
/// whose middle is `cut` radii toward the upper right.
fn moon(brush: *const Brush, box: Box, x_units: f32, y_units: f32, radius_units: f32, part: Part) void {
    const x = box.x_(x_units);
    const y = box.y_(y_units);
    const radius = box.len(radius_units);
    const vb = brush.vb;
    // Toward the second circle's middle, and across it.
    const toward = [2]f32{ 0.8, -0.6 };
    const across = [2]f32{ 0.6, 0.8 };
    const cut: f32 = 0.62;
    const half = cut * radius / 2;
    const reach = @sqrt(radius * radius - half * half);
    const first = [2]f32{ x + toward[0] * half + across[0] * reach, y + toward[1] * half + across[1] * reach };
    const second = [2]f32{ x + toward[0] * half - across[0] * reach, y + toward[1] * half - across[1] * reach };
    if (part == .picture) {
        const glow = [_]draw.Stop{
            .{ .offset = 0, .colour = rgb(0xFFF6D8, 0.30) },
            .{ .offset = 1, .colour = rgb(0xFFF6D8, 0) },
        };
        brush.circle(x, y, radius * 1.8);
        brush.fill(&draw.radial(&glow, x, y, radius * 1.8, x, y));
    }
    const path = brush.begin();
    vb.MoveTo(path, first[0], first[1]);
    // The outer circle the long way round, away from the cut; then the
    // cut's circle back, the short way, inside the first.
    vb.ArcTo(path, radius, radius, 0, vector.ARC_LARGE | vector.ARC_SWEEP, second[0], second[1]);
    vb.ArcTo(path, radius, radius, 0, 0, first[0], first[1]);
    vb.ClosePath(path);
    if (part == .shadow) return brush.fill(&shadowPaint());
    const face = [_]draw.Stop{
        .{ .offset = 0, .colour = rgb(0xFFFBEA, 1) },
        .{ .offset = 1, .colour = rgb(0xF5D77A, 1) },
    };
    brush.fill(&draw.radial(&face, x, y, radius, x - radius * 0.5, y + radius * 0.2));
}

fn star(brush: *const Brush, box: Box, x_units: f32, y_units: f32, radius_units: f32) void {
    brush.circle(box.x_(x_units), box.y_(y_units), box.len(radius_units));
    brush.fill(&draw.solid(rgb(0xFFFBEA, 0.9)));
}

/// A cloud `width_units` wide, its middle at (x, y), in `tone`.
fn cloud(brush: *const Brush, box: Box, x_units: f32, y_units: f32, width_units: f32, tone: Tone, part: Part) void {
    const width = box.len(width_units);
    const left = box.x_(x_units) - width / 2;
    const middle = box.y_(y_units);
    const stops = draw.two(rgb(tone.top, 1), rgb(tone.bottom, 1));
    const paint = if (part == .shadow) shadowPaint() else draw.linear(&stops, 0, middle - width * 0.36, 0, middle + width * 0.26);
    // Drawn opaque piece by piece in one gradient, the pieces are one.
    brush.roundRect(left + width * 0.06, middle - width * 0.02, width * 0.88, width * 0.28, width * 0.14);
    brush.fill(&paint);
    brush.circle(left + width * 0.30, middle + width * 0.03, width * 0.19);
    brush.fill(&paint);
    brush.circle(left + width * 0.53, middle - width * 0.08, width * 0.27);
    brush.fill(&paint);
    brush.circle(left + width * 0.76, middle + width * 0.07, width * 0.18);
    brush.fill(&paint);
}

/// Rain falling from each place, slanting left.
fn drops(brush: *const Brush, box: Box, places: []const [2]f32, part: Part) void {
    const paint = if (part == .shadow) shadowPaint() else draw.solid(rgb(rain_colour, 1));
    for (places) |at| {
        brush.line(box.x_(at[0]), box.y_(at[1]), box.x_(at[0] - 4), box.y_(at[1] + 11));
        brush.stroke(&paint, box.len(5));
    }
}

fn drizzle(brush: *const Brush, box: Box, part: Part) void {
    const paint = if (part == .shadow) shadowPaint() else draw.solid(rgb(rain_colour, 0.95));
    const places = [_][2]f32{ .{ 28, 70 }, .{ 46, 76 }, .{ 64, 70 }, .{ 80, 76 }, .{ 36, 88 }, .{ 56, 90 }, .{ 72, 88 } };
    for (places) |at| {
        brush.line(box.x_(at[0]), box.y_(at[1]), box.x_(at[0] - 1.5), box.y_(at[1] + 4));
        brush.stroke(&paint, box.len(3.6));
    }
}

/// A six-armed flake at each place, `arm_units` long.
fn flakes(brush: *const Brush, box: Box, places: []const [2]f32, arm_units: f32, part: Part) void {
    const paint = if (part == .shadow) shadowPaint() else draw.solid(rgb(0xFFFFFF, 1));
    const arm = box.len(arm_units);
    const arms = [3][2]f32{ .{ 1, 0 }, .{ 0.5, 0.866 }, .{ -0.5, 0.866 } };
    for (places) |at| {
        const x = box.x_(at[0]);
        const y = box.y_(at[1]);
        for (arms) |direction| {
            brush.line(x - direction[0] * arm, y - direction[1] * arm, x + direction[0] * arm, y + direction[1] * arm);
            brush.stroke(&paint, @max(box.len(2.2), 1));
        }
    }
}

fn bolt(brush: *const Brush, box: Box, part: Part) void {
    const vb = brush.vb;
    const points = [_][2]f32{ .{ 54, 52 }, .{ 38, 76 }, .{ 50, 76 }, .{ 42, 96 }, .{ 66, 68 }, .{ 54, 68 }, .{ 62, 52 } };
    const path = brush.begin();
    vb.MoveTo(path, box.x_(points[0][0]), box.y_(points[0][1]));
    for (points[1..]) |at| vb.LineTo(path, box.x_(at[0]), box.y_(at[1]));
    vb.ClosePath(path);
    if (part == .shadow) return brush.fill(&shadowPaint());
    const stops = draw.two(rgb(0xFFF59D, 1), rgb(bolt_colour, 1));
    brush.fill(&draw.linear(&stops, 0, box.y_(52), 0, box.y_(96)));
    brush.stroke(&draw.solid(rgb(bolt_edge, 0.9)), @max(box.len(1.6), 1));
}

fn fog(brush: *const Brush, box: Box, part: Part) void {
    const paint = if (part == .shadow) shadowPaint() else draw.solid(rgb(0xEEF2F6, 0.92));
    const bars = [_][3]f32{ .{ 16, 80, 68 }, .{ 26, 90, 79 }, .{ 12, 70, 90 } };
    for (bars) |bar| {
        brush.line(box.x_(bar[0]), box.y_(bar[2]), box.x_(bar[1]), box.y_(bar[2]));
        brush.stroke(&paint, box.len(5.5));
    }
}

// --- the sky ----------------------------------------------------------------------------

/// The sky's colours, top and bottom.
pub const Colours = struct { top: u32, bottom: u32 };

pub fn coloursOf(sky: Sky, day: bool) Colours {
    if (day) return switch (sky) {
        .clear, .few_clouds => .{ .top = 0x1B66D2, .bottom = 0x74BFF0 },
        .cloudy => .{ .top = 0x3B6FA8, .bottom = 0x92B8D6 },
        .overcast, .fog => .{ .top = 0x5D7088, .bottom = 0x99A8B8 },
        .drizzle, .rain, .showers, .freezing => .{ .top = 0x43566C, .bottom = 0x7C8EA2 },
        .heavy_rain => .{ .top = 0x34445A, .bottom = 0x66788C },
        .snow, .snow_showers => .{ .top = 0x5F7D9C, .bottom = 0x9FB5C9 },
        .thunder => .{ .top = 0x2B2742, .bottom = 0x565473 },
    };
    return switch (sky) {
        .clear, .few_clouds => .{ .top = 0x081030, .bottom = 0x283B70 },
        .cloudy => .{ .top = 0x121B36, .bottom = 0x36476B },
        .overcast, .fog => .{ .top = 0x1B2334, .bottom = 0x434F66 },
        .drizzle, .rain, .showers, .freezing, .heavy_rain => .{ .top = 0x121927, .bottom = 0x334056 },
        .snow, .snow_showers => .{ .top = 0x26314B, .bottom = 0x586886 },
        .thunder => .{ .top = 0x100D20, .bottom = 0x302D4A },
    };
}

/// The whole of `width` by `height` painted as the sky of `sky`.
pub fn background(brush: *const Brush, sky: Sky, day: bool, width: f32, height: f32) void {
    const colours = coloursOf(sky, day);
    const stops = draw.two(rgb(colours.top, 1), rgb(colours.bottom, 1));
    brush.roundRect(0, 0, width, height, 0);
    brush.fill(&draw.linear(&stops, 0, 0, 0, height));
    const fine = sky == .clear or sky == .few_clouds or sky == .cloudy;
    if (day and fine) {
        // The sun's light, from beyond the upper right.
        const glow = [_]draw.Stop{
            .{ .offset = 0, .colour = rgb(0xFFF1C1, 0.42) },
            .{ .offset = 1, .colour = rgb(0xFFF1C1, 0) },
        };
        const reach = @max(width, height) * 0.75;
        brush.roundRect(0, 0, width, height, 0);
        brush.fill(&draw.radial(&glow, width * 0.92, -height * 0.05, reach, width * 0.92, -height * 0.05));
    } else if (!day and (sky == .clear or sky == .few_clouds)) {
        // Stars, the same ones each time: a small generator with a fixed
        // start.
        var seed: u32 = 0x2545F491;
        var left: u32 = 70;
        while (left > 0) : (left -= 1) {
            seed = seed *% 1664525 +% 1013904223;
            const x = @as(f32, @floatFromInt(seed >> 16)) / 65536.0 * width;
            seed = seed *% 1664525 +% 1013904223;
            const y = @as(f32, @floatFromInt(seed >> 16)) / 65536.0 * height * 0.7;
            seed = seed *% 1664525 +% 1013904223;
            const shine = @as(f32, @floatFromInt(seed >> 24)) / 256.0;
            brush.circle(x, y, 0.5 + shine * 1.0);
            brush.fill(&draw.solid(rgb(0xFFFFFF, 0.25 + shine * 0.6)));
        }
    }
}

// SPDX-License-Identifier: MIT
//! The pictures below the controls, drawn from the sound being heard into
//! a buffer of 32-bit pixels: a plasma, the wave, or the bars.
//!
//! - **Plasma**: sine waves over the area - one across, one along the
//!   diagonal, one that is the sine of a sum of sines across and down,
//!   which bends it, and rings round a centre that wanders - added and
//!   looked up in a palette that turns. The bass drives it faster, the
//!   treble turns the colours, the loudness lights it. The palette is the
//!   colour wheel, or with a cover the way from its first colour to its
//!   second and back, in bands of light and shade. It is worked out at
//!   half the size and each point drawn as a square of four, which is a
//!   quarter of the work and looks the same.
//! - **Wave**: a fiftieth of a second as a line, started where the sound
//!   rises through zero after it was clearly below it - so a note stands
//!   still and noise does not set it off - each point between two samples
//!   read between them; what was drawn before fades to a quarter each
//!   look, which leaves a trail.
//! - **Bars**: the spectrum (spectrum.zig) as columns of lit segments a
//!   pixel apart, green at the foot to red at the top - or the cover's
//!   first colour to its second - a mark above each where its peak was.
//!
//! The cover's colours (colours.zig) are `tint`, set by the window when a
//! song's cover is read and taken away when it has none.
//!
//! The sine table and the plasma's rows and columns are kept here, so a
//! look costs table lookups and additions - no sine per point. A ring's
//! distance is a square root, which comes from a table too: the squared
//! distances across and down are worked out per column and per row, and
//! the root of their sum looked up. Near the centre, where the root
//! changes fastest, a table holds it for every squared distance; further
//! out one holds it for every share of the farthest, which near the centre
//! would be too coarse - a flat square round it with a step at its edge.
//! Nothing here touches the system: the host tests hold it.

const spectrum = @import("spectrum.zig");
const colours = @import("colours.zig");

pub const Mode = enum(u8) { plasma, wave, bars };
pub const mode_count = 3;

/// The largest area drawn: the plasma's half size is held in these.
pub const max_width = 1280;
pub const max_height = 800;
const half_width = max_width / 2;
const half_height = max_height / 2;
/// The squared distances a ring is looked up by, and how many steps of
/// the sine table the farthest corner is from the centre: four rings.
const root_size = 4096;
const ring_steps = 1024;
/// The squared distances, in the plasma's points, whose root is held
/// exactly (`Visual.near`).
const near_size = 4096;

/// Samples a look takes from the sound: the spectrum's run, which the
/// wave takes too - half of it to find where to start, half to draw.
pub const take = spectrum.fft_size;

pub const Visual = struct {
    mode: Mode = .bars,
    spectrum: spectrum.Spectrum = .{},
    /// 128 + 127 sin, over 256 steps.
    sine: [256]u8 = @splat(0),
    palette: [256]u32 = @splat(0),
    /// The plasma's terms worked out per column, per row and per diagonal.
    across: [half_width]u16 = @splat(0),
    bend_x: [half_width]u8 = @splat(0),
    bend_y: [half_height]u8 = @splat(0),
    diagonal: [half_width + half_height]u16 = @splat(0),
    /// The rings: the squared distance from the centre per column and per
    /// row, in the plasma's points; the root of every share of the
    /// farthest (`root_size` of them), and of every squared distance below
    /// `near_size` for the farthest the area has (`reach`), which is worked
    /// out again when that changes. A squared distance is `share` 65536ths
    /// of a share.
    square_x: [half_width]u32 = @splat(0),
    square_y: [half_height]u32 = @splat(0),
    root: [root_size]u16 = @splat(0),
    near: [near_size]u16 = @splat(0),
    reach: u64 = 0,
    share: u32 = 0,
    /// The plasma's phases, in steps of the sine table: the wave across,
    /// the rings, the diagonal, the bend's two, then the centre across and
    /// down.
    phase: [7]f32 = @splat(0),
    hue: f32 = 0,
    /// The cover's two colours, which the plasma and the bars are drawn
    /// in; null for their own.
    tint: ?colours.Pair = null,
    /// The area as last drawn: a new size starts the trail again.
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(v: *Visual) void {
        v.spectrum.init();
        for (&v.sine, 0..) |*s, i| {
            const angle = @as(f32, @floatFromInt(i)) * (2.0 * 3.14159265358979 / 256.0);
            s.* = @intFromFloat(128.0 + 127.0 * @sin(angle));
        }
        for (&v.root, 0..) |*r, i| {
            const share = @as(f32, @floatFromInt(i)) / @as(f32, root_size - 1);
            r.* = @intFromFloat(@sqrt(share) * ring_steps);
        }
    }

    /// The next mode, round.
    pub fn cycle(v: *Visual) void {
        v.mode = @enumFromInt((@intFromEnum(v.mode) + 1) % mode_count);
        v.width = 0;
    }

    /// The silence after a stop or a seek: the bars drop, the trail goes.
    pub fn quiet(v: *Visual) void {
        v.spectrum.quiet();
    }

    /// One look of `width` by `height` pixels into `pixels`, `stride`
    /// pixels a row, from `samples` (`take` of them, -1 to 1) heard at
    /// `rate`.
    pub fn draw(v: *Visual, pixels: [*]u32, width: u32, height: u32, stride: u32, samples: []const f32, rate: u32) void {
        if (width < 4 or height < 4) return;
        const w = @min(width, max_width);
        const h = @min(height, max_height);
        const fresh = w != v.width or h != v.height;
        v.width = w;
        v.height = h;
        switch (v.mode) {
            .plasma => {
                v.spectrum.analyse(samples, @max(rate, 1), 24);
                v.plasma(pixels, w, h, stride);
            },
            .wave => v.wave(pixels, w, h, stride, samples, fresh),
            .bars => {
                const bands: usize = @min(@max(w / 18, 8), spectrum.max_bands);
                v.spectrum.analyse(samples, @max(rate, 1), bands);
                v.bars(pixels, w, h, stride, bands);
            },
        }
    }

    /// The average level of bands `first` to `last` of 24, 0 to 1.
    fn energy(v: *const Visual, first: usize, last: usize) f32 {
        var sum: f32 = 0;
        for (v.spectrum.levels[first..last]) |level| sum += level;
        return sum / @as(f32, @floatFromInt(last - first));
    }

    fn plasma(v: *Visual, pixels: [*]u32, w: u32, h: u32, stride: u32) void {
        const bass = v.energy(0, 6);
        const treble = v.energy(16, 24);
        const loud = v.energy(0, 24);
        // The phases move a little on their own and more with the bass.
        const speeds = [7]f32{ 1.1, -0.7, 0.9, 1.6, -1.3, 0.37, 0.23 };
        for (&v.phase, speeds) |*phase, speed| phase.* = wrap(phase.* + speed * (0.6 + 6.0 * bass));
        v.hue = wrap(v.hue + 0.4 + 5.0 * treble);
        v.turnPalette(0.5 + 0.5 * loud);

        const cols = (w + 1) / 2;
        const rows = (h + 1) / 2;
        // As many waves across the area whatever its size: one across,
        // three quarters down, one along the diagonal.
        const kx = 256 * 256 / (cols + 1);
        const ky = 192 * 256 / (rows + 1);
        const kd = 256 * 256 / (cols + rows + 1);
        const p0: u32 = @intFromFloat(v.phase[0]);
        const p1: u32 = @intFromFloat(v.phase[1]);
        const p2: u32 = @intFromFloat(v.phase[2]);
        const p3: u32 = @intFromFloat(v.phase[3]);
        const p4: u32 = @intFromFloat(v.phase[4]);
        for (0..cols) |x| {
            const step: u32 = @intCast(x * kx >> 8);
            v.across[x] = v.sine[(step + p0) & 255];
            v.bend_x[x] = v.sine[(step + p3) & 255];
        }
        for (0..rows) |y| {
            const step: u32 = @intCast(y * ky >> 8);
            v.bend_y[y] = v.sine[(step + p4) & 255];
        }
        for (0..cols + rows) |d| {
            const step: u32 = @intCast(d * kd >> 8);
            v.diagonal[d] = v.sine[(step + p2) & 255];
        }
        // The centre swings through the middle half of the area; the
        // farthest a point can be from it is the area's diagonal.
        const swing_x: i32 = @as(i32, v.sine[@as(u32, @intFromFloat(v.phase[5]))]) - 128;
        const swing_y: i32 = @as(i32, v.sine[@as(u32, @intFromFloat(v.phase[6]))]) - 128;
        const centre_x: i32 = @intCast(cols / 2);
        const centre_y: i32 = @intCast(rows / 2);
        const cx = centre_x + @divTrunc(swing_x * centre_x, 256);
        const cy = centre_y + @divTrunc(swing_y * centre_y, 256);
        const reach: u64 = @as(u64, cols) * cols + @as(u64, rows) * rows + 1;
        if (reach != v.reach) v.reachTo(reach);
        for (0..cols) |x| {
            const dx: i64 = @as(i64, @intCast(x)) - cx;
            v.square_x[x] = @intCast(dx * dx);
        }
        for (0..rows) |y| {
            const dy: i64 = @as(i64, @intCast(y)) - cy;
            v.square_y[y] = @intCast(dy * dy);
        }
        for (0..rows) |y| {
            const top = pixels + y * 2 * stride;
            const second = y * 2 + 1 < h;
            for (0..cols) |x| {
                const bend = v.sine[(@as(u32, v.bend_x[x]) + v.bend_y[y]) & 255];
                const ring = v.sine[(v.ringDistance(v.square_x[x] + v.square_y[y]) + p1) & 255];
                const sum = @as(u32, v.across[x]) + v.diagonal[x + y] + bend + ring;
                const colour = v.palette[(sum >> 2) & 255];
                const left = x * 2;
                top[left] = colour;
                if (left + 1 < w) top[left + 1] = colour;
                if (second) {
                    top[stride + left] = colour;
                    if (left + 1 < w) top[stride + left + 1] = colour;
                }
            }
        }
    }

    /// The rings' tables for an area whose farthest squared distance is
    /// `reach`: the root of every squared distance up to `near_size`, and
    /// how much of a share of `root` a squared distance is.
    fn reachTo(v: *Visual, reach: u64) void {
        v.reach = reach;
        v.share = @intCast((root_size - 1) * 65536 / reach);
        for (&v.near, 0..) |*n, i| {
            const part = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(reach));
            n.* = @intFromFloat(@sqrt(part) * ring_steps);
        }
    }

    /// How many steps of the sine table a point is from the rings'
    /// centre, `square` its squared distance from it in points - below
    /// the area's farthest.
    fn ringDistance(v: *const Visual, square: u32) u32 {
        if (square < near_size) return v.near[square];
        return v.root[square * v.share >> 16];
    }

    /// The palette for this look: the colour wheel - three sines a third
    /// apart - turned by `hue`, never below a sixth in any colour so it
    /// stays soft, at `light` of full brightness. With a tint, the way
    /// from its first colour to its second and back, turned the same, in
    /// two bands of light and shade round the palette.
    fn turnPalette(v: *Visual, light: f32) void {
        const turn: u32 = @intFromFloat(v.hue);
        const scale: u32 = @intFromFloat(light * 256.0);
        if (v.tint) |pair| {
            for (&v.palette, 0..) |*entry, i| {
                const n: u32 = @intCast(i);
                const colour = colours.mix(pair.first, pair.second, v.sine[(n + turn) & 255]);
                entry.* = colours.dim(colour, soft(v.sine[(n * 2 + 64) & 255]) * scale >> 8);
            }
            return;
        }
        for (&v.palette, 0..) |*entry, i| {
            const n: u32 = @intCast(i);
            const r = soft(v.sine[(n + turn) & 255]) * scale >> 8;
            const g = soft(v.sine[(n + turn + 85) & 255]) * scale >> 8;
            const b = soft(v.sine[(n + turn + 171) & 255]) * scale >> 8;
            entry.* = rgb(r, g, b);
        }
    }

    fn wave(v: *Visual, pixels: [*]u32, w: u32, h: u32, stride: u32, samples: []const f32, fresh: bool) void {
        _ = v;
        // What was drawn before, at a quarter, or black.
        for (0..h) |y| {
            const row = pixels[y * stride ..][0..w];
            if (fresh) {
                @memset(row, rgb(0, 0, 0));
            } else {
                for (row) |*p| p.* = (p.* >> 2) & 0x003F3F3F | 0xFF000000;
            }
        }
        const middle = h / 2;
        const axis = pixels[middle * stride ..][0..w];
        for (axis) |*p| p.* |= rgb(0, 40, 30);

        // Where to start: the first rise through zero, in the first half,
        // after the sound was below a tenth of its loudest - so a rise
        // that is only noise round zero does not count.
        const span = samples.len / 2;
        var loudest: f32 = 0;
        for (samples[0..span]) |s| loudest = @max(loudest, @abs(s));
        const below = -0.1 * loudest;
        var start: usize = 0;
        var armed = false;
        for (samples[0..span], 0..) |s, i| {
            if (s < below) armed = true;
            if (armed and s >= 0) {
                start = i;
                break;
            }
        }
        const reach: f32 = @floatFromInt(h / 2 - 1);
        const step = @as(f32, @floatFromInt(span - 1)) / @as(f32, @floatFromInt(w));
        var previous: u32 = middle;
        for (0..w) |x| {
            // The point between two samples, read between them.
            const at = @as(f32, @floatFromInt(x)) * step;
            const whole: usize = @intFromFloat(at);
            const part = at - @as(f32, @floatFromInt(whole));
            const sample = samples[start + whole] * (1.0 - part) + samples[start + whole + 1] * part;
            const level = @min(@max(sample, -1.0), 1.0);
            const y: u32 = @intFromFloat(@as(f32, @floatFromInt(middle)) - level * reach);
            // A line from the last point down or up to this one.
            const from = @min(previous, y);
            const to = @max(previous, y);
            var row = from;
            while (row <= to) : (row += 1) pixels[row * stride + x] = rgb(110, 255, 200);
            previous = y;
        }
    }

    fn bars(v: *Visual, pixels: [*]u32, w: u32, h: u32, stride: u32, bands: usize) void {
        const segment = 4;
        const gap = 1;
        for (0..h) |y| @memset(pixels[y * stride ..][0..w], rgb(8, 8, 16));
        const room = h - 2;
        for (0..bands) |b| {
            const left: u32 = @intCast(b * w / bands);
            const right: u32 = @intCast((b + 1) * w / bands - gap);
            if (right <= left) continue;
            const lit: u32 = @intFromFloat(v.spectrum.levels[b] * @as(f32, @floatFromInt(room)));
            const peak: u32 = @intFromFloat(v.spectrum.peaks[b] * @as(f32, @floatFromInt(room)));
            // Each segment lit up to the level, coloured by its height.
            var up: u32 = 0;
            while (up < lit) : (up += 1) {
                if (up % segment == segment - 1) continue;
                const row = pixels + (h - 1 - up) * stride;
                const height = up * 255 / room;
                const colour = if (v.tint) |pair| colours.mix(pair.first, pair.second, height) else heat(height);
                @memset(row[left..right], colour);
            }
            if (peak > 1 and peak < room) {
                const row = pixels + (h - 1 - peak) * stride;
                @memset(row[left..right], rgb(240, 240, 255));
            }
        }
    }
};

/// A palette colour no darker than a sixth: `level` 0 to 255.
fn soft(level: u8) u32 {
    return 40 + @as(u32, level) * 215 / 255;
}

/// Green at the foot, yellow half way, red at the top: `height` 0 to 255.
fn heat(height: u32) u32 {
    if (height < 128) return rgb(height * 2, 220, 40);
    return rgb(255, 220 - (height - 128) * 220 / 128, 40);
}

pub fn rgb(r: u32, g: u32, b: u32) u32 {
    return 0xFF000000 | (r & 255) << 16 | (g & 255) << 8 | (b & 255);
}

fn wrap(phase: f32) f32 {
    var p = phase;
    while (p >= 256.0) p -= 256.0;
    while (p < 0) p += 256.0;
    return p;
}

// --- tests --------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "every mode draws inside its area and leaves the rest" {
    const v = try testing.allocator.create(Visual);
    defer testing.allocator.destroy(v);
    v.* = .{};
    v.init();
    const stride = 130;
    const w = 121;
    const h = 61;
    var pixels: [stride * (h + 1)]u32 = undefined;
    var samples: [take]f32 = undefined;
    for (&samples, 0..) |*s, i| s.* = 0.8 * @sin(@as(f32, @floatFromInt(i)) * 0.3);
    for (0..mode_count) |_| {
        @memset(&pixels, 0x12345678);
        for (0..3) |_| v.draw(&pixels, w, h, stride, &samples, 44100);
        for (0..h) |y| {
            for (w..stride) |x| try testing.expectEqual(@as(u32, 0x12345678), pixels[y * stride + x]);
        }
        for (pixels[h * stride ..]) |p| try testing.expectEqual(@as(u32, 0x12345678), p);
        // Something was drawn, not one colour.
        var differs = false;
        for (0..h) |y| {
            for (pixels[y * stride ..][0..w]) |p| differs = differs or p != pixels[0];
        }
        try testing.expect(differs);
        v.cycle();
    }
}

test "with a cover's colours the bars go from its first at the foot to its second at the top, a pixel apart" {
    const v = try testing.allocator.create(Visual);
    defer testing.allocator.destroy(v);
    v.* = .{ .mode = .bars, .tint = .{ .first = rgb(255, 0, 0), .second = rgb(0, 0, 255) } };
    v.init();
    const w = 160;
    const h = 64;
    var pixels: [w * h]u32 = undefined;
    // Every band at the top.
    v.spectrum.levels = @splat(1.0);
    v.bars(&pixels, w, h, w, 8);
    const ground = rgb(8, 8, 16);
    // The foot of the first band in the first colour, the top of its lit
    // part in the second, the column after each band the ground.
    try testing.expectEqual(rgb(255, 0, 0), pixels[(h - 1) * w]);
    const top = pixels[(h - 1 - (h - 3)) * w];
    try testing.expect(top >> 16 & 255 < 8 and top & 255 > 240);
    for (1..8) |b| try testing.expectEqual(ground, pixels[(h - 1) * w + b * w / 8 - 1]);
    // Without them, green at the foot again.
    v.tint = null;
    v.bars(&pixels, w, h, w, 8);
    try testing.expectEqual(heat(0), pixels[(h - 1) * w]);
}

test "with a cover's colours the plasma's palette holds only blends of them" {
    const v = try testing.allocator.create(Visual);
    defer testing.allocator.destroy(v);
    v.* = .{ .tint = .{ .first = rgb(255, 0, 0), .second = rgb(0, 0, 255) } };
    v.init();
    v.turnPalette(1.0);
    for (v.palette) |entry| try testing.expect(entry >> 8 & 255 == 0);
}

test "the wave stands still where the sound crosses zero going up" {
    const v = try testing.allocator.create(Visual);
    defer testing.allocator.destroy(v);
    v.* = .{ .mode = .wave };
    v.init();
    const w = 64;
    const h = 33;
    var first: [w * h]u32 = undefined;
    var second: [w * h]u32 = undefined;
    var samples: [take]f32 = undefined;
    // The same note, started at two points of its cycle.
    for (&samples, 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i)) * 0.2);
    v.draw(&first, w, h, w, &samples, 44100);
    for (&samples, 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i + 9)) * 0.2);
    v.width = 0;
    v.draw(&second, w, h, w, &samples, 44100);
    var same: usize = 0;
    for (first, second) |a, b| same += @intFromBool(a == b);
    try testing.expect(same > w * h * 9 / 10);
}

test "a ring's distance is the distance from its centre, close to it too" {
    const v = try testing.allocator.create(Visual);
    defer testing.allocator.destroy(v);
    v.* = .{};
    v.init();
    for ([_][2]u32{ .{ 300, 88 }, .{ 60, 30 }, .{ half_width, half_height } }) |size| {
        const cols, const rows = size;
        const reach = @as(u64, cols) * cols + @as(u64, rows) * rows + 1;
        v.reachTo(reach);
        for (0..rows) |dy| {
            for (0..cols) |dx| {
                const square: u32 = @intCast(dx * dx + dy * dy);
                const exact = @sqrt(@as(f64, @floatFromInt(square)) / @as(f64, @floatFromInt(reach))) * ring_steps;
                const looked_up: f64 = @floatFromInt(v.ringDistance(square));
                try testing.expect(@abs(looked_up - exact) < 2.5);
            }
        }
    }
}

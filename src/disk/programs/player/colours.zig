// SPDX-License-Identifier: MIT
//! The two colours a cover leads with, which the pictures are drawn in
//! (visual.zig), and the blends they are drawn with.
//!
//! The cover is looked at on a grid of points over the square it is shown
//! as. Each point is sorted by its hue into one of `hue_bins` and counted
//! by how much colour it has - its chroma, the difference between its
//! strongest part and its weakest - so a grey, black or white point counts
//! for nothing, and a black ground never leads; nor does a point more
//! clear than not, whose colour is never seen. The first colour is the
//! hue counted most, together with the hues either side of it, so a colour
//! on the border between two bins is not split in half. The second is the
//! hue counted most at least a sixth of the wheel away, or the first made
//! lighter when no other hue has a sixth of its count. Each is the average
//! of the points counted, made as bright as it can be. A cover with almost
//! no colour leads with none, and the pictures keep their own.
//!
//! Nothing here touches the system: the host tests hold it.

/// Two colours, 0xFFRRGGBB.
pub const Pair = struct { first: u32, second: u32 };

const hue_bins = 24;
/// The points looked at each way.
const grid = 48;
/// The least chroma a point counts with: below it, it is grey.
const least_chroma = 40;
/// How far apart the two hues are at least, in bins: a sixth of the wheel.
const apart = hue_bins / 6;

const Bin = struct { weight: u32 = 0, r: u32 = 0, g: u32 = 0, b: u32 = 0 };

/// The leading colours of the `width` by `height` pixels whose top left is
/// at `left`, `top` of `pixels` - 32 bits each, blue first in memory,
/// `pitch` bytes a row; null when they have too little colour to lead
/// with.
pub fn leading(pixels: [*]const u8, pitch: usize, left: u32, top: u32, width: u32, height: u32) ?Pair {
    if (width == 0 or height == 0) return null;
    var bins: [hue_bins]Bin = @splat(.{});
    var total: u32 = 0;
    for (0..grid) |row| {
        // The middle of each of the grid's rows and columns.
        const y = top + @as(u32, @intCast((2 * row + 1) * height / (2 * grid)));
        const line = pixels + @as(usize, y) * pitch;
        for (0..grid) |column| {
            const x = left + @as(u32, @intCast((2 * column + 1) * width / (2 * grid)));
            const point = line + @as(usize, x) * 4;
            if (point[3] < 128) continue;
            const b: u32 = point[0];
            const g: u32 = point[1];
            const r: u32 = point[2];
            const high = @max(r, g, b);
            const chroma = high - @min(r, g, b);
            if (chroma < least_chroma) continue;
            const bin = &bins[hueBin(r, g, b, high, chroma)];
            bin.weight += chroma;
            bin.r += r * chroma;
            bin.g += g * chroma;
            bin.b += b * chroma;
            total += chroma;
        }
    }
    // Too little colour: what there is averages under a 32nd of the most.
    if (total < grid * grid * 255 / 32) return null;

    const first = strongest(&bins, null) orelse return null;
    const first_colour = brightest(averageAround(&bins, first));
    const second = strongest(&bins, first);
    const second_colour = if (second != null and scoreAround(&bins, second.?) * 6 >= scoreAround(&bins, first))
        brightest(averageAround(&bins, second.?))
    else
        mix(first_colour, rgb(255, 255, 255), 128);
    return .{ .first = first_colour, .second = second_colour };
}

/// Which bin a point's hue falls in: the wheel of 360 degrees, red at 0.
fn hueBin(r: u32, g: u32, b: u32, high: u32, chroma: u32) usize {
    const red: i32 = @intCast(r);
    const green: i32 = @intCast(g);
    const blue: i32 = @intCast(b);
    const span: i32 = @intCast(chroma);
    const degrees: i32 = if (high == r)
        @divTrunc(60 * (green - blue), span)
    else if (high == g)
        120 + @divTrunc(60 * (blue - red), span)
    else
        240 + @divTrunc(60 * (red - green), span);
    return @intCast(@divTrunc(@mod(degrees, 360) * hue_bins, 360));
}

/// The bin whose count, with its neighbours', is the highest - at least
/// `apart` bins round the wheel from `away` when that is given. Null when
/// no bin there counts anything.
fn strongest(bins: *const [hue_bins]Bin, away: ?usize) ?usize {
    var best: ?usize = null;
    var best_score: u32 = 0;
    for (0..hue_bins) |at| {
        if (away) |other| {
            const distance = (at + hue_bins - other) % hue_bins;
            if (@min(distance, hue_bins - distance) < apart) continue;
        }
        const score = scoreAround(bins, at);
        if (score > best_score) {
            best = at;
            best_score = score;
        }
    }
    return best;
}

/// A bin's count with its two neighbours'.
fn scoreAround(bins: *const [hue_bins]Bin, at: usize) u32 {
    return bins[(at + hue_bins - 1) % hue_bins].weight + bins[at].weight + bins[(at + 1) % hue_bins].weight;
}

/// The average colour of a bin and its two neighbours.
fn averageAround(bins: *const [hue_bins]Bin, at: usize) u32 {
    var sum: Bin = .{};
    for ([_]usize{ (at + hue_bins - 1) % hue_bins, at, (at + 1) % hue_bins }) |which| {
        sum.weight += bins[which].weight;
        sum.r += bins[which].r;
        sum.g += bins[which].g;
        sum.b += bins[which].b;
    }
    if (sum.weight == 0) return rgb(0, 0, 0);
    return rgb(sum.r / sum.weight, sum.g / sum.weight, sum.b / sum.weight);
}

/// `colour` as bright as it can be: its strongest part at full.
fn brightest(colour: u32) u32 {
    const high = @max(redOf(colour), greenOf(colour), blueOf(colour));
    if (high == 0) return colour;
    return rgb(redOf(colour) * 255 / high, greenOf(colour) * 255 / high, blueOf(colour) * 255 / high);
}

/// `from` blended towards `to` by `amount`, 0 (all `from`) to 255.
pub fn mix(from: u32, to: u32, amount: u32) u32 {
    const keep = 255 - amount;
    return rgb(
        (redOf(from) * keep + redOf(to) * amount) / 255,
        (greenOf(from) * keep + greenOf(to) * amount) / 255,
        (blueOf(from) * keep + blueOf(to) * amount) / 255,
    );
}

/// `colour` at `light` 256ths of its brightness.
pub fn dim(colour: u32, light: u32) u32 {
    return rgb(redOf(colour) * light >> 8, greenOf(colour) * light >> 8, blueOf(colour) * light >> 8);
}

fn redOf(colour: u32) u32 {
    return colour >> 16 & 255;
}

fn greenOf(colour: u32) u32 {
    return colour >> 8 & 255;
}

fn blueOf(colour: u32) u32 {
    return colour & 255;
}

fn rgb(r: u32, g: u32, b: u32) u32 {
    return 0xFF000000 | (r & 255) << 16 | (g & 255) << 8 | (b & 255);
}

// --- tests --------------------------------------------------------------------------

const testing = @import("std").testing;

/// A picture `side` each way, blue first in memory, painted by `paint`.
fn picture(comptime side: usize, comptime paint: fn (x: usize, y: usize) [3]u8) [side * side * 4]u8 {
    var bytes: [side * side * 4]u8 = undefined;
    for (0..side) |y| {
        for (0..side) |x| {
            const r, const g, const b = paint(x, y);
            const at = (y * side + x) * 4;
            bytes[at..][0..4].* = .{ b, g, r, 255 };
        }
    }
    return bytes;
}

fn near(expected: u32, got: u32) bool {
    const parts = [_]u5{ 16, 8, 0 };
    for (parts) |shift| {
        const want: i32 = @intCast(expected >> shift & 255);
        const have: i32 = @intCast(got >> shift & 255);
        if (@abs(want - have) > 24) return false;
    }
    return true;
}

test "a cover's two leading colours: the hue it has most of, then the next one well away from it" {
    // Half red, a quarter blue, the rest black - which leads with nothing.
    const bytes = picture(64, struct {
        fn paint(x: usize, y: usize) [3]u8 {
            if (y < 32) return .{ 200, 20, 20 };
            if (x < 32) return .{ 20, 20, 160 };
            return .{ 0, 0, 0 };
        }
    }.paint);
    const pair = leading(&bytes, 64 * 4, 0, 0, 64, 64).?;
    try testing.expect(near(rgb(255, 25, 25), pair.first));
    try testing.expect(near(rgb(32, 32, 255), pair.second));
}

test "a cover of one hue leads with it, and with it lighter" {
    const bytes = picture(32, struct {
        fn paint(x: usize, y: usize) [3]u8 {
            _ = x;
            _ = y;
            return .{ 30, 140, 40 };
        }
    }.paint);
    const pair = leading(&bytes, 32 * 4, 0, 0, 32, 32).?;
    try testing.expect(near(rgb(54, 255, 72), pair.first));
    try testing.expect(near(mix(pair.first, rgb(255, 255, 255), 128), pair.second));
}

test "grey, black and white lead with nothing; only the area asked for counts" {
    const bytes = picture(64, struct {
        fn paint(x: usize, y: usize) [3]u8 {
            // Colour only in the right half, the left in shades of grey.
            if (x >= 32) return .{ 250, 200, 0 };
            const level: u8 = @intCast((x + y) * 2);
            return .{ level, level, level };
        }
    }.paint);
    try testing.expectEqual(@as(?Pair, null), leading(&bytes, 64 * 4, 0, 0, 32, 64));
    const right = leading(&bytes, 64 * 4, 32, 0, 32, 64).?;
    try testing.expect(near(rgb(255, 204, 0), right.first));
}

test "a clear point counts for nothing, whatever its colour" {
    // Red, under a blue that is all but clear.
    var bytes = picture(32, struct {
        fn paint(x: usize, y: usize) [3]u8 {
            _ = y;
            return if (x < 12) .{ 220, 30, 30 } else .{ 30, 30, 220 };
        }
    }.paint);
    var at: usize = 3;
    while (at < bytes.len) : (at += 4) {
        if (bytes[at - 1] < 100) bytes[at] = 20;
    }
    const pair = leading(&bytes, 32 * 4, 0, 0, 32, 32).?;
    try testing.expect(near(rgb(255, 35, 35), pair.first));
    try testing.expect(near(mix(pair.first, rgb(255, 255, 255), 128), pair.second));
}

test "a hue on the border between two bins is not split" {
    // Two shades either side of 15 degrees, the border of the first bin,
    // against a little more of a blue: together they lead.
    const bytes = picture(48, struct {
        fn paint(x: usize, y: usize) [3]u8 {
            _ = y;
            if (x < 14) return .{ 255, 60, 0 };
            if (x < 28) return .{ 255, 70, 0 };
            return .{ 0, 0, 255 };
        }
    }.paint);
    const pair = leading(&bytes, 48 * 4, 0, 0, 48, 48).?;
    try testing.expect(near(rgb(255, 65, 0), pair.first));
    try testing.expect(near(rgb(0, 0, 255), pair.second));
}

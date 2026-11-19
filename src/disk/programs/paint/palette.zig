// SPDX-License-Identifier: MIT
//! Paint's palette: the 32 colours offered beside the picture, and what
//! is done with them.
//!
//! A colour is a pixel, `0xAARRGGBB`, and the palette's are opaque. The
//! editor shows one as hue, saturation and value too (`toHsv`,
//! `fromHsv`) and as the hex text it is written in (`hexText`,
//! `parseHex`); a run between two is spread evenly (`spread`); and the
//! pixels of colours that changed are made the new ones (`recolour`).
//!
//! **From a picture** (`mostUsed`) come the colours it uses most: all of
//! them when it has no more than the palette holds, otherwise the colours
//! are counted in 32 steps of red, green and blue each, and the box of
//! all of them is cut in two again and again - the box with the most
//! pixels times its longest side, across that side where half its pixels
//! lie on either side - until there are as many boxes as colours wanted.
//! Each box gives the mean of its colours. The colours come out darkest
//! first.
//!
//! **A palette file** is text, a colour a line, six hex digits `RRGGBB`
//! (`toText`, `fromText`); a `#` before them, and whatever follows on the
//! line, is passed over.

const picture_zig = @import("picture.zig");
const Pixel = picture_zig.Pixel;

/// The colours a palette has.
pub const size = 32;
pub const Palette = [size]Pixel;

/// The colours Paint offers to begin with: black, white and greys, a ring
/// of hues, the same darker, and earth and skin.
pub const standard = Palette{
    0xFF000000, 0xFFFFFFFF, 0xFF404040, 0xFF808080, 0xFFC0C0C0, 0xFFE02828, 0xFFF08A1E, 0xFFF5D820,
    0xFF8CD02A, 0xFF22A447, 0xFF1FB3A3, 0xFF2AB4F0, 0xFF2858D8, 0xFF5A35C8, 0xFF9A35C8, 0xFFE03AA0,
    0xFF202020, 0xFF606060, 0xFFA0A0A0, 0xFFE0E0E0, 0xFF801818, 0xFF8A4A10, 0xFF8A7A10, 0xFF4A7A18,
    0xFF145A28, 0xFF106A60, 0xFF186A90, 0xFF183480, 0xFF341E78, 0xFF581E78, 0xFF801E5A, 0xFF5A3A22,
};

/// Black to white in 32 even steps.
pub const greys = blk: {
    var made: Palette = undefined;
    for (&made, 0..) |*colour, place| {
        const level: Pixel = place * 255 / (size - 1);
        colour.* = 0xFF00_0000 | level * 0x01_01_01;
    }
    break :blk made;
};

/// Eight greys, then 24 hues at their brightest, a 15 degrees apart.
pub const spectrum = ring(.{ 0, 255 }, 100, 100);

/// Eight light greys, then 24 hues, pale.
pub const pastel = ring(.{ 160, 255 }, 35, 100);

/// Soil, rust and ochre, moss and sage, slate, sky and stone.
pub const earth = Palette{
    0xFF1B1410, 0xFF3B2A1E, 0xFF5C4030, 0xFF7E5A3C, 0xFFA07848, 0xFFC49A60, 0xFFE0C08A, 0xFFF4E4C0,
    0xFF5A2A18, 0xFF8A3E20, 0xFFB45A2C, 0xFFD2803C, 0xFFC8A040, 0xFFA88830, 0xFF7A6420, 0xFF4E4018,
    0xFF1E2A14, 0xFF2E4220, 0xFF46602C, 0xFF64803A, 0xFF88A050, 0xFFB0C078, 0xFF6E7660, 0xFF4A5040,
    0xFF202830, 0xFF384858, 0xFF56708A, 0xFF7898B4, 0xFFA8C0D4, 0xFF8C8C84, 0xFFB4B0A4, 0xFFDCD8CC,
};

/// Eight greys from `levels[0]` to `levels[1]`, then 24 hues at that
/// saturation and value.
fn ring(comptime levels: [2]u32, comptime saturation: u32, comptime value: u32) Palette {
    @setEvalBranchQuota(20000);
    var made: Palette = undefined;
    for (made[0..8], 0..) |*colour, place| {
        const level: Pixel = levels[0] + place * (levels[1] - levels[0]) / 7;
        colour.* = 0xFF00_0000 | level * 0x01_01_01;
    }
    for (made[8..], 0..) |*colour, place| colour.* = fromHsv(.{ .hue = @intCast(place * 15), .saturation = saturation, .value = value });
    return made;
}

/// A colour as hue (0 to 359 degrees), saturation and value (0 to 100).
pub const Hsv = struct {
    hue: u32 = 0,
    saturation: u32 = 0,
    value: u32 = 0,
};

pub fn toHsv(colour: Pixel) Hsv {
    const red: i32 = @intCast((colour >> 16) & 0xFF);
    const green: i32 = @intCast((colour >> 8) & 0xFF);
    const blue: i32 = @intCast(colour & 0xFF);
    const most = @max(red, green, blue);
    const least = @min(red, green, blue);
    const range = most - least;
    var made = Hsv{ .value = @intCast(@divTrunc(most * 100 + 127, 255)) };
    if (most == 0 or range == 0) return made;
    made.saturation = @intCast(@divTrunc(range * 100 + @divTrunc(most, 2), most));
    // Sixty degrees for each step of the range, rounded.
    const degrees = if (most == red)
        @divFloor((green - blue) * 120 + range, range * 2)
    else if (most == green)
        @divFloor((blue - red) * 120 + range, range * 2) + 120
    else
        @divFloor((red - green) * 120 + range, range * 2) + 240;
    made.hue = @intCast(@mod(degrees, 360));
    return made;
}

/// An opaque colour from hue, saturation and value.
pub fn fromHsv(hsv: Hsv) Pixel {
    // @min would narrow the type: both are held to 100 as u32s.
    const value_level: u32 = @min(hsv.value, 100);
    const saturation: u32 = @min(hsv.saturation, 100);
    const value = (value_level * 255 + 50) / 100;
    const hue = hsv.hue % 360;
    const within = hue % 60;
    const low = (value * (100 - saturation) + 50) / 100;
    const falling = (value * (6000 - saturation * within) + 3000) / 6000;
    const rising = (value * (6000 - saturation * (60 - within)) + 3000) / 6000;
    const channels: [3]u32 = switch (hue / 60) {
        0 => .{ value, rising, low },
        1 => .{ falling, value, low },
        2 => .{ low, value, rising },
        3 => .{ low, falling, value },
        4 => .{ rising, low, value },
        else => .{ value, low, falling },
    };
    return 0xFF00_0000 | channels[0] << 16 | channels[1] << 8 | channels[2];
}

const digits = "0123456789ABCDEF";

/// `#RRGGBB` and a NUL, in `into`; the text without the NUL.
pub fn hexText(colour: Pixel, into: *[8]u8) []const u8 {
    into[0] = '#';
    for (into[1..7], 0..) |*digit, place| digit.* = digits[(colour >> @intCast(20 - place * 4)) & 0xF];
    into[7] = 0;
    return into[0..7];
}

/// The opaque colour six hex digits name, with or without a `#` before
/// them and spaces around; null for anything else.
pub fn parseHex(text: []const u8) ?Pixel {
    var start: usize = 0;
    var end = text.len;
    while (start < end and isSpace(text[start])) start += 1;
    while (end > start and isSpace(text[end - 1])) end -= 1;
    if (start < end and text[start] == '#') start += 1;
    if (end - start != 6) return null;
    var colour: Pixel = 0;
    for (text[start..end]) |char| colour = colour << 4 | (digitOf(char) orelse return null);
    return 0xFF00_0000 | colour;
}

fn isSpace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\r' or char == '\n';
}

fn digitOf(char: u8) ?Pixel {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// The colours between places `first` and `last` (either way round) made
/// an even run from the one to the other.
pub fn spread(palette: []Pixel, first: usize, last: usize) void {
    const low = @min(first, last);
    const high = @max(first, last);
    if (high - low < 2) return;
    const steps: u32 = @intCast(high - low);
    for (palette[low + 1 .. high], 1..) |*colour, step| {
        var made: Pixel = 0xFF00_0000;
        for ([_]u5{ 16, 8, 0 }) |shift| {
            const from: u32 = (palette[low] >> shift) & 0xFF;
            const to: u32 = (palette[high] >> shift) & 0xFF;
            const at: u32 = @intCast(step);
            const mixed = (from * (steps - at) + to * at + steps / 2) / steps;
            made |= mixed << shift;
        }
        colour.* = made;
    }
}

/// The pixels of `row` whose colour is one of `old`'s made the colour at
/// the same place in `new`, each keeping its alpha; see-through pixels
/// are left. The first and one past the last pixel changed, or null.
pub fn recolour(row: []Pixel, old: []const Pixel, new: []const Pixel) ?[2]usize {
    var changed: ?[2]usize = null;
    for (row, 0..) |*pixel, at| {
        const place = placeIn(pixel.*, old) orelse continue;
        pixel.* = (pixel.* & 0xFF00_0000) | (new[place] & 0x00FF_FFFF);
        changed = if (changed) |range| .{ range[0], at + 1 } else .{ at, at + 1 };
    }
    return changed;
}

/// The first and one past the last pixel of `row` whose colour is one of
/// `old`'s, see-through ones left out; null for none.
pub fn find(row: []const Pixel, old: []const Pixel) ?[2]usize {
    var found: ?[2]usize = null;
    for (row, 0..) |pixel, at| {
        if (placeIn(pixel, old) == null) continue;
        found = if (found) |range| .{ range[0], at + 1 } else .{ at, at + 1 };
    }
    return found;
}

/// Where in `colours` a pixel's colour is, unless it is see-through.
fn placeIn(pixel: Pixel, colours: []const Pixel) ?usize {
    if (pixel >> 24 == 0) return null;
    for (colours, 0..) |colour, place| {
        if ((colour ^ pixel) & 0x00FF_FFFF == 0) return place;
    }
    return null;
}

/// Whether `bytes` are text: no control characters but tabs and line
/// ends.
pub fn isText(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte < 0x20 and byte != '\t' and byte != '\r' and byte != '\n') return false;
    }
    return true;
}

/// What `mostUsed` counts the colours in: 32 steps of each of red, green
/// and blue.
pub const bins = 1 << 15;

/// The colours the pixels at least half covered use most, as many as
/// `into` holds (no more than `size`) or as there are; `counts` is
/// memory of `bins` the caller gives. The colours, darkest first, are put
/// in `into`; how many.
pub fn mostUsed(pixels: []const Pixel, counts: []u32, into: []Pixel) usize {
    // Few enough colours are taken as they are.
    var seen: [size + 1]Pixel = undefined;
    var found: usize = 0;
    for (pixels) |pixel| {
        if (pixel >> 24 < 128) continue;
        const colour = pixel | 0xFF00_0000;
        for (seen[0..found]) |known| {
            if (known == colour) break;
        } else {
            if (found > into.len) break;
            seen[found] = colour;
            found += 1;
        }
    }
    if (found <= into.len) {
        @memcpy(into[0..found], seen[0..found]);
        byBrightness(into[0..found]);
        return found;
    }

    @memset(counts[0..bins], 0);
    for (pixels) |pixel| {
        if (pixel >> 24 >= 128) counts[binOf(pixel)] += 1;
    }
    var boxes: [size]Box = undefined;
    boxes[0] = .{ .low = .{ 0, 0, 0 }, .high = .{ 31, 31, 31 }, .count = 0 };
    boxes[0].shrink(counts);
    var made: usize = 1;
    while (made < into.len) {
        // The box with the most pixels times its longest side.
        var best: ?usize = null;
        var best_weight: u64 = 0;
        for (boxes[0..made], 0..) |box, place| {
            const weight = @as(u64, box.count) * box.longest()[1];
            if (weight > best_weight) {
                best_weight = weight;
                best = place;
            }
        }
        const cut = best orelse break;
        boxes[made] = boxes[cut].split(counts);
        made += 1;
    }
    for (boxes[0..made], into[0..made]) |box, *colour| colour.* = box.mean(counts);
    byBrightness(into[0..made]);
    return made;
}

/// A colour's bin: its top five bits of red, green and blue.
fn binOf(pixel: Pixel) usize {
    return ((pixel >> 9) & 0x7C00) | ((pixel >> 6) & 0x03E0) | ((pixel >> 3) & 0x001F);
}

/// A box of bins, from `low` to `high` in red, green and blue, holding
/// `count` pixels.
const Box = struct {
    low: [3]u8,
    high: [3]u8,
    count: u32,

    /// The channel along which it is longest, and how long.
    fn longest(box: Box) [2]u32 {
        var axis: u32 = 0;
        var length: u32 = 0;
        for (0..3) |channel| {
            const side: u32 = box.high[channel] - box.low[channel];
            if (side > length) {
                length = side;
                axis = @intCast(channel);
            }
        }
        return .{ axis, length };
    }

    /// Made as small as the bins with pixels in it, and those counted.
    fn shrink(box: *Box, counts: []const u32) void {
        var low = [3]u8{ 31, 31, 31 };
        var high = [3]u8{ 0, 0, 0 };
        var count: u32 = 0;
        var red = box.low[0];
        while (red <= box.high[0]) : (red += 1) {
            var green = box.low[1];
            while (green <= box.high[1]) : (green += 1) {
                var blue = box.low[2];
                while (blue <= box.high[2]) : (blue += 1) {
                    const there = counts[@as(usize, red) << 10 | @as(usize, green) << 5 | blue];
                    if (there == 0) continue;
                    count += there;
                    for ([3]u8{ red, green, blue }, &low, &high) |at, *least, *most| {
                        least.* = @min(least.*, at);
                        most.* = @max(most.*, at);
                    }
                }
            }
        }
        box.* = .{ .low = low, .high = high, .count = count };
    }

    /// Cut in two across its longest side where half its pixels lie on
    /// either side: it keeps the lower part, the upper part is returned.
    /// It is longer than one bin along that side.
    fn split(box: *Box, counts: []const u32) Box {
        const axis = box.longest()[0];
        var along: [32]u32 = @splat(0);
        var red = box.low[0];
        while (red <= box.high[0]) : (red += 1) {
            var green = box.low[1];
            while (green <= box.high[1]) : (green += 1) {
                var blue = box.low[2];
                while (blue <= box.high[2]) : (blue += 1) {
                    const at = [3]u8{ red, green, blue };
                    along[at[axis]] += counts[@as(usize, red) << 10 | @as(usize, green) << 5 | blue];
                }
            }
        }
        var cut = box.low[axis];
        var below: u32 = 0;
        while (cut < box.high[axis]) : (cut += 1) {
            below += along[cut];
            if (below * 2 >= box.count) break;
        }
        if (cut >= box.high[axis]) cut = box.high[axis] - 1;
        var upper = box.*;
        upper.low[axis] = cut + 1;
        box.high[axis] = cut;
        box.shrink(counts);
        upper.shrink(counts);
        return upper;
    }

    /// The mean of its pixels' colours, each bin taken at its middle.
    fn mean(box: Box, counts: []const u32) Pixel {
        var sums = [3]u64{ 0, 0, 0 };
        var red = box.low[0];
        while (red <= box.high[0]) : (red += 1) {
            var green = box.low[1];
            while (green <= box.high[1]) : (green += 1) {
                var blue = box.low[2];
                while (blue <= box.high[2]) : (blue += 1) {
                    const there: u64 = counts[@as(usize, red) << 10 | @as(usize, green) << 5 | blue];
                    for ([3]u8{ red, green, blue }, &sums) |at, *sum| sum.* += there * (@as(u64, at) * 8 + 4);
                }
            }
        }
        var colour: Pixel = 0xFF00_0000;
        for (sums, [_]u5{ 16, 8, 0 }) |sum, shift| {
            const channel: Pixel = @intCast(@min(255, (sum + box.count / 2) / @max(box.count, 1)));
            colour |= channel << shift;
        }
        return colour;
    }
};

/// The colours put in order of brightness, darkest first.
fn byBrightness(colours: []Pixel) void {
    var at: usize = 1;
    while (at < colours.len) : (at += 1) {
        const moving = colours[at];
        var place = at;
        while (place > 0 and brightness(colours[place - 1]) > brightness(moving)) : (place -= 1) colours[place] = colours[place - 1];
        colours[place] = moving;
    }
}

fn brightness(colour: Pixel) u32 {
    return 30 * ((colour >> 16) & 0xFF) + 59 * ((colour >> 8) & 0xFF) + 11 * (colour & 0xFF);
}

/// The palette as text, a colour a line, into `into` (seven bytes a
/// colour); how many bytes.
pub fn toText(palette: []const Pixel, into: []u8) usize {
    var length: usize = 0;
    for (palette) |colour| {
        var hex: [8]u8 = undefined;
        @memcpy(into[length..][0..6], hexText(colour, &hex)[1..7]);
        into[length + 6] = '\n';
        length += 7;
    }
    return length;
}

/// The colours of a palette's text, a line each, put in `into`; lines
/// that name none are passed over. How many.
pub fn fromText(text: []const u8, into: []Pixel) usize {
    var found: usize = 0;
    var start: usize = 0;
    while (start < text.len and found < into.len) {
        var end = start;
        while (end < text.len and text[end] != '\n') end += 1;
        var line = text[start..end];
        while (line.len > 0 and isSpace(line[0])) line = line[1..];
        if (line.len > 0 and line[0] == '#') line = line[1..];
        if (line.len >= 6 and (line.len == 6 or !isHex(line[6]))) {
            if (parseHex(line[0..6])) |colour| {
                into[found] = colour;
                found += 1;
            }
        }
        start = end + 1;
    }
    return found;
}

fn isHex(char: u8) bool {
    return digitOf(char) != null;
}

// SPDX-License-Identifier: MPL-2.0
//! A band whose buffer is not the picture's width, scaled as it is
//! composed (`_compose.zig` `lines`).
//!
//! The ratio of the two widths scales the band both ways the same: a
//! buffer half as wide as the picture shows each of its pixels twice
//! across and each of its rows on two lines. Display column `x` of the
//! picture shows the buffer's column `x * buffer width / picture width`,
//! and line `y` of the band - counted from the band's origin - its row
//! `y * buffer width / picture width`; a line whose row the buffer has
//! not got is black.
//!
//! Where the picture's width is a whole number of buffer widths, each
//! pixel is repeated and none is mixed. Otherwise a pixel of the picture
//! is taken where its middle lies in the buffer and mixed of the four
//! pixels around that place, by how near each is: a buffer one and a half
//! times the picture's width loses no line of one pixel, it greys it.
//! What is mixed is the colour's channels, each on its own, so how it is
//! done hangs on the format; a format whose bytes are no channels - a
//! pen's number - takes the nearest pixel and mixes nothing.
//!
//! A place in the buffer is counted in 65536ths of a pixel, which holds a
//! buffer of 65535 pixels a side in a 32-bit count.

const rtg = @import("sdk").rtg;

/// How the pixels of a format are mixed.
const Mixing = enum {
    /// Every byte of a pixel is a channel.
    bytes,
    /// Five, six and five bits in sixteen.
    rgb565,
    /// One bit of alpha, taken from the nearest pixel, and three times
    /// five bits.
    argb1555,
    /// Not mixed: the nearest pixel.
    none,
};

fn mixingOf(format: rtg.PixelFormat) Mixing {
    return switch (format) {
        .rgba32, .bgra32, .rgb24, .bgr24, .gray8 => .bytes,
        .rgb565 => .rgb565,
        .argb1555 => .argb1555,
        else => .none,
    };
}

/// The scale of one band: a buffer's width over the picture's.
pub const Scale = struct {
    /// The buffer's width and the picture's.
    from: u32,
    to: u32,

    /// Whether each pixel of the buffer is shown a whole number of times:
    /// nothing is mixed then.
    fn whole(scale: Scale) bool {
        return scale.to % scale.from == 0;
    }

    /// Where display column or line `at` lies in the buffer, in 65536ths
    /// of a pixel: the middle of that pixel, half a buffer pixel back, so
    /// that the two pixels it lies between are the whole part and the
    /// one after it. Never before the first pixel.
    fn place(scale: Scale, at: u32) u64 {
        const middle = (@as(u64, at) * 2 + 1) * scale.from * 32768 / scale.to;
        return middle -| 32768;
    }

    /// The buffer's column or row display column or line `at` shows where
    /// nothing is mixed.
    fn nearest(scale: Scale, at: u32) u32 {
        return @intCast(@as(u64, at) * scale.from / scale.to);
    }

    /// The first display column or line that shows something of the
    /// buffer's column or row `at`, and one past the last that shows
    /// something of the one before `end`: what of the picture changes
    /// when columns or rows `at` up to `end` of the buffer are written. A
    /// pixel more each side where pixels are mixed, since each is mixed
    /// into its neighbours' places.
    pub fn span(scale: Scale, at: u32, end: u32) struct { first: u32, end: u32 } {
        const margin: u64 = if (scale.whole()) 0 else 1;
        const first = (@as(u64, at) -| margin) * scale.to / scale.from;
        const last = ((@as(u64, end) + margin) * scale.to + scale.from - 1) / scale.from;
        return .{ .first = @intCast(@min(first, 0xFFFF_FFFF)), .end = @intCast(@min(last, 0xFFFF_FFFF)) };
    }
};

/// One pixel of two bytes, as the machine holds it.
fn load16(at: [*]const u8) u32 {
    return @as(u32, at[0]) | @as(u32, at[1]) << 8;
}

fn store16(at: [*]u8, value: u32) void {
    at[0] = @truncate(value);
    at[1] = @truncate(value >> 8);
}

/// Two channels mixed: `far` 256ths of `b` and the rest of `a`.
fn between(a: u32, b: u32, far: u32) u32 {
    return (a * (256 - far) + b * far + 128) >> 8;
}

/// Two pixels of five, six and five bits mixed, 32nds of `b`: the three
/// channels spread over one word, each with room above it, and mixed in
/// one multiplication.
fn between565(a: u32, b: u32, far: u32) u32 {
    const mask: u32 = 0x07E0_F81F;
    const one = (a | a << 16) & mask;
    const other = (b | b << 16) & mask;
    const mixed = ((one * (32 - far) + other * far) >> 5) & mask;
    return (mixed | mixed >> 16) & 0xFFFF;
}

/// The same for three times five bits; the alpha bit is `a`'s.
fn between1555(a: u32, b: u32, far: u32) u32 {
    const mask: u32 = 0x03E0_7C1F;
    const one = (a & 0x7C1F) | (a & 0x03E0) << 16;
    const other = (b & 0x7C1F) | (b & 0x03E0) << 16;
    const mixed = ((one * (32 - far) + other * far) >> 5) & mask;
    return (a & 0x8000) | (mixed & 0x7C1F) | (mixed >> 16 & 0x03E0);
}

/// The pixels of one line of a scaled band.
///
/// INPUTS:
/// - `bitmap` - the band's buffer, with pixels, not the picture's width.
/// - `width` - the picture's width.
/// - `bytes` - bytes a pixel takes, in the buffer and in the picture.
/// - `line` - the line of the band, from the display line its buffer's
///   first row is at; 0 for a band that repeats that row.
/// - `left` - the first display column wanted.
/// - `count` - how many columns.
/// - `out` - where the pixels go, `count` of them.
pub fn row(bitmap: *const rtg.RtgBitMap, width: u32, bytes: u32, line: u32, left: u32, count: u32, out: [*]u8) void {
    const scale = Scale{ .from = bitmap.width, .to = width };
    const pixels = bitmap.pixels.?;
    const mixing: Mixing = if (scale.whole()) .none else mixingOf(bitmap.format);
    const last_column = bitmap.width - 1;

    if (mixing == .none) {
        // The nearest row, and of it the nearest pixel of each column.
        const source_row = if (scale.whole()) scale.nearest(line) else @as(u32, @intCast((scale.place(line) + 32768) >> 16));
        if (source_row >= bitmap.height) return @memset(out[0 .. @as(usize, count) * bytes], 0);
        const from = pixels + @as(usize, source_row) * bitmap.pitch;
        var column: u32 = 0;
        while (column < count) : (column += 1) {
            const x = left + column;
            const source = if (scale.whole()) scale.nearest(x) else @min(@as(u32, @intCast((scale.place(x) + 32768) >> 16)), last_column);
            const pixel = from + @as(usize, source) * bytes;
            const to = out + @as(usize, column) * bytes;
            var i: u32 = 0;
            while (i < bytes) : (i += 1) to[i] = pixel[i];
        }
        return;
    }

    // The two rows the line lies between, and how far down from the
    // first; past the buffer's last row there is black.
    const down = scale.place(line);
    const upper: u32 = @intCast(down >> 16);
    if (upper >= bitmap.height) return @memset(out[0 .. @as(usize, count) * bytes], 0);
    const lower = @min(upper + 1, bitmap.height - 1);
    const far_down: u32 = @intCast((down & 0xFFFF) >> 8);
    const above = pixels + @as(usize, upper) * bitmap.pitch;
    const below = pixels + @as(usize, lower) * bitmap.pitch;

    var column: u32 = 0;
    while (column < count) : (column += 1) {
        const across = scale.place(left + column);
        const near: u32 = @min(@as(u32, @intCast(across >> 16)), last_column);
        const next = @min(near + 1, last_column);
        const far_across: u32 = @intCast((across & 0xFFFF) >> 8);
        const a = above + @as(usize, near) * bytes;
        const b = above + @as(usize, next) * bytes;
        const c = below + @as(usize, near) * bytes;
        const d = below + @as(usize, next) * bytes;
        const to = out + @as(usize, column) * bytes;
        switch (mixing) {
            .bytes => {
                var i: u32 = 0;
                while (i < bytes) : (i += 1) {
                    to[i] = @intCast(between(between(a[i], b[i], far_across), between(c[i], d[i], far_across), far_down));
                }
            },
            .rgb565 => store16(to, between565(
                between565(load16(a), load16(b), far_across >> 3),
                between565(load16(c), load16(d), far_across >> 3),
                far_down >> 3,
            )),
            .argb1555 => store16(to, between1555(
                between1555(load16(a), load16(b), far_across >> 3),
                between1555(load16(c), load16(d), far_across >> 3),
                far_down >> 3,
            )),
            .none => unreachable,
        }
    }
}

const std = @import("std");
const testing = std.testing;

test "a buffer half the picture's width: every pixel twice across and on two lines, none mixed" {
    var source = [_]u16{ 0xF800, 0x07E0, 0x001F, 0xFFFF };
    const bitmap = rtg.RtgBitMap{ .pixels = @ptrCast(&source), .width = 2, .height = 2, .pitch = 4, .format = .rgb565 };
    var out: [4]u16 = undefined;
    row(&bitmap, 4, 2, 0, 0, 4, @ptrCast(&out));
    try testing.expectEqual([4]u16{ 0xF800, 0xF800, 0x07E0, 0x07E0 }, out);
    row(&bitmap, 4, 2, 1, 0, 4, @ptrCast(&out));
    try testing.expectEqual([4]u16{ 0xF800, 0xF800, 0x07E0, 0x07E0 }, out);
    row(&bitmap, 4, 2, 3, 1, 2, @ptrCast(&out));
    try testing.expectEqual([2]u16{ 0x001F, 0xFFFF }, out[0..2].*);
    // The buffer has two rows: the band's fifth line shows none.
    row(&bitmap, 4, 2, 4, 0, 4, @ptrCast(&out));
    try testing.expectEqual([4]u16{ 0, 0, 0, 0 }, out);
}

test "a buffer one and a half times the picture's width: neighbours mixed, a flat colour kept" {
    // Three pixels into two: each of the picture's lies half way between
    // two of the buffer's.
    var flat = [_]u16{ 0x8410, 0x8410, 0x8410, 0x8410, 0x8410, 0x8410 };
    const even = rtg.RtgBitMap{ .pixels = @ptrCast(&flat), .width = 3, .height = 2, .pitch = 6, .format = .rgb565 };
    var out: [2]u16 = undefined;
    row(&even, 2, 2, 0, 0, 2, @ptrCast(&out));
    try testing.expectEqual([2]u16{ 0x8410, 0x8410 }, out);

    // Black, white, black across: each of the picture's two pixels lies
    // a quarter of the way from a black pixel to the white one, and is a
    // quarter white.
    var striped = [_]u16{ 0x0000, 0xFFFF, 0x0000, 0x0000, 0xFFFF, 0x0000 };
    const stripes = rtg.RtgBitMap{ .pixels = @ptrCast(&striped), .width = 3, .height = 2, .pitch = 6, .format = .rgb565 };
    row(&stripes, 2, 2, 0, 0, 2, @ptrCast(&out));
    try testing.expectEqual(out[0], out[1]);
    const grey = out[0];
    try testing.expect((grey >> 11) >= 6 and (grey >> 11) <= 9);
    try testing.expect((grey >> 5 & 0x3F) >= 14 and (grey >> 5 & 0x3F) <= 17);
    try testing.expect((grey & 0x1F) >= 6 and (grey & 0x1F) <= 9);
}

test "four bytes a pixel are mixed a byte at a time; a pen's number is not mixed" {
    var two = [_]u8{ 0, 0, 0, 0, 200, 100, 50, 255, 0, 0, 0, 0 };
    const colours = rtg.RtgBitMap{ .pixels = &two, .width = 3, .height = 1, .pitch = 12, .format = .bgra32 };
    var out: [8]u8 = undefined;
    row(&colours, 2, 4, 0, 0, 2, &out);
    // A quarter of the middle pixel in each.
    try testing.expect(out[0] >= 48 and out[0] <= 52);
    try testing.expect(out[1] >= 23 and out[1] <= 27);
    try testing.expect(out[3] >= 62 and out[3] <= 66);
    try testing.expectEqualSlices(u8, out[0..4], out[4..8]);

    var pens = [_]u8{ 1, 9, 5 };
    const indexed = rtg.RtgBitMap{ .pixels = &pens, .width = 3, .height = 1, .pitch = 3, .format = .indexed8 };
    var pen_out: [2]u8 = undefined;
    row(&indexed, 2, 1, 0, 0, 2, &pen_out);
    for (pen_out) |pen| try testing.expect(pen == 1 or pen == 9 or pen == 5);
}

test "what of the picture a stretch of the buffer shows" {
    // Twice as wide: columns 3 and 4 of the buffer are 6 up to 10.
    const twice = Scale{ .from = 8, .to = 16 };
    try testing.expectEqual(@as(u32, 6), twice.span(3, 5).first);
    try testing.expectEqual(@as(u32, 10), twice.span(3, 5).end);
    // Two thirds: a pixel more each side, for what is mixed.
    const smaller = Scale{ .from = 24, .to = 16 };
    const stretch = smaller.span(6, 9);
    try testing.expect(stretch.first <= 3 and stretch.end >= 7);
    try testing.expectEqual(@as(u32, 0), smaller.span(0, 1).first);
}

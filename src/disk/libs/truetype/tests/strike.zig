// SPDX-License-Identifier: MIT
//! Host tests of truetype.library's fonts of pictures, on tables built
//! here: a list of strikes and the pictures it lists, put into a built
//! font without outlines.
//!
//! Every built font has 1000 units an em and a line of 1000 from its
//! ascender (800) to its descender, so a line of n rows has an em of n
//! pixels: a strike of n pixels an em is at its own size there, its
//! baseline on row n * 0.8 rounded.
//!
//! - Every way a strike lists its pictures (the five) finds each glyph's.
//! - Every form of a picture - rows from a new byte, rows one after the
//!   other, with five bytes of measures, eight, or the strike's - of 1,
//!   2, 4 and 8 bits a pixel, and one put together of other glyphs.
//! - Which strike is read for a line's height, and for a glyph's box.
//! - A picture at its strike's size pixel for pixel, at half of it the
//!   mean of four, at twice it each pixel four times, and at an edge
//!   between pixels the share that lies in each.
//! - Pictures of colour: a PNG file under each of its three forms, at
//!   its size and scaled, the colour weighted by coverage; a file that
//!   is damaged or not the size its measures say; the room a glyph
//!   takes, said without reading it; memory that runs out.
//! - compression.library, held open by a font of colour pictures for as
//!   long as it is open, and such a font not opened without it.
//! - What is no font of pictures: one with outlines, one whose list is
//!   of another version or whose strikes have other bits a pixel; and
//!   of two pairs of tables the colour one read.
//!
//! `waysFont`, `formsFont` and `colourFont` are also the fonts of
//! pictures the tests of changed bytes (`fuzz.zig`) and of fonts closed
//! to writes (`readonly.zig`) start from.

const std = @import("std");
const sdk = @import("sdk");
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const truetype = sdk.truetype;
const decode = sdk.datatypes.png.decode;
const builder = @import("builder.zig");
const built = @import("truetype.zig");
const _outline = @import("../outline/_outline.zig");
const _strike = @import("../outline/_strike.zig");

const testing = std.testing;
const File = builder.File;
const Rig = built.Rig;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;

// --- the tables -----------------------------------------------------------

/// One range of a strike's glyphs.
const Range = struct {
    first: u16,
    last: u16,
    /// Which of the five ways its pictures are listed.
    way: u16,
    /// The pictures' format.
    format: u16,
    /// Each glyph's picture as it stands among the pictures, in order:
    /// of every glyph from `first` to `last`, or of each of `names`.
    pictures: []const []const u8,
    /// The glyphs of ways 4 and 5, which name them.
    names: []const u16 = &.{},
    /// The measures of all its pictures, for ways 2 and 5: rows, width,
    /// left, top.
    shared: [4]i8 = .{ 0, 0, 0, 0 },
    /// What ways 2 and 5 say a picture's bytes are; the first one's when
    /// not given.
    each: ?u32 = null,
};

/// One strike.
const Strike = struct {
    /// Pixels an em down, and across when not the same.
    ppem: u8,
    ppem_x: ?u8 = null,
    /// Bits a pixel.
    depth: u8,
    first: u16 = 0,
    last: u16 = 0xFFFF,
    ranges: []const Range,
};

/// The list of `strikes` written to `places` and their pictures to
/// `pictures`, both from empty, the list of version `major`.
fn tables(places: *File, pictures: *File, major: u16, strikes: []const Strike) void {
    places.* = .{};
    pictures.* = .{};
    places.word(major);
    places.word(0);
    places.long(@intCast(strikes.len));
    const records = places.len;
    places.skip(@intCast(48 * strikes.len));
    pictures.word(major);
    pictures.word(0);
    for (strikes, 0..) |strike, nth| {
        const record = records + @as(u32, @intCast(nth)) * 48;
        const list = places.len;
        places.setLong(record, list);
        places.setLong(record + 8, @intCast(strike.ranges.len));
        places.setWord(record + 40, strike.first);
        places.setWord(record + 42, strike.last);
        places.bytes[record + 44] = strike.ppem_x orelse strike.ppem;
        places.bytes[record + 45] = strike.ppem;
        places.bytes[record + 46] = strike.depth;
        places.skip(@intCast(8 * strike.ranges.len));
        for (strike.ranges, 0..) |range, r| {
            const entry = list + @as(u32, @intCast(r)) * 8;
            places.setWord(entry, range.first);
            places.setWord(entry + 2, range.last);
            places.setLong(entry + 4, places.len - list);
            places.word(range.way);
            places.word(range.format);
            const base = pictures.len;
            places.long(base);
            const each = range.each orelse @as(u32, @intCast(range.pictures[0].len));
            switch (range.way) {
                1 => {
                    for (range.pictures) |picture| {
                        places.long(pictures.len - base);
                        pictures.text(picture);
                    }
                    places.long(pictures.len - base);
                },
                3 => {
                    for (range.pictures) |picture| {
                        places.word(@intCast(pictures.len - base));
                        pictures.text(picture);
                    }
                    places.word(@intCast(pictures.len - base));
                },
                4 => {
                    places.long(@intCast(range.names.len));
                    for (range.pictures, range.names) |picture, name| {
                        places.word(name);
                        places.word(@intCast(pictures.len - base));
                        pictures.text(picture);
                    }
                    places.word(0);
                    places.word(@intCast(pictures.len - base));
                },
                2, 5 => {
                    places.long(each);
                    for (range.shared) |measure| places.byte(@bitCast(measure));
                    places.byte(@bitCast(range.shared[1]));
                    places.skip(3);
                    if (range.way == 5) {
                        places.long(@intCast(range.names.len));
                        for (range.names) |name| places.word(name);
                    }
                    for (range.pictures) |picture| pictures.text(picture);
                },
                else => unreachable,
            }
            places.pad();
        }
        places.setLong(record + 4, places.len - list);
    }
}

/// Which pair of tables a font's pictures are in.
const Pair = enum { coverage, colour, older };

/// What a built font of pictures is made of.
const Made = struct {
    glyphs: u16 = 8,
    pair: Pair = .coverage,
    major: u16 = 2,
    outlines: bool = false,
    strikes: []const Strike,
    /// Strikes of the other pair, for a font that has both.
    other: []const Strike = &.{},
};

/// A font of `made` in `file`; 'A' is glyph 1, and so on to the last.
fn fontOf(file: *File, made: Made) void {
    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    cmap.segments(&.{
        .{ .first = 'A', .last = 'A' + made.glyphs - 2, .delta = 1 -% @as(u16, 'A') },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });
    var places: File = .{};
    var pictures: File = .{};
    var other_places: File = .{};
    var other_pictures: File = .{};
    tables(&places, &pictures, made.major, made.strikes);
    tables(&other_places, &other_pictures, made.major, made.other);
    const colour = made.pair == .colour;
    const both = [4]builder.Table{
        .{ .tag = if (colour) "CBLC" else if (made.pair == .older) "bloc" else "EBLC", .bytes = places.written() },
        .{ .tag = if (colour) "CBDT" else if (made.pair == .older) "bdat" else "EBDT", .bytes = pictures.written() },
        .{ .tag = if (colour) "EBLC" else "CBLC", .bytes = other_places.written() },
        .{ .tag = if (colour) "EBDT" else "CBDT", .bytes = other_pictures.written() },
    };
    file.* = .{};
    _ = builder.font(file, .{
        .cmap = cmap.written(),
        .glyphs = made.glyphs,
        .outlines = made.outlines,
        .more = both[0..if (made.other.len != 0) 4 else 2],
    });
}

// --- pictures -------------------------------------------------------------

/// The five bytes of measures in front of a picture, and the eight.
fn small(rows: u8, width: u8, left: i8, top: i8) [5]u8 {
    return .{ rows, width, @bitCast(left), @bitCast(top), width };
}

fn big(rows: u8, width: u8, left: i8, top: i8) [8]u8 {
    return .{ rows, width, @bitCast(left), @bitCast(top), width, 0, 0, 0 };
}

/// Pixels of `depth` bits written to `file`, `width` a row: each row
/// from a new byte (`aligned`), or one straight after the other.
fn writePixels(file: *File, depth: u8, width: u32, values: []const u8, aligned: bool) void {
    var held: u32 = 0;
    var bits: u32 = 0;
    for (values, 0..) |value, nth| {
        held = (held << @intCast(depth)) | value;
        bits += depth;
        while (bits >= 8) {
            file.byte(@truncate(held >> @intCast(bits - 8)));
            bits -= 8;
        }
        const row_done = (nth + 1) % width == 0;
        if (bits != 0 and (nth + 1 == values.len or (aligned and row_done))) {
            file.byte(@truncate(held << @intCast(8 - bits)));
            bits = 0;
        }
    }
}

/// One chunk of a PNG file.
fn chunk(file: *File, id: *const [4]u8, data: []const u8) void {
    file.long(@intCast(data.len));
    const from = file.len;
    file.text(id);
    file.text(data);
    file.long(decode.crc32(file.bytes[from..file.len]));
}

/// The seven passes of an interlaced file: where each starts and how
/// far its pixels are apart, across and down.
const passes = [7][4]u32{
    .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 },
    .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 },
};

/// A PNG file of `width` by `rows` pixels - red, green, blue, coverage,
/// a byte each - written to `file`: no filter, packed as it is, row by
/// row or interlaced.
fn png(file: *File, width: u32, rows: u32, pixels: []const u8, interlaced: bool) void {
    file.text(&decode.signature);
    var header: File = .{};
    header.long(width);
    header.long(rows);
    header.text(&.{ 8, 6, 0, 0, @intFromBool(interlaced) });
    chunk(file, "IHDR", header.written());

    var raw: File = .{};
    if (interlaced) {
        for (passes) |pass| {
            var y = pass[1];
            while (y < rows and pass[0] < width) : (y += pass[3]) {
                raw.byte(0);
                var x = pass[0];
                while (x < width) : (x += pass[2]) raw.text(pixels[(y * width + x) * 4 ..][0..4]);
            }
        }
    } else {
        for (0..rows) |y| {
            raw.byte(0);
            raw.text(pixels[y * width * 4 ..][0 .. width * 4]);
        }
    }
    var stream: File = .{};
    stream.text(&.{ 0x78, 0x01, 0x01 });
    const length: u16 = @intCast(raw.len);
    stream.text(&.{ @truncate(length), @truncate(length >> 8), @truncate(~length), @truncate(~length >> 8) });
    stream.text(raw.written());
    stream.long(std.hash.Adler32.hash(raw.written()));
    chunk(file, "IDAT", stream.written());
    chunk(file, "IEND", &.{});
}

/// A picture that is a PNG file, as it stands among the pictures: its
/// measures (`front`: five bytes, eight, or none), the file's length,
/// the file.
fn framed(file: *File, front: []const u8, image: []const u8) void {
    file.text(front);
    file.long(@intCast(image.len));
    file.text(image);
}

// --- rendering ------------------------------------------------------------

/// What a watched byte holds.
const untouched: u8 = 0xAA;

/// A glyph rendered by its number.
const Shown = struct {
    answer: i32,
    kind: fontimage.Kind,
    box: fontimage.Glyph,
    size: u32,
    bytes: [room]u8,

    const room = 1024;

    /// Its pixels.
    fn pixels(shown: *const Shown) []const u8 {
        return shown.bytes[0..shown.size];
    }

    /// Its box is `width` by `rows` at `left`, `top`.
    fn expectBox(shown: *const Shown, left: i32, top: i32, width: u32, rows: u32) !void {
        try testing.expectEqual(left, @as(i32, shown.box.left));
        try testing.expectEqual(top, @as(i32, shown.box.top));
        try testing.expectEqual(width, @as(u32, shown.box.width));
        try testing.expectEqual(rows, @as(u32, shown.box.rows));
    }

    /// The coverage of its pixel at `x`, `y`: 0 to 15.
    fn at(shown: *const Shown, x: u32, y: u32) u8 {
        const byte = shown.bytes[y * shown.box.pitch + x / 2];
        return if (x & 1 == 0) byte >> 4 else byte & 0x0F;
    }
};

/// Glyph `glyph` of `outline` for a line `rows` tall, into `room` bytes;
/// nothing past what it says it wrote is touched.
fn showIn(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, rows: u32, room: u32) !Shown {
    var shown: Shown = undefined;
    @memset(&shown.bytes, untouched);
    var image = truetype.GlyphImage{ .pixels = &shown.bytes, .room = room, .size = 1, .kind = .mono1 };
    shown.answer = tb.RenderGlyph(outline, glyph, rows, &image);
    shown.kind = image.kind;
    shown.box = image.glyph;
    shown.size = image.size;
    const written = if (shown.answer == truetype.TRUETYPE_OK) image.size else 0;
    for (shown.bytes[written..]) |byte| try testing.expectEqual(untouched, byte);
    return shown;
}

fn show(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, rows: u32) !Shown {
    const shown = try showIn(tb, outline, glyph, rows, Shown.room);
    try testing.expectEqual(truetype.TRUETYPE_OK, shown.answer);
    try testing.expectEqual(@as(u32, shown.box.pitch) * shown.box.rows, shown.size);
    return shown;
}

// --- coverage -------------------------------------------------------------

/// The picture the tests of the ways give glyph `glyph`: two pixels in
/// one row, and what they come out as.
fn pairOf(comptime glyph: u8) [2]u8 {
    return .{ (glyph % 16) * 17, ((glyph + 8) % 16) * 17 };
}

/// A font of thirteen glyphs whose strike lists its pictures in each of
/// the five ways: glyph 0, 8 and 11 have none.
pub fn waysFont(file: *File) void {
    const measures = small(1, 2, 0, 1);
    fontOf(file, .{
        .glyphs = 13,
        .strikes = &.{.{
            .ppem = 10,
            .depth = 8,
            .ranges = &.{
                // A start for each glyph, four bytes and two.
                .{ .first = 1, .last = 2, .way = 1, .format = 1, .pictures = &.{ &(measures ++ pairOf(1)), &(measures ++ pairOf(2)) } },
                .{ .first = 3, .last = 4, .way = 3, .format = 1, .pictures = &.{ &(measures ++ pairOf(3)), &(measures ++ pairOf(4)) } },
                // All of one size, their measures in the list.
                .{ .first = 5, .last = 6, .way = 2, .format = 5, .shared = .{ 1, 2, 0, 1 }, .pictures = &.{ &pairOf(5), &pairOf(6) } },
                // The glyphs named: 8 and 11 have no picture.
                .{ .first = 7, .last = 9, .way = 4, .format = 1, .names = &.{ 7, 9 }, .pictures = &.{ &(measures ++ pairOf(7)), &(measures ++ pairOf(9)) } },
                .{ .first = 10, .last = 12, .way = 5, .format = 5, .shared = .{ 1, 2, 0, 1 }, .names = &.{ 10, 12 }, .pictures = &.{ &pairOf(10), &pairOf(12) } },
            },
        }},
    });
}

test "pictures: every way a strike lists its pictures finds each glyph's" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var file: File = .{};
    waysFont(&file);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;

    var glyph: u32 = 0;
    while (glyph < 13) : (glyph += 1) {
        const shown = try show(tb, outline, glyph, 10);
        try testing.expectEqual(fontimage.Kind.alpha4, shown.kind);
        try testing.expectEqual(@as(i16, 6), shown.box.advance);
        if (glyph == 0 or glyph == 8 or glyph == 11) {
            // No picture: no ink, and its advance.
            try testing.expectEqual(@as(u32, 0), shown.size);
            try shown.expectBox(0, 0, 0, 0);
            continue;
        }
        // On the baseline, row 8, one row tall.
        try shown.expectBox(0, 7, 2, 1);
        try testing.expectEqual(@as(u32, 1), shown.size);
        try testing.expectEqual(@as(u8, @intCast(glyph % 16)), shown.at(0, 0));
        try testing.expectEqual(@as(u8, @intCast((glyph + 8) % 16)), shown.at(1, 0));
    }
    // No glyph of that number.
    const none = try showIn(tb, outline, 13, 10, Shown.room);
    try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, none.answer);

    tb.CloseOutline(outline);
    try rig.down();
}

test "pictures: every form of a picture, of 1, 2, 4 and 8 bits a pixel" {
    var rig = try Rig.up();
    const tb = rig.tb;

    for ([_]u8{ 1, 2, 4, 8 }) |depth| {
        // Three pixels by two: a row does not end on a byte.
        var levels: [6]u8 = undefined;
        var values: [6]u8 = undefined;
        for (0..6) |nth| {
            const level: u8 = @intCast((nth * 5 + 3) % 16);
            switch (depth) {
                1 => {
                    values[nth] = level % 2;
                    levels[nth] = values[nth] * 15;
                },
                2 => {
                    values[nth] = level % 4;
                    levels[nth] = values[nth] * 5;
                },
                4 => {
                    values[nth] = level;
                    levels[nth] = level;
                },
                else => {
                    values[nth] = level * 17;
                    levels[nth] = level;
                },
            }
        }
        var rows_small: File = .{};
        rows_small.text(&small(2, 3, 1, 2));
        writePixels(&rows_small, depth, 3, &values, true);
        var bits_small: File = .{};
        bits_small.text(&small(2, 3, 1, 2));
        writePixels(&bits_small, depth, 3, &values, false);
        var bits_bare: File = .{};
        writePixels(&bits_bare, depth, 3, &values, false);
        var rows_big: File = .{};
        rows_big.text(&big(2, 3, 1, 2));
        writePixels(&rows_big, depth, 3, &values, true);
        var bits_big: File = .{};
        bits_big.text(&big(2, 3, 1, 2));
        writePixels(&bits_big, depth, 3, &values, false);

        var file: File = .{};
        fontOf(&file, .{
            .strikes = &.{.{
                .ppem = 10,
                .depth = depth,
                .ranges = &.{
                    .{ .first = 1, .last = 1, .way = 1, .format = 1, .pictures = &.{rows_small.written()} },
                    .{ .first = 2, .last = 2, .way = 1, .format = 2, .pictures = &.{bits_small.written()} },
                    .{ .first = 3, .last = 3, .way = 2, .format = 5, .shared = .{ 2, 3, 1, 2 }, .pictures = &.{bits_bare.written()} },
                    .{ .first = 4, .last = 4, .way = 1, .format = 6, .pictures = &.{rows_big.written()} },
                    .{ .first = 5, .last = 5, .way = 1, .format = 7, .pictures = &.{bits_big.written()} },
                    // Formats that are not read: a glyph without a picture.
                    .{ .first = 6, .last = 6, .way = 1, .format = 3, .pictures = &.{rows_small.written()} },
                    .{ .first = 7, .last = 7, .way = 1, .format = 17, .pictures = &.{rows_small.written()} },
                },
            }},
        });
        const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
        var glyph: u32 = 1;
        while (glyph <= 5) : (glyph += 1) {
            errdefer std.debug.print("{d} bits a pixel, glyph {d}\n", .{ depth, glyph });
            const shown = try show(tb, outline, glyph, 10);
            try shown.expectBox(1, 6, 3, 2);
            try testing.expectEqual(@as(u32, 4), shown.size);
            for (0..6) |nth| try testing.expectEqual(levels[nth], shown.at(@intCast(nth % 3), @intCast(nth / 3)));
            // Half a byte of nothing after a row of three.
            try testing.expectEqual(@as(u8, 0), shown.at(3, 0));
            try testing.expectEqual(@as(u8, 0), shown.at(3, 1));
        }
        for ([_]u32{ 6, 7 }) |unread| try testing.expectEqual(@as(u32, 0), (try show(tb, outline, unread, 10)).size);
        tb.CloseOutline(outline);
    }
    try rig.down();
}

test "pictures: one put together of other glyphs, and what is not put together" {
    var rig = try Rig.up();
    const tb = rig.tb;

    const corner = small(2, 2, 0, 2);
    const whole = small(3, 4, 0, 3);
    // Parts: how many, then each a glyph and where it goes.
    const two = whole ++ [_]u8{ 0, 0, 3, 0, 1, 0, 0, 0, 2, 1, 1, 0, 0, 0, 0 };
    const nested = big(3, 4, 0, 3) ++ [_]u8{ 0, 2, 0, 3, 0, 0, 0, 1, 2, 1 };
    const itself = whole ++ [_]u8{ 0, 0, 1, 0, 5, 0, 0 };
    const outside = whole ++ [_]u8{ 0, 0, 2, 0, 1, 3, 2, 0, 1, 0xFF, 0xFF };
    var many: File = .{};
    many.text(&big(3, 4, 0, 3));
    many.word(257);
    for (0..257) |_| many.text(&.{ 0, 1, 0, 0 });
    var most: File = .{};
    most.text(&big(3, 4, 0, 3));
    most.word(256);
    for (0..256) |_| most.text(&.{ 0, 1, 0, 0 });
    // A picture cut short: three of its four pixels.
    const short = corner ++ [_]u8{ 85, 85, 85 };

    var file: File = .{};
    fontOf(&file, .{ .glyphs = 10, .strikes = &.{.{
        .ppem = 10,
        .depth = 8,
        .ranges = &.{
            .{ .first = 1, .last = 2, .way = 1, .format = 1, .pictures = &.{ &(corner ++ [_]u8{ 85, 85, 85, 85 }), &(corner ++ [_]u8{ 170, 170, 170, 170 }) } },
            .{ .first = 3, .last = 3, .way = 1, .format = 8, .pictures = &.{&two} },
            .{ .first = 4, .last = 4, .way = 1, .format = 9, .pictures = &.{&nested} },
            .{ .first = 5, .last = 6, .way = 1, .format = 8, .pictures = &.{ &itself, &outside } },
            .{ .first = 7, .last = 8, .way = 1, .format = 9, .pictures = &.{ many.written(), most.written() } },
            .{ .first = 9, .last = 9, .way = 1, .format = 1, .pictures = &.{&short} },
        },
    }} });
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;

    const expected = [_]struct { glyph: u32, rows: [3][4]u8 }{
        // Glyph 1, glyph 2 a pixel right and down - where both are, the
        // larger - and a glyph without a picture left out.
        .{ .glyph = 3, .rows = .{ .{ 5, 5, 0, 0 }, .{ 5, 10, 10, 0 }, .{ 0, 10, 10, 0 } } },
        // That one, and glyph 1 at its right edge.
        .{ .glyph = 4, .rows = .{ .{ 5, 5, 0, 0 }, .{ 5, 10, 10, 5 }, .{ 0, 10, 10, 5 } } },
        // One that names itself is not read: its box, with nothing in it.
        .{ .glyph = 5, .rows = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } } },
        // What of a part lies outside is left out.
        .{ .glyph = 6, .rows = .{ .{ 5, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 5 } } },
        // More parts than are read, and as many as are.
        .{ .glyph = 7, .rows = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } } },
        .{ .glyph = 8, .rows = .{ .{ 5, 5, 0, 0 }, .{ 5, 5, 0, 0 }, .{ 0, 0, 0, 0 } } },
    };
    for (expected) |want| {
        errdefer std.debug.print("glyph {d}\n", .{want.glyph});
        const shown = try show(tb, outline, want.glyph, 10);
        try shown.expectBox(0, 5, 4, 3);
        for (want.rows, 0..) |row, y| {
            for (row, 0..) |level, x| try testing.expectEqual(level, shown.at(@intCast(x), @intCast(y)));
        }
    }
    // Data too short for its rows: the box, with nothing in it.
    const cut = try show(tb, outline, 9, 10);
    try cut.expectBox(0, 6, 2, 2);
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, cut.pixels());

    tb.CloseOutline(outline);
    try rig.down();
}

// --- which strike, and at what size -----------------------------------------

/// A picture of one pixel on the baseline, of coverage `level`.
fn dot(comptime level: u8) [6]u8 {
    return small(1, 1, 0, 1) ++ [_]u8{level * 17};
}

test "pictures: the strike nearest above a line's height, the largest when none is, the first of two alike" {
    var rig = try Rig.up();
    const tb = rig.tb;

    // Not in the order of their sizes.
    var file: File = .{};
    fontOf(&file, .{
        .strikes = &.{
            .{ .ppem = 16, .depth = 8, .ranges = &.{.{ .first = 1, .last = 1, .way = 1, .format = 1, .pictures = &.{&dot(6)} }} },
            .{ .ppem = 32, .depth = 8, .ranges = &.{.{ .first = 1, .last = 1, .way = 1, .format = 1, .pictures = &.{&dot(9)} }} },
            .{ .ppem = 8, .depth = 8, .ranges = &.{.{ .first = 1, .last = 2, .way = 1, .format = 1, .pictures = &.{ &dot(3), &dot(12) } }} },
            .{ .ppem = 16, .depth = 8, .ranges = &.{.{ .first = 1, .last = 1, .way = 1, .format = 1, .pictures = &.{&dot(15)} }} },
            // One the glyph lies outside of, and one of no size.
            .{ .ppem = 64, .depth = 8, .first = 3, .last = 7, .ranges = &.{.{ .first = 1, .last = 1, .way = 1, .format = 1, .pictures = &.{&dot(1)} }} },
            .{ .ppem = 0, .depth = 8, .ranges = &.{.{ .first = 1, .last = 1, .way = 1, .format = 1, .pictures = &.{&dot(2)} }} },
        },
    });
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));

    const lines = [_]struct { rows: ?u32, ppem: u32 }{
        .{ .rows = 1, .ppem = 8 },   .{ .rows = 8, .ppem = 8 },     .{ .rows = 9, .ppem = 16 },
        .{ .rows = 16, .ppem = 16 }, .{ .rows = 17, .ppem = 32 },   .{ .rows = 32, .ppem = 32 },
        .{ .rows = 33, .ppem = 32 }, .{ .rows = 4096, .ppem = 32 }, .{ .rows = null, .ppem = 32 },
    };
    for (lines) |line| {
        const picture = _strike.pictureOf(font, 1, line.rows) orelse return error.NoPicture;
        try testing.expectEqual(line.ppem, picture.strike.ppem_y);
        // A glyph only one strike has is that one's at every height.
        const only = _strike.pictureOf(font, 2, line.rows) orelse return error.NoPicture;
        try testing.expectEqual(@as(u32, 8), only.strike.ppem_y);
    }
    try testing.expect(_strike.pictureOf(font, 3, 16) == null);

    // At a strike's own size its picture, and of two alike the first's.
    const levels = [_][2]u32{ .{ 8, 3 }, .{ 16, 6 }, .{ 32, 9 } };
    for (levels) |level| {
        const shown = try show(tb, outline, 1, level[0]);
        try testing.expectEqual(@as(u32, 1), shown.size);
        try testing.expectEqual(@as(u8, @intCast(level[1])), shown.at(0, 0));
    }

    // A glyph's box is its largest picture's, in units and widened to
    // whole ones; its advance the font's.
    var measures: truetype.GlyphMetrics = .{};
    try testing.expect(tb.GlyphMetrics(outline, 1, &measures));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .left_bearing = 0, .x_min = 0, .y_min = 0, .x_max = 32, .y_max = 32 }, measures);
    try testing.expect(tb.GlyphMetrics(outline, 2, &measures));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .left_bearing = 0, .x_min = 0, .y_min = 0, .x_max = 125, .y_max = 125 }, measures);
    try testing.expect(tb.GlyphMetrics(outline, 3, &measures));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600 }, measures);

    tb.CloseOutline(outline);
    try rig.down();
}

test "pictures: at its size pixel for pixel, smaller the mean of each pixel's area, larger each pixel over its area" {
    var rig = try Rig.up();
    const tb = rig.tb;

    // Four by four, two pixels right of the point, four rows above the
    // baseline: its quarters all covered, one pixel of four, three of
    // four, none.
    const quarters = small(4, 4, 2, 4) ++ [_]u8{
        255, 255, 255, 0,
        255, 255, 0,   0,
        255, 255, 0,   0,
        255, 0,   0,   0,
    };
    // Two by two, its edges half a pixel off at half the size.
    const offset = small(2, 2, 1, 2) ++ [_]u8{ 102, 102, 102, 102 };
    var file: File = .{};
    fontOf(&file, .{ .strikes = &.{.{
        .ppem = 20,
        .depth = 8,
        .ranges = &.{.{ .first = 1, .last = 2, .way = 1, .format = 1, .pictures = &.{ &quarters, &offset } }},
    }} });
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;

    // Its own size: the baseline is row 16.
    const same = try show(tb, outline, 1, 20);
    try same.expectBox(2, 12, 4, 4);
    try testing.expectEqual(@as(i16, 12), same.box.advance);
    for (0..4) |y| {
        for (0..4) |x| try testing.expectEqual(@as(u8, quarters[5 + y * 4 + x] / 17), same.at(@intCast(x), @intCast(y)));
    }

    // Half: each pixel the mean of four. 255, 63.75, 191.25 and 0 of
    // 255, in fifteenths rounded.
    const half = try show(tb, outline, 1, 10);
    try half.expectBox(1, 6, 2, 2);
    try testing.expectEqual(@as(i16, 6), half.box.advance);
    try testing.expectEqualSlices(u8, &.{ 0xF4, 0xB0 }, half.pixels());

    // Twice: each pixel four.
    const twice = try show(tb, outline, 1, 40);
    try twice.expectBox(4, 24, 8, 8);
    for (0..8) |y| {
        for (0..8) |x| try testing.expectEqual(@as(u8, quarters[5 + (y / 2) * 4 + x / 2] / 17), twice.at(@intCast(x), @intCast(y)));
    }

    // An edge between two pixels: each has the half of it that lies in
    // it, the rest of its area counting as nothing.
    const between = try show(tb, outline, 2, 10);
    try between.expectBox(0, 7, 2, 1);
    try testing.expectEqualSlices(u8, &.{0x33}, between.pixels());

    tb.CloseOutline(outline);

    // A strike of more pixels across than down.
    const wide = small(1, 4, 0, 1) ++ [_]u8{ 255, 255, 0, 0 };
    fontOf(&file, .{ .strikes = &.{.{
        .ppem = 10,
        .ppem_x = 20,
        .depth = 8,
        .ranges = &.{.{ .first = 1, .last = 1, .way = 1, .format = 1, .pictures = &.{&wide} }},
    }} });
    const squeezed = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    const narrow = try show(tb, squeezed, 1, 10);
    try narrow.expectBox(0, 7, 2, 1);
    try testing.expectEqualSlices(u8, &.{0xF0}, narrow.pixels());
    var measures: truetype.GlyphMetrics = .{};
    try testing.expect(tb.GlyphMetrics(squeezed, 1, &measures));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .left_bearing = 0, .x_min = 0, .y_min = 0, .x_max = 200, .y_max = 100 }, measures);
    tb.CloseOutline(squeezed);

    try rig.down();
}

// --- colour -----------------------------------------------------------------

/// Two pixels by two: red, green, a third-covered blue, and a pixel of
/// colour that nothing covers.
const four = [16]u8{
    255, 0, 0,   255, 0, 255, 0, 255,
    0,   0, 255, 85,  9, 9,   9, 0,
};

/// The same as a glyph comes out: no colour where nothing covers.
const four_shown = [16]u8{
    255, 0, 0,   255, 0, 255, 0, 255,
    0,   0, 255, 85,  0, 0,   0, 0,
};

/// A font of colour pictures in a strike of 20 pixels an em, each two
/// by two on the baseline: glyphs 1 to 3 `four` under the three forms a
/// PNG file comes in, 4 the file interlaced, 5 a file with a byte
/// changed, 6 a file of one pixel, 7 a file said to be longer than what
/// is there.
pub fn colourFont(file: *File) void {
    const measures = small(2, 2, 0, 2);
    var image: File = .{};
    png(&image, 2, 2, &four, false);
    var laced: File = .{};
    png(&laced, 2, 2, &four, true);
    var changed = image;
    changed.bytes[changed.len - 20] ^= 0x40;
    var one: File = .{};
    png(&one, 1, 1, four[0..4], false);

    var with_small: File = .{};
    framed(&with_small, &measures, image.written());
    var with_big: File = .{};
    framed(&with_big, &big(2, 2, 0, 2), image.written());
    var bare: File = .{};
    framed(&bare, &.{}, image.written());
    var with_laced: File = .{};
    framed(&with_laced, &measures, laced.written());
    var with_changed: File = .{};
    framed(&with_changed, &measures, changed.written());
    var with_one: File = .{};
    framed(&with_one, &measures, one.written());
    var long: File = .{};
    framed(&long, &measures, image.written());
    long.setLong(5, image.len + 1);

    fontOf(file, .{ .pair = .colour, .strikes = &.{.{
        .ppem = 20,
        .depth = 32,
        .ranges = &.{
            .{ .first = 1, .last = 1, .way = 1, .format = 17, .pictures = &.{with_small.written()} },
            .{ .first = 2, .last = 2, .way = 1, .format = 18, .pictures = &.{with_big.written()} },
            .{ .first = 3, .last = 3, .way = 2, .format = 19, .shared = .{ 2, 2, 0, 2 }, .pictures = &.{bare.written()} },
            .{ .first = 4, .last = 7, .way = 1, .format = 17, .pictures = &.{ with_laced.written(), with_changed.written(), with_one.written(), long.written() } },
        },
    }} });
}

test "pictures of colour: a PNG file under each of its forms, at its size and scaled, and one that cannot be read" {
    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;

    var file: File = .{};
    colourFont(&file);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;

    // At its size, red, green, blue and coverage as the file has them.
    var glyph: u32 = 1;
    while (glyph <= 4) : (glyph += 1) {
        errdefer std.debug.print("glyph {d}\n", .{glyph});
        const shown = try show(tb, outline, glyph, 20);
        try testing.expectEqual(fontimage.Kind.rgba32, shown.kind);
        try shown.expectBox(0, 14, 2, 2);
        try testing.expectEqual(@as(u16, 8), shown.box.pitch);
        try testing.expectEqual(@as(i16, 12), shown.box.advance);
        try testing.expectEqualSlices(u8, &four_shown, shown.pixels());
    }

    // Half: one pixel, covered by the mean of the four (595 / 4), its
    // colour theirs weighted by how much each covers.
    const half = try show(tb, outline, 1, 10);
    try half.expectBox(0, 7, 1, 1);
    try testing.expectEqualSlices(u8, &.{ 109, 109, 36, 149 }, half.pixels());

    // Twice: each pixel four.
    const twice = try show(tb, outline, 1, 40);
    try twice.expectBox(0, 28, 4, 4);
    for (0..4) |y| {
        for (0..4) |x| {
            const from = ((y / 2) * 2 + x / 2) * 4;
            try testing.expectEqualSlices(u8, four_shown[from..][0..4], twice.bytes[(y * 4 + x) * 4 ..][0..4]);
        }
    }

    // A damaged file, and one not the size its measures say: the box,
    // with nothing in it.
    for ([_]u32{ 5, 6 }) |damaged| {
        const shown = try show(tb, outline, damaged, 20);
        try shown.expectBox(0, 14, 2, 2);
        try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0)), shown.pixels());
    }
    // A file that does not lie in its data: a glyph without a picture.
    const none = try show(tb, outline, 7, 20);
    try testing.expectEqual(fontimage.Kind.rgba32, none.kind);
    try testing.expectEqual(@as(u32, 0), none.size);
    try testing.expectEqual(@as(i16, 12), none.box.advance);

    // The room a glyph takes is said from its measures: the same for a
    // file that cannot be read, and nothing is written.
    for ([_]u32{ 1, 5 }) |asked| {
        for ([_]u32{ 0, 15 }) |room| {
            const short = try showIn(tb, outline, asked, 20, room);
            try testing.expectEqual(truetype.TRUETYPEERR_ROOM, short.answer);
            try testing.expectEqual(@as(u32, 16), short.size);
            try short.expectBox(0, 14, 2, 2);
            try testing.expectEqual(@as(i16, 12), short.box.advance);
        }
    }

    // An image of the font's characters is of colour too, its glyphs
    // the ones rendered by their numbers.
    const ranges = [_]truetype.CodeRange{.{ .first = 'A', .last = 'G' }};
    const image = tb.RenderFontImage(outline, 20, &ranges, ranges.len) orelse return error.NoImage;
    const block: [*]const u8 = @ptrCast(image);
    try testing.expect(fontimage.check(block, image.size));
    try testing.expect(fontimage.sound(block, image.size));
    try testing.expectEqual(fontimage.Kind.rgba32, image.kind);
    var code: u32 = 'A';
    while (code <= 'G') : (code += 1) {
        const in_image = fontimage.find(image, code) orelse return error.NoGlyph;
        const shown = try show(tb, outline, code - 'A' + 1, 20);
        var by_number = shown.box;
        by_number.data = in_image.data;
        try testing.expectEqual(by_number, in_image.*);
        try testing.expectEqualSlices(u8, shown.pixels(), fontimage.pixelsOf(image, in_image)[0..shown.size]);
    }
    sys.FreeVec(image);

    tb.CloseOutline(outline);
    try rig.down();
}

test "pictures of colour: the font is opened with compression.library, and not without" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var colour: File = .{};
    colourFont(&colour);
    var coverage: File = .{};
    fontOf(&coverage, .{ .strikes = &.{.{
        .ppem = 10,
        .depth = 8,
        .ranges = &.{.{ .first = 1, .last = 1, .way = 1, .format = 1, .pictures = &.{&dot(15)} }},
    }} });

    // Held open for as long as the font is.
    const packer = rig.packer.?;
    try testing.expectEqual(@as(u16, 0), packer.open_cnt);
    const first = tb.OpenOutline(&colour.bytes, colour.len, null) orelse return error.NoOutline;
    const second = tb.OpenOutline(&colour.bytes, colour.len, null) orelse return error.NoOutline;
    try testing.expectEqual(@as(u16, 2), packer.open_cnt);
    // A font of coverage does not ask for it.
    const plain = tb.OpenOutline(&coverage.bytes, coverage.len, null) orelse return error.NoOutline;
    try testing.expectEqual(@as(u16, 2), packer.open_cnt);
    tb.CloseOutline(first);
    tb.CloseOutline(second);
    tb.CloseOutline(plain);
    try testing.expectEqual(@as(u16, 0), packer.open_cnt);

    rig.withoutPacker();
    try testing.expect(tb.OpenOutline(&colour.bytes, colour.len, null) == null);
    const still = tb.OpenOutline(&coverage.bytes, coverage.len, null) orelse return error.NoOutline;
    try testing.expectEqual(@as(u32, 1), (try show(tb, still, 1, 10)).size);
    tb.CloseOutline(still);

    try rig.down();
}

test "pictures of colour: memory that runs out at any of a glyph's blocks is said, and none is kept" {
    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;

    // A picture of 16 by 16, every pixel its own, in a strike of 20.
    var drawn: [16 * 16 * 4]u8 = undefined;
    for (0..16 * 16) |pixel| {
        drawn[pixel * 4 + 0] = @intCast(pixel);
        drawn[pixel * 4 + 1] = @intCast(255 - pixel);
        drawn[pixel * 4 + 2] = @intCast(pixel * 7 % 256);
        drawn[pixel * 4 + 3] = @intCast(64 + pixel % 192);
    }
    var image_file: File = .{};
    png(&image_file, 16, 16, &drawn, false);
    var picture: File = .{};
    framed(&picture, &small(16, 16, 0, 16), image_file.written());
    var file: File = .{};
    fontOf(&file, .{ .pair = .colour, .strikes = &.{.{
        .ppem = 20,
        .depth = 32,
        .ranges = &.{.{ .first = 1, .last = 1, .way = 1, .format = 17, .pictures = &.{picture.written()} }},
    }} });
    // The font holds compression.library open: it stays when memory
    // runs out.
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;

    // What the call writes with all the memory there is: twice the
    // picture's size, 32 by 32 pixels of four bytes.
    const room = 8 * 1024;
    const size = 32 * 32 * 4;
    var expected: [room]u8 = undefined;
    var bytes: [room]u8 = undefined;
    var image = truetype.GlyphImage{ .pixels = &expected, .room = room, .kind = .mono1 };
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, 1, 40, &image));
    try testing.expectEqual(@as(u32, size), image.size);
    const box = image.glyph;

    // All the memory taken but one stretch of it.
    const stretch = 512 * 1024;
    const kept = sys.AllocVec(stretch, sdk.exec.MEMF_ANY) orelse return error.NoMemory;
    var taken: [256]struct { block: *anyopaque, size: usize } = undefined;
    var taken_count: usize = 0;
    while (taken_count < taken.len) {
        const largest = sys.AvailMem(sdk.exec.MEMF_ANY | sdk.exec.MEMF_LARGEST);
        if (largest == 0) break;
        const block = sys.AllocMem(largest, sdk.exec.MEMF_ANY) orelse break;
        taken[taken_count] = .{ .block = block, .size = largest };
        taken_count += 1;
    }
    sys.FreeVec(kept);
    const free = sys.AvailMem(sdk.exec.MEMF_ANY);
    try testing.expect(free <= stretch + 64);

    // The stretch filled but for a little, and a little more each time:
    // the glyph's pixels, the picture's, and what the file is unpacked
    // with each fail in turn, and then it renders.
    var failed: u32 = 0;
    var rendered = false;
    var left: usize = 0;
    while (left < stretch - 64) : (left += 128) {
        const filler = sys.AllocVec(stretch - 64 - left, sdk.exec.MEMF_ANY) orelse return error.NoMemory;
        const before = sys.AvailMem(sdk.exec.MEMF_ANY);
        @memset(&bytes, untouched);
        image = .{ .pixels = &bytes, .room = room, .size = 77, .kind = .mono1, .glyph = .{ .width = 6, .rows = 7 } };
        const answer = tb.RenderGlyph(outline, 1, 40, &image);
        try testing.expectEqual(before, sys.AvailMem(sdk.exec.MEMF_ANY));
        sys.FreeVec(filler);
        try testing.expectEqual(fontimage.Kind.rgba32, image.kind);
        if (answer == truetype.TRUETYPE_OK) {
            try testing.expectEqual(@as(u32, size), image.size);
            try testing.expectEqual(box, image.glyph);
            try testing.expectEqualSlices(u8, expected[0..size], bytes[0..size]);
            for (bytes[size..]) |byte| try testing.expectEqual(untouched, byte);
            rendered = true;
            break;
        }
        try testing.expectEqual(truetype.TRUETYPEERR_NOMEM, answer);
        try testing.expectEqual(@as(u32, 0), image.size);
        try testing.expectEqual(fontimage.Glyph{}, image.glyph);
        for (bytes) |byte| try testing.expectEqual(untouched, byte);
        failed += 1;
    }
    try testing.expect(rendered);
    // The glyph's pixels alone are 32 steps of 128 bytes.
    try testing.expect(failed > 32);

    try testing.expectEqual(free, sys.AvailMem(sdk.exec.MEMF_ANY));
    for (taken[0..taken_count]) |entry| sys.FreeMem(entry.block, entry.size);
    tb.CloseOutline(outline);
    try rig.down();
}

// --- what is no font of pictures -------------------------------------------

test "pictures: a font with outlines is drawn from them, and one whose list cannot be read has no glyph to draw" {
    var rig = try Rig.up();
    const tb = rig.tb;

    const strikes = [_]Strike{.{
        .ppem = 10,
        .depth = 8,
        .ranges = &.{.{ .first = 1, .last = 1, .way = 1, .format = 1, .pictures = &.{&dot(15)} }},
    }};

    // Outlines and pictures: as the same font without the pictures.
    var both: File = .{};
    fontOf(&both, .{ .outlines = true, .strikes = &strikes });
    var plain: File = .{};
    fontOf(&plain, .{ .outlines = true, .strikes = &.{} });
    const with = tb.OpenOutline(&both.bytes, both.len, null) orelse return error.NoOutline;
    const without = tb.OpenOutline(&plain.bytes, plain.len, null) orelse return error.NoOutline;
    const font: *const _outline.Font = @ptrCast(@alignCast(with));
    try testing.expect(!_outline.hasPictures(font));
    for ([_]u32{ 10, 37 }) |rows| {
        const drawn = try show(tb, with, 1, rows);
        const model = try show(tb, without, 1, rows);
        try testing.expect(drawn.size > 1);
        try testing.expectEqual(fontimage.Kind.alpha4, drawn.kind);
        try testing.expectEqual(model.box, drawn.box);
        try testing.expectEqualSlices(u8, model.pixels(), drawn.pixels());
    }
    var measures: truetype.GlyphMetrics = .{};
    var model_measures: truetype.GlyphMetrics = .{};
    try testing.expect(tb.GlyphMetrics(with, 1, &measures));
    try testing.expect(tb.GlyphMetrics(without, 1, &model_measures));
    try testing.expectEqual(model_measures, measures);
    tb.CloseOutline(with);
    tb.CloseOutline(without);

    // A list of a version not read: a font of neither.
    var newer: File = .{};
    fontOf(&newer, .{ .major = 4, .strikes = &strikes });
    const unread = tb.OpenOutline(&newer.bytes, newer.len, null) orelse return error.NoOutline;
    const refused = try showIn(tb, unread, 1, 10, Shown.room);
    try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, refused.answer);
    try testing.expectEqual(@as(u32, 0), refused.size);
    try testing.expect(tb.GlyphMetrics(unread, 1, &measures));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600 }, measures);
    const ranges = [_]truetype.CodeRange{.{ .first = 'A', .last = 'A' }};
    try testing.expect(tb.RenderFontImage(unread, 10, &ranges, ranges.len) == null);
    tb.CloseOutline(unread);

    // Version 3 is read as 2 is.
    var third: File = .{};
    fontOf(&third, .{ .major = 3, .strikes = &strikes });
    const read = tb.OpenOutline(&third.bytes, third.len, null) orelse return error.NoOutline;
    try testing.expectEqual(@as(u32, 1), (try show(tb, read, 1, 10)).size);
    tb.CloseOutline(read);

    try rig.down();
}

test "pictures: a strike of bits its pair does not have is passed over, and of two pairs the one of colour is read" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var image_file: File = .{};
    png(&image_file, 2, 2, &four, false);
    var picture: File = .{};
    framed(&picture, &small(2, 2, 0, 2), image_file.written());
    const of_colour = Strike{
        .ppem = 20,
        .depth = 32,
        .ranges = &.{.{ .first = 1, .last = 1, .way = 1, .format = 17, .pictures = &.{picture.written()} }},
    };
    const of_coverage = Strike{
        .ppem = 10,
        .depth = 8,
        .ranges = &.{.{ .first = 1, .last = 2, .way = 1, .format = 1, .pictures = &.{ &dot(15), &dot(15) } }},
    };
    // The same lists, each said to be of the other's bits.
    var wrong_colour = of_colour;
    wrong_colour.depth = 8;
    var wrong_coverage = of_coverage;
    wrong_coverage.depth = 32;

    // Among the colour pair's strikes one of 8 bits is none, among the
    // other's one of 32: the glyph is found in the strike after it.
    var file: File = .{};
    fontOf(&file, .{ .pair = .colour, .strikes = &.{ wrong_colour, of_colour } });
    var outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    var font: *const _outline.Font = @ptrCast(@alignCast(outline));
    try testing.expectEqual(@as(u32, 32), (_strike.pictureOf(font, 1, null) orelse return error.NoPicture).strike.depth);
    try testing.expectEqualSlices(u8, &four_shown, (try show(tb, outline, 1, 20)).pixels());
    tb.CloseOutline(outline);

    fontOf(&file, .{ .strikes = &.{ wrong_coverage, of_coverage } });
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    font = @ptrCast(@alignCast(outline));
    try testing.expectEqual(@as(u32, 8), (_strike.pictureOf(font, 1, null) orelse return error.NoPicture).strike.depth);
    try testing.expectEqualSlices(u8, &.{0xF0}, (try show(tb, outline, 1, 10)).pixels());
    tb.CloseOutline(outline);

    // The same pictures under the tables' other names.
    fontOf(&file, .{ .pair = .older, .strikes = &.{of_coverage} });
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    try testing.expectEqualSlices(u8, &.{0xF0}, (try show(tb, outline, 1, 10)).pixels());
    try testing.expectEqualSlices(u8, &.{0xF0}, (try show(tb, outline, 2, 10)).pixels());
    tb.CloseOutline(outline);

    // With none after it the glyph has no picture, and no ink.
    fontOf(&file, .{ .pair = .colour, .strikes = &.{wrong_colour} });
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    font = @ptrCast(@alignCast(outline));
    try testing.expect(_strike.pictureOf(font, 1, null) == null);
    const none = try show(tb, outline, 1, 20);
    try testing.expectEqual(fontimage.Kind.rgba32, none.kind);
    try testing.expectEqual(@as(u32, 0), none.size);
    try testing.expectEqual(@as(i16, 12), none.box.advance);
    tb.CloseOutline(outline);

    // Both pairs: the font is of colour, and a glyph only the other pair
    // has a picture of has none.
    fontOf(&file, .{ .pair = .colour, .strikes = &.{of_colour}, .other = &.{of_coverage} });
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    const first = try show(tb, outline, 1, 20);
    try testing.expectEqual(fontimage.Kind.rgba32, first.kind);
    try testing.expectEqualSlices(u8, &four_shown, first.pixels());
    const second = try show(tb, outline, 2, 20);
    try testing.expectEqual(fontimage.Kind.rgba32, second.kind);
    try testing.expectEqual(@as(u32, 0), second.size);
    tb.CloseOutline(outline);

    try rig.down();
}

// --- fonts for the tests that change a font's bytes -------------------------

/// A font of two strikes: one of 1 bit a pixel whose pictures come in
/// the forms that pack their rows and in the two put together of other
/// glyphs, and one of 4 bits listed by starts of two bytes.
pub fn formsFont(file: *File) void {
    const values = [6]u8{ 1, 0, 1, 1, 1, 0 };
    var bits_small: File = .{};
    bits_small.text(&small(2, 3, 1, 2));
    writePixels(&bits_small, 1, 3, &values, false);
    var rows_big: File = .{};
    rows_big.text(&big(2, 3, 1, 2));
    writePixels(&rows_big, 1, 3, &values, true);
    var bits_big: File = .{};
    bits_big.text(&big(2, 3, 1, 2));
    writePixels(&bits_big, 1, 3, &values, false);
    // Parts: how many, then each a glyph and where it goes.
    const two = small(3, 4, 0, 3) ++ [_]u8{ 0, 0, 2, 0, 1, 0, 0, 0, 2, 1, 1 };
    const nested = big(3, 4, 0, 3) ++ [_]u8{ 0, 2, 0, 4, 0, 0, 0, 3, 1, 1 };

    const levels = [6]u8{ 15, 9, 0, 3, 12, 6 };
    var finer: File = .{};
    finer.text(&small(2, 3, 0, 2));
    writePixels(&finer, 4, 3, &levels, true);

    fontOf(file, .{ .strikes = &.{
        .{
            .ppem = 10,
            .depth = 1,
            .ranges = &.{
                .{ .first = 1, .last = 1, .way = 1, .format = 2, .pictures = &.{bits_small.written()} },
                .{ .first = 2, .last = 2, .way = 1, .format = 6, .pictures = &.{rows_big.written()} },
                .{ .first = 3, .last = 3, .way = 1, .format = 7, .pictures = &.{bits_big.written()} },
                .{ .first = 4, .last = 4, .way = 1, .format = 8, .pictures = &.{&two} },
                .{ .first = 5, .last = 5, .way = 1, .format = 9, .pictures = &.{&nested} },
            },
        },
        .{
            .ppem = 24,
            .depth = 4,
            .ranges = &.{.{ .first = 1, .last = 2, .way = 3, .format = 1, .pictures = &.{ finer.written(), finer.written() } }},
        },
    } });
}

test "pictures: the fonts handed on to be changed have their pictures" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var file: File = .{};
    formsFont(&file);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    // In the strike of 10 the three forms are one picture, and the two
    // put together have ink.
    const first = try show(tb, outline, 1, 10);
    try first.expectBox(1, 6, 3, 2);
    for ([_]u32{ 2, 3 }) |glyph| {
        const shown = try show(tb, outline, glyph, 10);
        try testing.expectEqual(first.box, shown.box);
        try testing.expectEqualSlices(u8, first.pixels(), shown.pixels());
    }
    for ([_]u32{ 4, 5 }) |glyph| {
        const shown = try show(tb, outline, glyph, 10);
        try shown.expectBox(0, 5, 4, 3);
        var ink: u32 = 0;
        for (shown.pixels()) |byte| ink += byte;
        try testing.expect(ink != 0);
    }
    // In the strike of 24, at its size.
    const finer = try show(tb, outline, 2, 24);
    try finer.expectBox(0, 17, 3, 2);
    try testing.expectEqualSlices(u8, &.{ 0xF9, 0x00, 0x3C, 0x60 }, finer.pixels());
    tb.CloseOutline(outline);
    try rig.down();
}

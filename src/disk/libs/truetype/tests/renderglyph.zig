// SPDX-License-Identifier: MIT
//! Host tests of RenderGlyph on the fonts the tests build: a glyph by its
//! number against the same glyph in a font image, the room it is given,
//! what the call refuses, and memory that runs out at each of its blocks.

const std = @import("std");
const sdk = @import("sdk");
const fontimage = sdk.graphics.fontimage;
const truetype = sdk.truetype;
const built = @import("truetype.zig");
const builder = @import("builder.zig");

const testing = std.testing;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;

/// What a byte the call may not write holds.
const untouched: u8 = 0xAA;

/// How many bytes after a glyph's are looked at for a write.
const watched = 16;

/// Room for the largest glyph rendered here, and the watched bytes.
var bytes: [96 * 1024 + watched]u8 = undefined;

/// A glyph image over `room` of the tests' bytes, all of them marked, that
/// says something of everything the call is to set.
fn imageOf(room: u32) truetype.GlyphImage {
    @memset(&bytes, untouched);
    return .{
        .pixels = &bytes,
        .room = room,
        .size = 77,
        .kind = .mono1,
        .glyph = .{ .data = 5, .width = 6, .rows = 7, .top = 8, .left = 9, .advance = 10, .pitch = 11 },
    };
}

/// Every byte from `from` on is as it was marked.
fn expectUntouched(from: u32) !void {
    for (bytes[from..]) |byte| try testing.expectEqual(untouched, byte);
}

/// `image` says nothing of a glyph, and no byte was written.
fn expectNothing(image: *const truetype.GlyphImage) !void {
    try testing.expectEqual(@as(u32, 0), image.size);
    try testing.expectEqual(fontimage.Kind.alpha4, image.kind);
    try testing.expectEqual(fontimage.Glyph{}, image.glyph);
    try expectUntouched(0);
}

/// `found`'s box and advance are `expected`'s. Its place among an image's
/// pixels is 0: it has none.
fn expectBox(expected: *const fontimage.Glyph, found: *const fontimage.Glyph) !void {
    try testing.expectEqual(@as(u32, 0), found.data);
    try testing.expectEqual(expected.width, found.width);
    try testing.expectEqual(expected.rows, found.rows);
    try testing.expectEqual(expected.top, found.top);
    try testing.expectEqual(expected.left, found.left);
    try testing.expectEqual(expected.advance, found.advance);
    try testing.expectEqual(expected.pitch, found.pitch);
}

/// Glyph `glyph` of `outline` at `rows` comes out as `expected`, a glyph
/// of `image`: with no room and with a byte too few it says how many
/// bytes it takes and writes none, and with those it writes them and no
/// more.
fn expectSame(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, rows: u32, image: *const fontimage.FontImage, expected: *const fontimage.Glyph) !void {
    const size = @as(u32, expected.pitch) * expected.rows;
    try testing.expect(size <= bytes.len - watched);

    if (size != 0) {
        for ([_]u32{ 0, size - 1 }) |room| {
            var short = imageOf(room);
            try testing.expectEqual(truetype.TRUETYPEERR_ROOM, tb.RenderGlyph(outline, glyph, rows, &short));
            try testing.expectEqual(size, short.size);
            try testing.expectEqual(fontimage.Kind.alpha4, short.kind);
            try expectBox(expected, &short.glyph);
            try expectUntouched(0);
        }
    }

    for ([_]u32{ size, size + watched }) |room| {
        var whole = imageOf(room);
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, glyph, rows, &whole));
        try testing.expectEqual(size, whole.size);
        try testing.expectEqual(fontimage.Kind.alpha4, whole.kind);
        try expectBox(expected, &whole.glyph);
        try testing.expectEqualSlices(u8, fontimage.pixelsOf(image, expected)[0..size], bytes[0..size]);
        try expectUntouched(size);
    }
}

test "RenderGlyph: a glyph by its number is the glyph of a font image, byte for byte, at every height" {
    var rig = try built.Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;

    var out: built.Out = .{};
    built.buildFont(&out);
    const outline = tb.OpenOutline(&out.bytes, out.len, null) orelse return error.NotRead;

    const letters = [_]truetype.CodeRange{.{ .first = 'A', .last = 'C' }};
    for ([_]u32{ 1, 2, 3, 7, 16, 20, 33, 64, 200, 500 }) |rows| {
        const image = tb.RenderFontImage(outline, rows, &letters, letters.len) orelse return error.NoImage;
        defer sys.FreeVec(image);
        // 'A', 'B' and 'C' are glyphs 1 to 3: a square, one with a curved
        // top, and a composite.
        for ([_]u32{ 'A', 'B', 'C' }) |code| {
            const expected = fontimage.find(image, code) orelse return error.NoGlyph;
            try testing.expectEqual(code - 'A' + 1, tb.GlyphIndex(outline, code));
            try expectSame(tb, outline, code - 'A' + 1, rows, image, expected);
        }
        // Glyph 0 has no ink: the image's default glyph.
        const missing = fontimage.glyphFor(image, 'z');
        try testing.expectEqual(@as(u16, 0), missing.width);
        try expectSame(tb, outline, 0, rows, image, missing);
    }

    // At 20 rows: 'A' 10 by 14 pixels, two down from the top, each byte
    // two pixels wholly covered; the glyph of no ink has its advance.
    var square = imageOf(96);
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, 1, 20, &square));
    try testing.expectEqual(fontimage.Glyph{ .width = 10, .rows = 14, .top = 2, .left = 0, .advance = 12, .pitch = 5 }, square.glyph);
    try testing.expectEqual(@as(u32, 70), square.size);
    for (bytes[0..70]) |byte| try testing.expectEqual(@as(u8, 0xFF), byte);
    var empty = imageOf(0);
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, 0, 20, &empty));
    try testing.expectEqual(fontimage.Glyph{ .advance = 12 }, empty.glyph);
    try testing.expectEqual(@as(u32, 0), empty.size);
    try expectUntouched(0);

    tb.CloseOutline(outline);
    try rig.down();
}

test "RenderGlyph: a height of nothing or too tall, a glyph the font lacks and a font without outlines are refused" {
    var rig = try built.Rig.up();
    const tb = rig.tb;

    var out: built.Out = .{};
    built.buildFont(&out);
    const outline = tb.OpenOutline(&out.bytes, out.len, null) orelse return error.NotRead;

    for ([_]u32{ 0, 4097, 0x1_0000, 0xFFFF_FFFF }) |rows| {
        var image = imageOf(4096);
        try testing.expectEqual(truetype.TRUETYPEERR_ROWS, tb.RenderGlyph(outline, 1, rows, &image));
        try expectNothing(&image);
    }
    // The font has four glyphs.
    for ([_]u32{ 4, 5, 0xFFFF, 0x1_0000, 0xFFFF_FFFF }) |glyph| {
        var image = imageOf(4096);
        try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.RenderGlyph(outline, glyph, 20, &image));
        try expectNothing(&image);
    }
    // The height is looked at first.
    var both = imageOf(4096);
    try testing.expectEqual(truetype.TRUETYPEERR_ROWS, tb.RenderGlyph(outline, 4, 0, &both));
    try expectNothing(&both);
    // The tallest line there is: the square is 2048 by 2868 pixels, which
    // the room here does not hold.
    var tall = imageOf(4096);
    try testing.expectEqual(truetype.TRUETYPEERR_ROOM, tb.RenderGlyph(outline, 1, 4096, &tall));
    try testing.expectEqual(fontimage.Glyph{ .width = 2048, .rows = 2868, .top = 409, .left = 0, .advance = 2458, .pitch = 1024 }, tall.glyph);
    try testing.expectEqual(@as(u32, 1024 * 2868), tall.size);
    try expectUntouched(0);
    tb.CloseOutline(outline);

    // A font of pictures: glyphs, and no outline of any.
    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    cmap.segments(&.{
        .{ .first = 'A', .last = 'E', .delta = @bitCast(@as(i16, 1 - 'A')) },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });
    var file: builder.File = .{};
    _ = builder.font(&file, .{ .cmap = cmap.written(), .glyphs = 6, .outlines = false });
    const pictures = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    for ([_]u32{ 0, 1, 5, 6 }) |glyph| {
        var image = imageOf(4096);
        try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.RenderGlyph(pictures, glyph, 20, &image));
        try expectNothing(&image);
    }
    tb.CloseOutline(pictures);
    try rig.down();
}

test "RenderGlyph: memory that runs out at any of its blocks is said, and none is kept" {
    var rig = try built.Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;

    var out: built.Out = .{};
    built.buildFont(&out);
    const outline = tb.OpenOutline(&out.bytes, out.len, null) orelse return error.NotRead;

    // What the call writes with all the memory there is.
    var expected: [96 * 1024]u8 = undefined;
    var image = imageOf(96 * 1024);
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, 2, 200, &image));
    const size = image.size;
    const box = image.glyph;
    @memcpy(expected[0..size], bytes[0..size]);

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
    // the call's own block, the one it adds the outline up in, and the
    // glyph's pixels each fail in turn, and then it renders.
    var failed: u32 = 0;
    var rendered = false;
    var left: usize = 0;
    while (left < stretch - 64) : (left += 128) {
        const filler = sys.AllocVec(stretch - 64 - left, sdk.exec.MEMF_ANY) orelse return error.NoMemory;
        const before = sys.AvailMem(sdk.exec.MEMF_ANY);
        image = imageOf(96 * 1024);
        const answer = tb.RenderGlyph(outline, 2, 200, &image);
        try testing.expectEqual(before, sys.AvailMem(sdk.exec.MEMF_ANY));
        sys.FreeVec(filler);
        if (answer == truetype.TRUETYPE_OK) {
            try testing.expectEqual(size, image.size);
            try testing.expectEqual(box, image.glyph);
            try testing.expectEqualSlices(u8, expected[0..size], bytes[0..size]);
            try expectUntouched(size);
            rendered = true;
            break;
        }
        try testing.expectEqual(truetype.TRUETYPEERR_NOMEM, answer);
        try expectNothing(&image);
        failed += 1;
    }
    try testing.expect(rendered);
    // 100 by 140 pixels: more than two hundred steps of 128 bytes short.
    try testing.expect(failed > 200);

    try testing.expectEqual(free, sys.AvailMem(sdk.exec.MEMF_ANY));
    for (taken[0..taken_count]) |entry| sys.FreeMem(entry.block, entry.size);
    tb.CloseOutline(outline);
    try rig.down();
}

// SPDX-License-Identifier: MIT
//! Host tests of what lets any number of tasks share one outline: no call
//! writes to an opened outline, to the font's bytes, or to the library's
//! base.
//!
//! A test puts a font's bytes into pages of the host's own and opens the
//! font into another (`_outline.open`, as OpenOutline does into the
//! memory it allocates), then takes the right to write away from all of
//! them. Every call that takes an outline is made through the jump table
//! on that page, twice over, and its answers checked. A call that wrote
//! to the outline or the font would not fail a check: the host ends the
//! test run at the write with a segmentation fault, whose trace names the
//! function that wrote. The base is compared byte by byte with what it
//! held before the calls.
//!
//! What a call needs while it works - a glyph's points, the edges of a
//! rendering - it allocates and frees itself (`glyph/_segments.zig`,
//! `render/_render.zig`); the rig's check that nothing is left allocated
//! covers it.
//!
//! The pages are the Linux kernel's to close, so the tests are skipped on
//! another host.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const truetype = sdk.truetype;
const vector = sdk.vector;
const builder = @import("builder.zig");
const reference = @import("reference.zig");
const built = @import("truetype.zig");
const cubic = @import("cff.zig");
const pictured = @import("strike.zig");
const _outline = @import("../outline/_outline.zig");
const LibraryBase = @import("../truetype_base.zig").TrueTypeBase;

const testing = std.testing;
const linux = std.os.linux;
const Rig = built.Rig;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;

comptime {
    // An outline's state lies in one page.
    std.debug.assert(@sizeOf(_outline.Font) <= std.heap.page_size_min);
}

/// Pages of the host's own, outside the memory exec has.
const Pages = struct {
    memory: []align(std.heap.page_size_min) u8,

    /// Pages that hold `bytes` and 0 after them, open to writes.
    fn holding(bytes: []const u8) !Pages {
        const length = std.mem.alignForward(usize, @max(bytes.len, 1), std.heap.pageSize());
        const memory = try std.posix.mmap(null, length, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        @memcpy(memory[0..bytes.len], bytes);
        return .{ .memory = memory };
    }

    /// No write reaches them from here on. That they are closed is
    /// asked of the kernel: told to put a byte there itself, it refuses,
    /// where a program's own write would end the program.
    fn close(pages: Pages) !void {
        if (linux.errno(linux.mprotect(pages.memory.ptr, pages.memory.len, .{ .READ = true })) != .SUCCESS) return error.NotClosed;
        var open: [1]u8 = undefined;
        if (linux.errno(linux.getrandom(&open, 1, 0)) != .SUCCESS) return error.NothingToAskWith;
        if (linux.errno(linux.getrandom(pages.memory.ptr, 1, 0)) != .FAULT) return error.NotClosed;
        if (linux.errno(linux.getrandom(pages.memory.ptr + pages.memory.len - 1, 1, 0)) != .FAULT) return error.NotClosed;
    }

    fn free(pages: Pages) void {
        std.posix.munmap(pages.memory);
    }
};

/// A font in pages closed to writes, opened into a page closed to them.
const Closed = struct {
    file: Pages,
    state: Pages,
    outline: *truetype.Outline,

    fn of(bytes: []const u8) !Closed {
        return with(bytes, null);
    }

    /// The same of a font whose pictures are unpacked by `packer`,
    /// compression.library opened: OpenOutline notes it in the outline.
    fn with(bytes: []const u8, packer: ?*sdk.exec.Library) !Closed {
        const file = try Pages.holding(bytes);
        errdefer file.free();
        const state = try Pages.holding(&.{});
        errdefer state.free();
        const font: *_outline.Font = @ptrCast(@alignCast(state.memory.ptr));
        if (!_outline.open(font, file.memory.ptr, @intCast(bytes.len), 0)) return error.NotRead;
        if (packer) |cb| font.compression = @ptrCast(@alignCast(cb));
        try file.close();
        try state.close();
        return .{ .file = file, .state = state, .outline = @ptrCast(font) };
    }

    fn free(closed: Closed) void {
        closed.state.free();
        closed.file.free();
    }
};

/// What the base holds, byte by byte.
fn baseOf(rig: *const Rig) []const u8 {
    return @as([*]const u8, @ptrCast(rig.library))[0..@sizeOf(LibraryBase)];
}

test "truetype: no call writes to an outline, to its font or to the base" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;
    var before: [@sizeOf(LibraryBase)]u8 = undefined;
    @memcpy(&before, baseOf(&rig));

    const M = vector.SEG_MOVE;
    const L = vector.SEG_LINE;
    const Q = vector.SEG_QUAD;
    const C = vector.SEG_CLOSE;
    var verbs: [16]u8 = undefined;
    var points: [16]vector.Point = undefined;
    var metrics: truetype.FontMetrics = .{};
    var glyph: truetype.GlyphMetrics = .{};
    var length: u32 = 0;
    var text: [32]u8 = undefined;
    const letters = [_]truetype.CodeRange{.{ .first = 'A', .last = 'Z' }};

    // A font with every table the library reads.
    var file: builder.File = .{};
    builder.whole(&file);
    const whole = try Closed.of(file.written());
    // Twice over: what one use left behind, the next would meet.
    for (0..2) |_| {
        const outline = whole.outline;
        tb.FontMetrics(outline, &metrics);
        try testing.expectEqual(@as(u32, 12), metrics.glyph_count);
        try testing.expectEqual(@as(u32, builder.units_per_em), metrics.units_per_em);
        try testing.expectEqual(@as(i32, builder.ascender), metrics.ascender);
        try testing.expectEqual(@as(i32, builder.descender), metrics.descender);
        try testing.expectEqual(@as(i32, builder.line_gap), metrics.line_gap);
        try testing.expectEqual(@as(i32, 480), metrics.x_height);
        try testing.expectEqual(@as(i32, 700), metrics.cap_height);
        try testing.expectEqual(@as(i32, -100), metrics.underline_position);
        try testing.expectEqual(@as(i32, 40), metrics.underline_thickness);
        try testing.expectEqual(@as(i32, 250), metrics.strikeout_position);
        try testing.expectEqual(@as(i32, 50), metrics.strikeout_thickness);
        try testing.expectEqual(@as(u32, 5 + 2 * 2), metrics.most_verbs);
        try testing.expectEqual(@as(u32, 2 * 5 + 2), metrics.most_points);

        try testing.expectEqual(@as(u32, 1), tb.GlyphIndex(outline, 'A'));
        try testing.expectEqual(@as(u32, 10), tb.GlyphIndex(outline, 'J'));
        try testing.expectEqual(@as(u32, 11), tb.GlyphIndex(outline, 0x1F600));
        try testing.expectEqual(@as(u32, 0), tb.GlyphIndex(outline, 'K'));
        try testing.expectEqual(@as(u32, 5), tb.GlyphVariant(outline, 'A', 0xFE00));
        try testing.expectEqual(@as(u32, 2), tb.GlyphVariant(outline, 'B', 0xFE00));
        try testing.expectEqual(@as(u32, 3), tb.GlyphVariant(outline, 'C', 0xFE00));
        try testing.expectEqual(@as(u32, 0), tb.GlyphVariant(outline, 'D', 0xFE00));
        try testing.expectEqual(@as(u32, 0), tb.GlyphVariant(outline, 'A', 0xFE0F));

        try testing.expectEqual(@as(u32, builder.whole_family.len), tb.FontName(outline, truetype.TTNAME_FAMILY, &text, text.len));
        try testing.expectEqualStrings(builder.whole_family, std.mem.sliceTo(&text, 0));
        try testing.expectEqual(@as(u32, builder.whole_style.len), tb.FontName(outline, truetype.TTNAME_STYLE, &text, 4));
        try testing.expectEqualStrings(builder.whole_style[0..3], std.mem.sliceTo(&text, 0));
        try testing.expectEqual(@as(u32, 0), tb.FontName(outline, truetype.TTNAME_FULL, &text, text.len));

        const kern = tb.FontTable(outline, truetype.tableTag("kern"), &length) orelse return error.NoTable;
        try testing.expectEqual(@as(u32, 4 + 14 + 2 * 6), length);
        try testing.expect(@intFromPtr(kern) > @intFromPtr(whole.file.memory.ptr));
        try testing.expect(@intFromPtr(kern) + length <= @intFromPtr(whole.file.memory.ptr) + file.len);
        try testing.expect(tb.FontTable(outline, truetype.tableTag("GSUB"), &length) == null);

        try testing.expect(tb.GlyphMetrics(outline, 11, &glyph));
        try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .x_max = 500, .y_max = 700 }, glyph);
        try testing.expect(!tb.GlyphMetrics(outline, 12, &glyph));
        var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 16, .point_room = 16 };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 11, &segments));
        try testing.expectEqualSlices(u8, &.{ M, L, L, L, C }, verbs[0..segments.verb_count]);
        try testing.expectEqual(vector.Point{ .x = 500, .y = 700 }, points[2]);
        try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.GlyphSegments(outline, 12, &segments));
        var short = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 2, .point_room = 16 };
        try testing.expectEqual(truetype.TRUETYPEERR_ROOM, tb.GlyphSegments(outline, 1, &short));

        try testing.expectEqual(@as(i32, -50), tb.Kerning(outline, 1, 2));
        try testing.expectEqual(@as(i32, 20), tb.Kerning(outline, 2, 3));
        try testing.expectEqual(@as(i32, 0), tb.Kerning(outline, 3, 2));

        const image = tb.RenderFontImage(outline, 20, &letters, letters.len) orelse return error.NoImage;
        try testing.expect(fontimage.sound(@ptrCast(image), image.size));
        try testing.expectEqual(@as(u32, 11), image.glyph_count);
        const j = fontimage.find(image, 'J') orelse return error.NoGlyph;
        try testing.expectEqual(@as(u16, 10), j.width);
        try testing.expectEqual(@as(u16, 14), j.rows);
        try testing.expect(fontimage.find(image, 'K') == null);
        // The glyph by its number: the image's, and the answers of a
        // room too short, a glyph the font lacks and a line of no rows.
        var pixels: [80]u8 = undefined;
        var by_number = truetype.GlyphImage{ .pixels = &pixels, .room = pixels.len };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, 10, 20, &by_number));
        try testing.expectEqual(@as(u32, 70), by_number.size);
        try testing.expectEqual(fontimage.Glyph{ .width = 10, .rows = 14, .top = j.top, .left = j.left, .advance = j.advance, .pitch = 5 }, by_number.glyph);
        try testing.expectEqualSlices(u8, fontimage.pixelsOf(image, j)[0..70], pixels[0..70]);
        by_number.room = 69;
        try testing.expectEqual(truetype.TRUETYPEERR_ROOM, tb.RenderGlyph(outline, 10, 20, &by_number));
        try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.RenderGlyph(outline, 12, 20, &by_number));
        try testing.expectEqual(truetype.TRUETYPEERR_ROWS, tb.RenderGlyph(outline, 10, 0, &by_number));
        sys.FreeVec(image);
        try testing.expect(tb.RenderFontImage(outline, 0, &letters, letters.len) == null);
    }
    whole.free();

    // One with a curve and a glyph put together of another.
    var out: built.Out = .{};
    built.buildFont(&out);
    const drawn = try Closed.of(out.bytes[0..out.len]);
    for (0..2) |_| {
        const outline = drawn.outline;
        try testing.expectEqual(@as(u32, 3), tb.GlyphIndex(outline, 'C'));
        try testing.expectEqual(@as(u32, 0), tb.GlyphVariant(outline, 'C', 0xFE00));
        try testing.expectEqual(@as(u32, 0), tb.FontName(outline, truetype.TTNAME_FAMILY, &text, text.len));
        try testing.expect(tb.GlyphMetrics(outline, 3, &glyph));
        try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .x_min = 100, .x_max = 600, .y_max = 700 }, glyph);
        var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 16, .point_room = 16 };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 2, &segments));
        try testing.expectEqualSlices(u8, &.{ M, L, Q, L, C }, verbs[0..segments.verb_count]);
        try testing.expectEqual(vector.Point{ .x = 250, .y = 800 }, points[2]);
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 3, &segments));
        try testing.expectEqual(vector.Point{ .x = 600, .y = 700 }, points[2]);
        try testing.expectEqual(@as(i32, -50), tb.Kerning(outline, 1, 2));
        const image = tb.RenderFontImage(outline, 20, &letters, letters.len) orelse return error.NoImage;
        try testing.expect(fontimage.sound(@ptrCast(image), image.size));
        const c = fontimage.find(image, 'C') orelse return error.NoGlyph;
        try testing.expectEqual(@as(i16, 2), c.left);
        try testing.expectEqual(@as(u16, 10), c.width);
        // The curve and the composite by their numbers.
        var pixels: [80]u8 = undefined;
        for ([_]u32{ 2, 3 }) |number| {
            const in_image = fontimage.find(image, 'A' + number - 1) orelse return error.NoGlyph;
            var by_number = truetype.GlyphImage{ .pixels = &pixels, .room = pixels.len };
            try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, number, 20, &by_number));
            try testing.expectEqual(in_image.left, by_number.glyph.left);
            try testing.expectEqual(in_image.top, by_number.glyph.top);
            try testing.expectEqualSlices(u8, fontimage.pixelsOf(image, in_image)[0..by_number.size], pixels[0..by_number.size]);
        }
        sys.FreeVec(image);
    }
    drawn.free();

    try testing.expectEqualSlices(u8, &before, baseOf(&rig));
    try rig.down();
}

test "truetype: no call writes to a font of cubic outlines or its outline" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;
    var before: [@sizeOf(LibraryBase)]u8 = undefined;
    @memcpy(&before, baseOf(&rig));

    // A square, and a glyph of a line and a curve drawn by subroutines,
    // a local one that calls a global one; the font names a largest
    // glyph smaller than the second, which is so read twice.
    var file: builder.File = .{};
    cubic.build(&file, .{
        .glyphs = &.{
            builder.program("endchar"),
            builder.program("0 0 rmoveto 500 hlineto 700 vlineto -500 hlineto endchar"),
            builder.program("10 20 hstemhm 30 40 vstemhm hintmask #C0 100 100 rmoveto -107 callsubr 0 300 rlineto endchar"),
        },
        .locals = &.{builder.program("300 0 rlineto -107 callgsubr return")},
        .globals = &.{builder.program("100 50 50 100 0 150 rrcurveto return")},
    }, true);
    const closed = try Closed.of(file.written());
    const outline = closed.outline;
    const M = vector.SEG_MOVE;
    const L = vector.SEG_LINE;
    const C = vector.SEG_CUBIC;
    const Z = vector.SEG_CLOSE;
    var verbs: [16]u8 = undefined;
    var points: [16]vector.Point = undefined;
    var metrics: truetype.FontMetrics = .{};
    var glyph: truetype.GlyphMetrics = .{};
    const letters = [_]truetype.CodeRange{.{ .first = 'A', .last = 'Z' }};
    // Twice over: what one use left behind, the next would meet.
    for (0..2) |_| {
        tb.FontMetrics(outline, &metrics);
        try testing.expectEqual(@as(u32, 3), metrics.glyph_count);
        try testing.expectEqual(@as(u32, 1), tb.GlyphIndex(outline, 'A'));
        var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = verbs.len, .point_room = points.len };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 1, &segments));
        try testing.expectEqualSlices(u8, &.{ M, L, L, L, Z }, verbs[0..segments.verb_count]);
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 2, &segments));
        try testing.expectEqualSlices(u8, &.{ M, L, C, L, Z }, verbs[0..segments.verb_count]);
        try testing.expectEqual(vector.Point{ .x = 550, .y = 400 }, points[4]);
        try testing.expectEqual(vector.Point{ .x = 550, .y = 700 }, points[5]);
        try testing.expect(tb.GlyphMetrics(outline, 2, &glyph));
        try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .left_bearing = 0, .x_min = 100, .y_min = 100, .x_max = 550, .y_max = 700 }, glyph);
        var pixels: [256]u8 = undefined;
        var by_number = truetype.GlyphImage{ .pixels = &pixels, .room = pixels.len };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, 2, 20, &by_number));
        try testing.expectEqual(@as(u16, 9), by_number.glyph.width);
        try testing.expectEqual(@as(u16, 12), by_number.glyph.rows);
        const image = tb.RenderFontImage(outline, 20, &letters, letters.len) orelse return error.NoImage;
        try testing.expect(fontimage.sound(@ptrCast(image), image.size));
        const a = fontimage.find(image, 'A') orelse return error.NoGlyph;
        try testing.expectEqual(@as(u16, 10), a.width);
        try testing.expectEqual(@as(u16, 14), a.rows);
        sys.FreeVec(image);
    }
    closed.free();

    try testing.expectEqualSlices(u8, &before, baseOf(&rig));
    try rig.down();
}

test "truetype: no call writes to a font of pictures or its outline" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;
    var before: [@sizeOf(LibraryBase)]u8 = undefined;
    @memcpy(&before, baseOf(&rig));

    // Pictures of coverage in two strikes, some put together of other
    // glyphs; and pictures of colour, PNG files, one of them damaged.
    var coverage: builder.File = .{};
    pictured.formsFont(&coverage);
    var colour: builder.File = .{};
    pictured.colourFont(&colour);
    const packer = sys.OpenLibrary(sdk.compression.COMPRESSIONNAME, 1) orelse return error.NoCompression;
    const fonts = [_]Closed{ try Closed.of(coverage.written()), try Closed.with(colour.written(), packer) };
    const kinds = [_]fontimage.Kind{ .alpha4, .rgba32 };
    const letters = [_]truetype.CodeRange{.{ .first = 'A', .last = 'G' }};
    var verbs: [16]u8 = undefined;
    var points: [16]vector.Point = undefined;
    var measures: truetype.GlyphMetrics = .{};
    var pixels: [256]u8 = undefined;
    // Twice over: what one use left behind, the next would meet.
    for (0..2) |_| {
        for (fonts, kinds) |closed, kind| {
            const outline = closed.outline;
            const image = tb.RenderFontImage(outline, 20, &letters, letters.len) orelse return error.NoImage;
            try testing.expect(fontimage.sound(@ptrCast(image), image.size));
            try testing.expectEqual(kind, image.kind);
            var glyph: u32 = 1;
            while (glyph <= 7) : (glyph += 1) {
                try testing.expectEqual(glyph, tb.GlyphIndex(outline, 'A' + glyph - 1));
                // A picture is no outline: no verb, no point.
                var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = verbs.len, .point_room = points.len };
                try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, glyph, &segments));
                try testing.expectEqual(@as(u32, 0), segments.verb_count);
                try testing.expect(tb.GlyphMetrics(outline, glyph, &measures));
                try testing.expectEqual(@as(i32, 600), measures.advance);
                // Its glyph by number is the image's, at its size and
                // scaled.
                var by_number = truetype.GlyphImage{ .pixels = &pixels, .room = pixels.len };
                try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, glyph, 20, &by_number));
                try testing.expectEqual(kind, by_number.kind);
                const in_image = fontimage.find(image, 'A' + glyph - 1) orelse return error.NoGlyph;
                try testing.expectEqual(@as(u32, in_image.pitch) * in_image.rows, by_number.size);
                try testing.expectEqualSlices(u8, fontimage.pixelsOf(image, in_image)[0..by_number.size], pixels[0..by_number.size]);
                try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, glyph, 7, &by_number));
            }
            sys.FreeVec(image);
        }
    }
    for (fonts) |closed| closed.free();
    sys.CloseLibrary(packer);

    try testing.expectEqualSlices(u8, &before, baseOf(&rig));
    try rig.down();
}

/// Every call made on the fetched font `expected` is of, which is held
/// in memory that may only be read.
fn expectFetchedUntouched(expected: *const reference.Font) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const bytes = try reference.read(expected);
    defer testing.allocator.free(bytes);

    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;
    var before: [@sizeOf(LibraryBase)]u8 = undefined;
    @memcpy(&before, baseOf(&rig));

    const closed = try Closed.of(bytes);
    const outline = closed.outline;
    var metrics: truetype.FontMetrics = .{};
    tb.FontMetrics(outline, &metrics);
    try testing.expectEqual(expected.glyph_count, metrics.glyph_count);
    const verbs = try testing.allocator.alloc(u8, metrics.most_verbs);
    defer testing.allocator.free(verbs);
    const points = try testing.allocator.alloc(vector.Point, metrics.most_points);
    defer testing.allocator.free(points);

    // The characters and names written out for it, every glyph's outline
    // and measures, each neighbouring pair's kerning.
    for (expected.pairs) |pair| try testing.expectEqual(pair.glyph, tb.GlyphIndex(outline, pair.code));
    try testing.expectEqual(@as(u32, 0), tb.GlyphVariant(outline, 'A', 0xFE00));
    var text: [64]u8 = undefined;
    for (expected.names) |name| try testing.expectEqual(@as(u32, @intCast(name.text.len)), tb.FontName(outline, name.id, &text, text.len));
    var length: u32 = 0;
    for (expected.tables) |entry| {
        const table = tb.FontTable(outline, truetype.tableTag(entry.tag), &length) orelse return error.NoTable;
        try testing.expectEqual(@intFromPtr(closed.file.memory.ptr) + entry.at, @intFromPtr(table));
    }
    var glyph: u32 = 0;
    var measures: truetype.GlyphMetrics = .{};
    while (glyph < expected.glyph_count) : (glyph += 1) {
        var segments = truetype.Segments{ .verbs = verbs.ptr, .points = points.ptr, .verb_room = metrics.most_verbs, .point_room = metrics.most_points };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, glyph, &segments));
        try testing.expect(tb.GlyphMetrics(outline, glyph, &measures));
        _ = tb.Kerning(outline, glyph, glyph + 1);
    }
    // Rendered at two sizes, the second while the first is still held.
    const ranges = [_]truetype.CodeRange{ .{ .first = 0x20, .last = 0x7E }, .{ .first = 0xA0, .last = 0x24F } };
    const small = tb.RenderFontImage(outline, 12, &ranges, ranges.len) orelse return error.NoImage;
    const large = tb.RenderFontImage(outline, 40, &ranges, ranges.len) orelse return error.NoImage;
    try testing.expect(fontimage.sound(@ptrCast(small), small.size));
    try testing.expect(fontimage.sound(@ptrCast(large), large.size));
    try testing.expectEqual(small.glyph_count, large.glyph_count);
    try testing.expect(fontimage.find(large, 0xE9) != null);
    // Every glyph by its number, while both images are held; the one of
    // a character is the small image's.
    const pixels = try testing.allocator.alloc(u8, 16 * 1024);
    defer testing.allocator.free(pixels);
    glyph = 0;
    while (glyph < expected.glyph_count) : (glyph += 1) {
        var by_number = truetype.GlyphImage{ .pixels = pixels.ptr, .room = @intCast(pixels.len) };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, glyph, 12, &by_number));
    }
    const e_acute = fontimage.find(small, 0xE9) orelse return error.NoGlyph;
    var by_number = truetype.GlyphImage{ .pixels = pixels.ptr, .room = @intCast(pixels.len) };
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, tb.GlyphIndex(outline, 0xE9), 12, &by_number));
    try testing.expectEqual(@as(u32, e_acute.pitch) * e_acute.rows, by_number.size);
    try testing.expectEqualSlices(u8, fontimage.pixelsOf(small, e_acute)[0..by_number.size], pixels[0..by_number.size]);
    sys.FreeVec(small);
    sys.FreeVec(large);
    closed.free();

    try testing.expectEqualSlices(u8, &before, baseOf(&rig));
    try rig.down();
}

test "truetype: no call writes to a fetched font or its outline" {
    try expectFetchedUntouched(reference.liberation_sans_regular);
}

test "truetype: no call writes to a fetched font of cubic outlines or its outline" {
    try expectFetchedUntouched(reference.source_sans_3_regular);
}

test "truetype: no call writes to a fetched font of pictures or its outline" {
    try expectFetchedUntouched(reference.spleen_8x16);
}

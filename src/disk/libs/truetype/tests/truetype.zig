// SPDX-License-Identifier: MIT
//! Host tests of truetype.library: the library made from its ROM tag on
//! the ROM's exec, a small TrueType file built by the test, and the images
//! rendered from it checked pixel by pixel.

const std = @import("std");
const sdk = @import("sdk");
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const truetype = sdk.truetype;
const host = @import("host_rom");
const kexec = host.exec;
const truetype_init = @import("../truetype_init.zig");

const testing = std.testing;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;

test {
    _ = @import("../truetype_lvo.zig");
    _ = @import("../glyph/_segments.zig");
}

/// Memory lent to exec: a font of many glyphs rendered takes more than
/// the ROM's test memory has.
var lent: [32 * 1024 * 1024]u8 align(16) = undefined;

/// The ROM's exec and utility.library up, and truetype.library made from
/// its ROM tag and opened.
pub const Rig = struct {
    sys: *sdk.interface.exec.ExecBase,
    region: *sdk.exec.MemHeader,
    ub: *host.utility.UtilityBase,
    library: *sdk.exec.Library,
    tb: *TrueTypeBase,

    pub fn up() !Rig {
        const ub = try host.utility.setUp();
        const sys = kexec.SysBase.iface();
        const region = sys.AddMemList(lent.len, sdk.exec.MEMF_ANY, 0, &lent, "lent").?;
        const made = kexec.InitResident(kexec.SysBase, &truetype_init.truetype_library_tag, null) orelse return error.NoLibrary;
        return .{
            .sys = sys,
            .region = region,
            .ub = ub,
            .library = @ptrCast(@alignCast(made)),
            .tb = @ptrCast(sys.OpenLibrary(truetype.TRUETYPENAME, 1) orelse return error.NoBase),
        };
    }

    /// The library closed and expunged, utility.library taken down, and
    /// nothing of what the test made left behind.
    pub fn down(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.tb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        try host.utility.tearDown(rig.ub);
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        rig.sys.Remove(&rig.region.node);
        kexec.deinit();
    }
};

/// A file being written, big-endian.
pub const Out = struct {
    bytes: [2048]u8 = @splat(0),
    len: u32 = 0,

    fn u16be(out: *Out, v: u16) void {
        out.bytes[out.len] = @truncate(v >> 8);
        out.bytes[out.len + 1] = @truncate(v);
        out.len += 2;
    }
    fn i16be(out: *Out, v: i16) void {
        out.u16be(@bitCast(v));
    }
    fn u32be(out: *Out, v: u32) void {
        out.u16be(@truncate(v >> 16));
        out.u16be(@truncate(v));
    }
    fn at(out: *Out, where: u32, v: u32) void {
        out.bytes[where] = @truncate(v >> 24);
        out.bytes[where + 1] = @truncate(v >> 16);
        out.bytes[where + 2] = @truncate(v >> 8);
        out.bytes[where + 3] = @truncate(v);
    }
    fn pad(out: *Out) void {
        while (out.len % 4 != 0) out.len += 1;
    }
};

/// A font of 1000 units, ascender 800, descender -200: glyph 0 empty (the
/// missing glyph), 1 'A' a square 0..500 by 0..700, 2 'B' a square with a
/// curved top, 3 'C' glyph 1 moved 100 right. Advances 600. Kerned: 'A'
/// then 'B' 50 closer, 'B' then 'C' 20 further.
pub fn buildFont(out: *Out) void {
    buildFace(out, 0);
}

/// The same font saying it is drawn in `style_bits`, its `head` table's
/// style bits: 1 bold, 2 italic.
pub fn buildFace(out: *Out, style_bits: u8) void {
    buildFaceAt(out, style_bits, 'A');
}

/// The same font with its three glyphs at `first` and the two characters
/// after it, in place of 'A' to 'C'.
pub fn buildFaceAt(out: *Out, style_bits: u8, first: u16) void {
    const tags = [_]*const [4]u8{ "cmap", "glyf", "head", "hhea", "hmtx", "kern", "loca", "maxp" };
    out.u32be(0x0001_0000);
    out.u16be(tags.len);
    out.u16be(0);
    out.u16be(0);
    out.u16be(0);
    const directory = out.len;
    out.len += tags.len * 16;
    var starts: [tags.len]u32 = undefined;
    var ends: [tags.len]u32 = undefined;

    // cmap: one Unicode subtable, format 4: `first` and the two after it
    // -> 1..3, and the end.
    starts[0] = out.len;
    out.u16be(0);
    out.u16be(1);
    out.u16be(3);
    out.u16be(1);
    out.u32be(12);
    out.u16be(4); // format
    out.u16be(32); // length
    out.u16be(0);
    out.u16be(4); // segCountX2
    out.u16be(4);
    out.u16be(1);
    out.u16be(0);
    out.u16be(first + 2); // end codes
    out.u16be(0xFFFF);
    out.u16be(0);
    out.u16be(first); // start codes
    out.u16be(0xFFFF);
    out.u16be(1 -% first); // deltas
    out.u16be(1);
    out.u16be(0); // range offsets
    out.u16be(0);
    ends[0] = out.len;
    out.pad();

    // glyf: 1 and 2 simple, 3 composite; glyph 0 has no data.
    starts[1] = out.len;
    var loca: [5]u32 = undefined;
    loca[0] = 0;
    loca[1] = 0;
    // The square: four points on the curve, words for every coordinate.
    out.i16be(1);
    out.i16be(0);
    out.i16be(0);
    out.i16be(500);
    out.i16be(700);
    out.u16be(3); // end point
    out.u16be(0); // instructions
    for (0..4) |i| out.bytes[out.len + i] = 1;
    out.len += 4;
    for ([_]i16{ 0, 0, 500, 0 }) |dx| out.i16be(dx);
    for ([_]i16{ 0, 700, 0, -700 }) |dy| out.i16be(dy);
    out.pad();
    loca[2] = out.len - starts[1];
    // The curved one: (0,0) (0,500) off (250,800) (500,500) (500,0).
    out.i16be(1);
    out.i16be(0);
    out.i16be(0);
    out.i16be(500);
    out.i16be(800);
    out.u16be(4);
    out.u16be(0);
    for ([_]u8{ 1, 1, 0, 1, 1 }) |f| {
        out.bytes[out.len] = f;
        out.len += 1;
    }
    for ([_]i16{ 0, 0, 250, 250, 0 }) |dx| out.i16be(dx);
    for ([_]i16{ 0, 500, 300, -300, -500 }) |dy| out.i16be(dy);
    out.pad();
    loca[3] = out.len - starts[1];
    // The composite: glyph 1, words, x/y values, 100 right.
    out.i16be(-1);
    out.i16be(100);
    out.i16be(0);
    out.i16be(600);
    out.i16be(700);
    out.u16be(0x0003);
    out.u16be(1);
    out.i16be(100);
    out.i16be(0);
    out.pad();
    loca[4] = out.len - starts[1];
    ends[1] = out.len;

    // head: units per em 1000, long offsets.
    starts[2] = out.len;
    out.len += 54;
    out.bytes[starts[2] + 18] = 1000 >> 8;
    out.bytes[starts[2] + 19] = 1000 & 0xFF;
    out.bytes[starts[2] + 45] = style_bits;
    out.bytes[starts[2] + 51] = 1;
    ends[2] = out.len;
    out.pad();

    // hhea: ascender 800, descender -200, one metric.
    starts[3] = out.len;
    out.len += 36;
    out.bytes[starts[3] + 4] = 800 >> 8;
    out.bytes[starts[3] + 5] = 800 & 0xFF;
    const descender: u16 = @bitCast(@as(i16, -200));
    out.bytes[starts[3] + 6] = @truncate(descender >> 8);
    out.bytes[starts[3] + 7] = @truncate(descender);
    out.bytes[starts[3] + 35] = 1;
    ends[3] = out.len;
    out.pad();

    // hmtx: every glyph 600 wide.
    starts[4] = out.len;
    out.u16be(600);
    out.i16be(0);
    ends[4] = out.len;
    out.pad();

    // kern: version 0, one horizontal subtable of format 0, two pairs.
    starts[5] = out.len;
    out.u16be(0);
    out.u16be(1);
    out.u16be(0);
    out.u16be(14 + 2 * 6);
    out.u16be(0x0001);
    out.u16be(2);
    out.u16be(12);
    out.u16be(1);
    out.u16be(0);
    out.u16be(1);
    out.u16be(2);
    out.i16be(-50);
    out.u16be(2);
    out.u16be(3);
    out.i16be(20);
    ends[5] = out.len;
    out.pad();

    // loca, long.
    starts[6] = out.len;
    for (loca) |offset| out.u32be(offset);
    ends[6] = out.len;

    // maxp: four glyphs.
    starts[7] = out.len;
    out.u32be(0x0000_5000);
    out.u16be(4);
    ends[7] = out.len;
    out.pad();

    for (tags, 0..) |tag, i| {
        const record = directory + @as(u32, @intCast(i)) * 16;
        for (0..4) |k| out.bytes[record + k] = tag[k];
        out.at(record + 8, starts[i]);
        out.at(record + 12, ends[i] - starts[i]);
    }
}

test "a TrueType file rendered: squares full, a curve smooth, a composite moved, the missing glyph as default" {
    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;

    var out: Out = .{};
    buildFont(&out);
    try testing.expect(tb.OpenOutline(&out.bytes, 8, null) == null);
    const outline = tb.OpenOutline(&out.bytes, out.len, null) orelse return error.NotRead;

    // Ranges out of order, or past the last code point: refused.
    const backwards = [_]truetype.CodeRange{ .{ .first = 'B', .last = 'C' }, .{ .first = 'A', .last = 'A' } };
    try testing.expect(tb.RenderFontImage(outline, 20, &backwards, backwards.len) == null);
    const past = [_]truetype.CodeRange{.{ .first = 0x10FFFF, .last = 0x110000 }};
    try testing.expect(tb.RenderFontImage(outline, 20, &past, past.len) == null);

    // 20 rows: 1000 units to 20 pixels, 0.02 a unit; the baseline 16 down.
    const printable = [_]truetype.CodeRange{ .{ .first = 32, .last = 126 }, .{ .first = 0x100, .last = 0x17F } };
    const image = tb.RenderFontImage(outline, 20, &printable, printable.len) orelse return error.NoImage;
    const block: [*]const u8 = @ptrCast(image);
    try testing.expect(fontimage.check(block, image.size));
    try testing.expect(fontimage.sound(block, image.size));
    try testing.expectEqual(@as(u16, 20), image.height);
    try testing.expectEqual(@as(u16, 16), image.baseline);
    try testing.expectEqual(fontimage.Kind.alpha4, image.kind);
    try testing.expectEqual(fontimage.MISSING, image.default_char);
    try testing.expectEqual(graphics.FS_NORMAL, image.style);

    // 'A': 10 by 14 pixels, two down from the top, every pixel covered.
    const a = fontimage.find(image, 'A').?;
    try testing.expectEqual(@as(u16, 10), a.width);
    try testing.expectEqual(@as(u16, 14), a.rows);
    try testing.expectEqual(@as(i16, 2), a.top);
    try testing.expectEqual(@as(i16, 0), a.left);
    try testing.expectEqual(@as(i16, 12), a.advance);
    const pixels = fontimage.pixelsOf(image, a);
    for (0..a.rows) |y| for (0..5) |x| try testing.expectEqual(@as(u8, 0xFF), pixels[y * a.pitch + x]);

    // 'B': full at the bottom, partly covered along the curve at the top.
    const b = fontimage.find(image, 'B').?;
    const bp = fontimage.pixelsOf(image, b);
    try testing.expectEqual(@as(u8, 0xFF), bp[(b.rows - 1) * b.pitch + 2]);
    var partial = false;
    for (0..@as(usize, b.pitch) * b.rows) |i| {
        const v = bp[i];
        if (v >> 4 != 0 and v >> 4 != 15) partial = true;
    }
    try testing.expect(partial);
    // Cropped to the ink: the curve's top at 650 units, 3 rows down.
    try testing.expectEqual(@as(i16, 3), b.top);

    // 'C' is 'A' two pixels further right.
    const c = fontimage.find(image, 'C').?;
    try testing.expectEqual(@as(i16, 2), c.left);
    try testing.expectEqual(a.width, c.width);

    // Only what the font has is in the image: 'A' to 'C' in one range,
    // and the missing glyph, the default, which is empty here. A code the
    // font lacks is drawn as that, or a letter with marks as its base
    // letter: Ā as A.
    try testing.expectEqual(@as(u32, 2), image.range_count);
    try testing.expectEqual(@as(u32, 4), image.glyph_count);
    try testing.expect(fontimage.find(image, 'z') == null);
    try testing.expectEqual(@as(u16, 0), fontimage.glyphFor(image, 'z').width);
    try testing.expectEqual(@as(u16, 0), fontimage.glyphFor(image, 300).width);
    try testing.expectEqual(a, fontimage.glyphFor(image, 0x100));

    sys.FreeVec(image);
    tb.CloseOutline(outline);
    try rig.down();
}

test "a face says what it is: its styles read from the file, and every size rendered in them" {
    var out: Out = .{};
    buildFace(&out, 1);
    try testing.expectEqual(graphics.FSF_BOLD, truetype.styleOf(out.bytes[0..out.len]));
    out = .{};
    buildFace(&out, 3);
    try testing.expectEqual(graphics.FSF_BOLD | graphics.FSF_ITALIC, truetype.styleOf(out.bytes[0..out.len]));
    // Cut before its head table, or not TrueType at all: no styles.
    try testing.expectEqual(graphics.FS_NORMAL, truetype.styleOf(out.bytes[0..40]));
    try testing.expectEqual(graphics.FS_NORMAL, truetype.styleOf("FONT and more bytes"));

    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;
    out = .{};
    buildFace(&out, 1);
    const outline = tb.OpenOutline(&out.bytes, out.len, null) orelse return error.NotRead;
    const ascii = [_]truetype.CodeRange{.{ .first = 32, .last = 126 }};
    const image = tb.RenderFontImage(outline, 20, &ascii, ascii.len) orelse return error.NoImage;
    try testing.expectEqual(graphics.FSF_BOLD, image.style);
    const block: [*]const u8 = @ptrCast(image);
    try testing.expect(fontimage.sound(block, image.size));

    sys.FreeVec(image);
    tb.CloseOutline(outline);
    try rig.down();
}

test "revision 2: glyphs by character, as outlines in the font's units, their measures, the font's, a kerned pair" {
    var rig = try Rig.up();
    const tb = rig.tb;
    try testing.expect(tb.lib().revision >= 2);

    var out: Out = .{};
    buildFont(&out);
    const outline = tb.OpenOutline(&out.bytes, out.len, null) orelse return error.NotRead;

    try testing.expectEqual(@as(u32, 1), tb.GlyphIndex(outline, 'A'));
    try testing.expectEqual(@as(u32, 3), tb.GlyphIndex(outline, 'C'));
    try testing.expectEqual(@as(u32, 0), tb.GlyphIndex(outline, 'z'));
    try testing.expectEqual(@as(u32, 0), tb.GlyphIndex(outline, 0x1F600));

    var fm: truetype.FontMetrics = .{};
    tb.FontMetrics(outline, &fm);
    try testing.expectEqual(@as(u32, 1000), fm.units_per_em);
    try testing.expectEqual(@as(u32, 4), fm.glyph_count);
    try testing.expectEqual(@as(i32, 800), fm.ascender);
    try testing.expectEqual(@as(i32, -200), fm.descender);
    // No maxp 1.0, OS/2 or post: room as for the default glyph, no lines.
    try testing.expectEqual(@as(u32, 1025 + 2 * 129), fm.most_verbs);
    try testing.expectEqual(@as(u32, 2 * 1025 + 129), fm.most_points);
    try testing.expectEqual(@as(i32, 0), fm.x_height);

    var gm: truetype.GlyphMetrics = .{};
    try testing.expect(tb.GlyphMetrics(outline, 3, &gm));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .x_min = 100, .x_max = 600, .y_max = 700 }, gm);
    try testing.expect(tb.GlyphMetrics(outline, 0, &gm));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600 }, gm);
    try testing.expect(!tb.GlyphMetrics(outline, 4, &gm));

    var verbs: [16]u8 = undefined;
    var points: [16]sdk.vector.Point = undefined;
    var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 16, .point_room = 16 };
    const M = sdk.vector.SEG_MOVE;
    const L = sdk.vector.SEG_LINE;
    const Q = sdk.vector.SEG_QUAD;
    const C = sdk.vector.SEG_CLOSE;
    // The square, y up as the font has it.
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 1, &segments));
    try testing.expectEqualSlices(u8, &.{ M, L, L, L, C }, verbs[0..segments.verb_count]);
    try testing.expectEqual(sdk.vector.Point{ .x = 0, .y = 700 }, points[1]);
    // The curved one: a line up, the curve over, a line down.
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 2, &segments));
    try testing.expectEqualSlices(u8, &.{ M, L, Q, L, C }, verbs[0..segments.verb_count]);
    try testing.expectEqual(sdk.vector.Point{ .x = 250, .y = 800 }, points[2]);
    // The composite: the square 100 to the right.
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 3, &segments));
    try testing.expectEqual(@as(u32, 5), segments.verb_count);
    try testing.expectEqual(sdk.vector.Point{ .x = 100, .y = 0 }, points[0]);
    try testing.expectEqual(sdk.vector.Point{ .x = 600, .y = 700 }, points[2]);
    // No outline, no glyph, no room.
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 0, &segments));
    try testing.expectEqual(@as(u32, 0), segments.verb_count);
    try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.GlyphSegments(outline, 9, &segments));
    var short = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 3, .point_room = 16 };
    try testing.expectEqual(truetype.TRUETYPEERR_ROOM, tb.GlyphSegments(outline, 1, &short));
    try testing.expectEqual(@as(u32, 5), short.verb_count);
    try testing.expectEqual(@as(u32, 4), short.point_count);

    try testing.expectEqual(@as(i32, -50), tb.Kerning(outline, 1, 2));
    try testing.expectEqual(@as(i32, 20), tb.Kerning(outline, 2, 3));
    try testing.expectEqual(@as(i32, 0), tb.Kerning(outline, 2, 1));
    try testing.expectEqual(@as(i32, 0), tb.Kerning(outline, 0x10000, 1));

    tb.CloseOutline(outline);
    try rig.down();
}

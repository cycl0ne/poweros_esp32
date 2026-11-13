// SPDX-License-Identifier: MIT
//! Host tests of what truetype.library reads of a font beside its
//! glyphs, on tables the tests build: the character map in each of its
//! formats, the variation sequences, which of several maps is read, the
//! fonts of a collection, the names, and a table handed out as it is.
//!
//! Each test writes a file that is sound in everything but the table it
//! is about (`builder.zig`), opens it through the library's jump table,
//! and compares what the calls answer with what the test wrote. What a
//! real font's tables say is `fonts.zig`'s.

const std = @import("std");
const sdk = @import("sdk");
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const truetype = sdk.truetype;
const utility = sdk.utility;
const builder = @import("builder.zig");
const Rig = @import("truetype.zig").Rig;

const testing = std.testing;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;

/// A font of `glyphs` glyphs with the character map `cmap`, alone in
/// `file`.
fn fontOf(file: *builder.File, cmap: *const builder.Cmap, glyphs: u16) void {
    file.* = .{};
    _ = builder.font(file, .{ .cmap = cmap.written(), .glyphs = glyphs });
}

/// What is added to a character of a format 4 segment for its glyph, as
/// the 16 bits the map stores.
fn delta(comptime difference: i32) u16 {
    return @truncate(@as(u32, @bitCast(difference)));
}

/// Each character of `wants` is the glyph beside it.
fn expectGlyphs(tb: *TrueTypeBase, outline: *truetype.Outline, wants: []const [2]u32) !void {
    for (wants) |want| {
        const glyph = tb.GlyphIndex(outline, want[0]);
        if (glyph == want[1]) continue;
        std.debug.print("U+{X:0>4} is glyph {d}, not {d}\n", .{ want[0], glyph, want[1] });
        return error.WrongGlyph;
    }
}

/// Each character and selector of `wants` are drawn with the glyph
/// beside them.
fn expectVariants(tb: *TrueTypeBase, outline: *truetype.Outline, wants: []const [3]u32) !void {
    for (wants) |want| {
        const glyph = tb.GlyphVariant(outline, want[0], want[1]);
        if (glyph == want[2]) continue;
        std.debug.print("U+{X:0>4} U+{X:0>4} is glyph {d}, not {d}\n", .{ want[0], want[1], glyph, want[2] });
        return error.WrongGlyph;
    }
}

/// A subtable of `format` that says 'A' is `glyph` and nothing else, at
/// the end of `cmap`; of a format the library does not read, its number
/// and bytes of 0.
fn letter(cmap: *builder.Cmap, format: u16, glyph: u16) void {
    switch (format) {
        0 => {
            var glyphs: [256]u8 = @splat(0);
            glyphs['A'] = @intCast(glyph);
            cmap.bytes(&glyphs);
        },
        4 => cmap.segments(&.{
            .{ .first = 'A', .last = 'A', .delta = glyph -% 'A' },
            .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
        }),
        6 => cmap.run('A', &.{glyph}),
        10 => cmap.longRun('A', &.{glyph}),
        12, 13 => cmap.groups(format, &.{.{ .first = 'A', .last = 'A', .glyph = glyph }}),
        2 => bytesOfTwo(cmap, &.{.{ .first = 'A', .glyphs = &.{glyph} }}, &.{}),
        8 => mixed(cmap, &.{.{ .first = 'A', .last = 'A', .glyph = glyph }}),
        else => {
            cmap.file.word(format);
            cmap.file.skip(30);
        },
    }
}

/// A run of second bytes behind one first byte - or, for format 2's
/// subheader 0, of the characters of one byte - and their glyphs.
const ByteRun = struct { high: u8 = 0, first: u8, glyphs: []const u16, delta: u16 = 0 };

/// Format 2: `single` is the run of the characters of one byte, `double`
/// the runs of second bytes, a first byte each.
fn bytesOfTwo(cmap: *builder.Cmap, single: []const ByteRun, double: []const ByteRun) void {
    const file = &cmap.file;
    const start = file.len;
    file.word(2);
    file.word(0);
    file.word(0);
    // The first bytes' subheaders, 8 bytes each from the one of single
    // bytes on.
    var keys: [256]u16 = @splat(0);
    for (double, 1..) |run, index| keys[run.high] = @intCast(index * 8);
    for (keys) |key| file.word(key);
    const runs = 1 + double.len;
    const headers = file.len;
    file.skip(@intCast(runs * 8));
    var number: u32 = 0;
    const none = [_]ByteRun{.{ .first = 0, .glyphs = &.{} }};
    for ([_][]const ByteRun{ if (single.len != 0) single[0..1] else &none, double }) |list| {
        for (list) |run| {
            const header = headers + number * 8;
            file.setWord(header, run.first);
            file.setWord(header + 2, @intCast(run.glyphs.len));
            file.setWord(header + 4, run.delta);
            file.setWord(header + 6, @intCast(file.len - (header + 6)));
            for (run.glyphs) |glyph| file.word(glyph);
            number += 1;
        }
    }
    file.setWord(start + 2, @intCast(file.len - start));
}

/// Format 8: groups as format 12's, behind the bits that say which
/// characters are 32 bits wide.
fn mixed(cmap: *builder.Cmap, list: []const builder.Group) void {
    const file = &cmap.file;
    file.word(8);
    file.word(0);
    file.long(@intCast(16 + 8192 + list.len * 12));
    file.long(0);
    file.skip(8192);
    file.long(@intCast(list.len));
    for (list) |group| {
        file.long(group.first);
        file.long(group.last);
        file.long(group.glyph);
    }
}

/// One subtable of a map that says what 'A' is.
const Map = struct {
    platform: u16,
    encoding: u16,
    format: u16,
    glyph: u16,
};

/// What a font whose character map has `maps` says 'A' is; null when it
/// is not opened.
fn letterOf(tb: *TrueTypeBase, maps: []const Map) ?u32 {
    var cmap = builder.Cmap.init(@intCast(maps.len));
    for (maps) |map| {
        cmap.begin(map.platform, map.encoding);
        letter(&cmap, map.format, map.glyph);
    }
    var file: builder.File = .{};
    fontOf(&file, &cmap, 8);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return null;
    defer tb.CloseOutline(outline);
    return tb.GlyphIndex(outline, 'A');
}

/// The file's font `index`, opened by its number.
fn openFont(tb: *TrueTypeBase, bytes: []const u8, index: usize) ?*truetype.Outline {
    const tags = [_]utility.TagItem{
        .{ .tag = truetype.TTA_FontIndex, .data = index },
        .{ .tag = utility.TAG_DONE, .data = 0 },
    };
    return tb.OpenOutline(bytes.ptr, @intCast(bytes.len), &tags);
}

/// Where in `bytes` the record of the table `tag` is, in the directory
/// at `directory`.
fn recordOf(bytes: []const u8, directory: u32, tag: *const [4]u8) !u32 {
    const count = std.mem.readInt(u16, bytes[directory + 4 ..][0..2], .big);
    for (0..count) |i| {
        const record = directory + 12 + @as(u32, @intCast(i)) * 16;
        if (std.mem.eql(u8, bytes[record..][0..4], tag)) return record;
    }
    return error.NoSuchTable;
}

/// The font's name `id` is `text`, read into a buffer with room to
/// spare; the empty string for a name it does not have.
fn expectName(tb: *TrueTypeBase, outline: *truetype.Outline, id: u32, text: []const u8) !void {
    var buffer: [128]u8 = @splat(0xAA);
    const needed = tb.FontName(outline, id, &buffer, buffer.len);
    if (needed != text.len or !std.mem.eql(u8, text, buffer[0..text.len]) or buffer[text.len] != 0) {
        std.debug.print("name {d} is \"{s}\" ({d} bytes), not \"{s}\"\n", .{ id, std.mem.sliceTo(&buffer, 0), needed, text });
        return error.WrongName;
    }
}

test "truetype: a character map of format 0, a glyph a byte" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var glyphs: [256]u8 = @splat(0);
    glyphs['A'] = 1;
    glyphs[0xE9] = 2;
    glyphs[0xFF] = 7;
    // A glyph the font does not have.
    glyphs['Z'] = 200;
    var cmap = builder.Cmap.init(1);
    cmap.begin(0, 3);
    cmap.bytes(&glyphs);
    var file: builder.File = .{};
    fontOf(&file, &cmap, 8);

    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{
        .{ 'A', 1 },   .{ 0xE9, 2 },  .{ 0xFF, 7 },     .{ 'Z', 0 },         .{ 'B', 0 }, .{ 0, 0 },
        // Past the 256 it has there is none: not the low byte's.
        .{ 0x100, 0 }, .{ 0x141, 0 }, .{ 0x1_0041, 0 }, .{ 0xFFFF_FFFF, 0 },
    });
    tb.CloseOutline(outline);
    try rig.down();
}

test "truetype: a character map of format 4, segments by what is added and by glyphs listed" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    cmap.segments(&.{
        .{ .first = 0x20, .last = 0x22, .delta = delta(1 - 0x20) },
        // Listed, one of them as no glyph.
        .{ .first = 'A', .last = 'D', .glyphs = &.{ 5, 0, 6, 7 } },
        // Listed and added to: 4 and 5, and none stays none.
        .{ .first = 0x100, .last = 0x102, .delta = 2, .glyphs = &.{ 2, 0, 3 } },
        // A glyph the font does not have.
        .{ .first = 0x200, .last = 0x200, .delta = delta(9 - 0x200) },
        // The sum taken modulo 65536: 3, 4, 5.
        .{ .first = 0xFF00, .last = 0xFF02, .delta = 0x0103 },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });
    var file: builder.File = .{};
    fontOf(&file, &cmap, 8);

    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{
        .{ 0x20, 1 },   .{ 0x21, 2 },   .{ 0x22, 3 },     .{ 0x1F, 0 },     .{ 0x23, 0 },
        .{ 'A', 5 },    .{ 'B', 0 },    .{ 'C', 6 },      .{ 'D', 7 },      .{ 'E', 0 },
        .{ '@', 0 },    .{ 0x100, 4 },  .{ 0x101, 0 },    .{ 0x102, 5 },    .{ 0x103, 0 },
        .{ 0x200, 0 },  .{ 0xFF00, 3 }, .{ 0xFF01, 4 },   .{ 0xFF02, 5 },   .{ 0xFEFF, 0 },
        .{ 0xFF03, 0 }, .{ 0xFFFF, 0 },
        // The basic plane only.
        .{ 0x1_0020, 0 }, .{ 0x1_0041, 0 }, .{ 0x10_FFFF, 0 },
    });
    tb.CloseOutline(outline);
    try rig.down();
}

test "truetype: character maps of formats 6 and 10, one run of characters" {
    var rig = try Rig.up();
    const tb = rig.tb;
    var file: builder.File = .{};

    var short = builder.Cmap.init(1);
    short.begin(3, 1);
    short.run(0x30, &.{ 1, 2, 3, 0, 4, 9 });
    fontOf(&file, &short, 8);
    var outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{
        .{ 0x30, 1 },     .{ 0x31, 2 }, .{ 0x32, 3 }, .{ 0x33, 0 }, .{ 0x34, 4 },
        // A glyph the font does not have, and either side of the run.
        .{ 0x35, 0 },     .{ 0x2F, 0 }, .{ 0x36, 0 }, .{ 0, 0 },    .{ 0xFFFF, 0 },
        .{ 0x1_0030, 0 },
    });
    tb.CloseOutline(outline);

    var long = builder.Cmap.init(1);
    long.begin(3, 10);
    long.longRun(0x1F600, &.{ 1, 2, 3 });
    fontOf(&file, &long, 8);
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{
        .{ 0x1F600, 1 }, .{ 0x1F601, 2 }, .{ 0x1F602, 3 }, .{ 0x1F5FF, 0 },     .{ 0x1F603, 0 },
        .{ 0xF600, 0 },  .{ 'A', 0 },     .{ 0, 0 },       .{ 0xFFFF_FFFF, 0 },
    });
    tb.CloseOutline(outline);
    try rig.down();
}

test "truetype: character maps of formats 12 and 13, groups of characters" {
    var rig = try Rig.up();
    const tb = rig.tb;
    var file: builder.File = .{};

    // The first of a group has its glyph, the others the ones after it.
    var following = builder.Cmap.init(1);
    following.begin(3, 10);
    following.groups(12, &.{
        .{ .first = 'A', .last = 'C', .glyph = 1 },
        .{ .first = 0x400, .last = 0x401, .glyph = 5 },
        .{ .first = 0x1F600, .last = 0x1F601, .glyph = 6 },
        // Runs past the glyphs the font has.
        .{ .first = 0x2_0000, .last = 0x2_0003, .glyph = 6 },
    });
    fontOf(&file, &following, 8);
    var outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{
        .{ 'A', 1 },      .{ 'B', 2 },       .{ 'C', 3 },         .{ 'D', 0 },      .{ '@', 0 },
        .{ 0x3FF, 0 },    .{ 0x400, 5 },     .{ 0x401, 6 },       .{ 0x402, 0 },    .{ 0x1F600, 6 },
        .{ 0x1F601, 7 },  .{ 0x1F602, 0 },   .{ 0x2_0000, 6 },    .{ 0x2_0001, 7 }, .{ 0x2_0002, 0 },
        .{ 0x2_0003, 0 }, .{ 0x10_FFFF, 0 }, .{ 0xFFFF_FFFF, 0 },
    });
    tb.CloseOutline(outline);

    // Every character of a group has the one glyph.
    var same = builder.Cmap.init(1);
    same.begin(3, 10);
    same.groups(13, &.{
        .{ .first = 0x20, .last = 0x7E, .glyph = 1 },
        .{ .first = 0x4E00, .last = 0x9FFF, .glyph = 2 },
        .{ .first = 0x2_0000, .last = 0x2_A6DF, .glyph = 9 },
    });
    fontOf(&file, &same, 8);
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{
        .{ 0x20, 1 },     .{ 0x50, 1 },     .{ 0x7E, 1 },   .{ 0x1F, 0 },   .{ 0x7F, 0 },
        .{ 0x4E00, 2 },   .{ 0x7777, 2 },   .{ 0x9FFF, 2 }, .{ 0x4DFF, 0 }, .{ 0xA000, 0 },
        // A glyph the font does not have.
        .{ 0x2_0000, 0 }, .{ 0x2_A6DF, 0 },
    });
    tb.CloseOutline(outline);
    try rig.down();
}

test "truetype: variation sequences, a character and its selector as a glyph" {
    var rig = try Rig.up();
    const tb = rig.tb;
    var file: builder.File = .{};

    // 'A' to 'J' are glyphs 1 to 10 of 12.
    const letters = [_]builder.Segment{
        .{ .first = 'A', .last = 'J', .delta = delta(1 - 'A') },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    };
    const sequences = [_]builder.Selector{
        .{ .selector = 0xFE00, .keeps = &.{.{ 'B', 1 }}, .changes = &.{.{ 'A', 5 }} },
        .{ .selector = 0xFE0F, .changes = &.{ .{ 'A', 6 }, .{ 'C', 11 } } },
        // A glyph the font does not have, and a character it has none for.
        .{ .selector = 0xE0100, .keeps = &.{ .{ 'A', 0 }, .{ 'H', 2 }, .{ 'Z', 0 } }, .changes = &.{.{ 'D', 99 }} },
    };
    var cmap = builder.Cmap.init(2);
    cmap.begin(0, 5);
    cmap.variations(&sequences);
    cmap.begin(3, 1);
    cmap.segments(&letters);
    fontOf(&file, &cmap, 12);
    var outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{ .{ 'A', 1 }, .{ 'J', 10 }, .{ 0xFE00, 0 } });
    // A glyph of the sequence's own; the character's own; neither.
    try expectVariants(tb, outline, &.{
        .{ 'A', 0xFE00, 5 },  .{ 'B', 0xFE00, 2 },   .{ 'C', 0xFE00, 3 },
        .{ 'D', 0xFE00, 0 },  .{ '@', 0xFE00, 0 },   .{ 'A', 0xFE0F, 6 },
        .{ 'C', 0xFE0F, 11 }, .{ 'B', 0xFE0F, 0 },   .{ 'A', 0xE0100, 1 },
        .{ 'B', 0xE0100, 0 }, .{ 'G', 0xE0100, 0 },  .{ 'H', 0xE0100, 8 },
        .{ 'I', 0xE0100, 9 }, .{ 'J', 0xE0100, 10 }, .{ 'K', 0xE0100, 0 },
        .{ 'Z', 0xE0100, 0 }, .{ 'D', 0xE0100, 0 },
    });
    // A selector the font has no sequences for.
    try expectVariants(tb, outline, &.{
        .{ 'A', 0xFE01, 0 },      .{ 'A', 0xE0101, 0 },        .{ 'A', 0, 0 },
        .{ 'A', 0xFFFF_FFFF, 0 }, .{ 0xFFFF_FFFF, 0xFE00, 0 },
    });
    tb.CloseOutline(outline);

    // A font without them has no sequence.
    var plain = builder.Cmap.init(1);
    plain.begin(3, 1);
    plain.segments(&letters);
    fontOf(&file, &plain, 12);
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectVariants(tb, outline, &.{ .{ 'A', 0xFE00, 0 }, .{ 'B', 0xFE00, 0 } });
    tb.CloseOutline(outline);

    // They are the Unicode platform's, encoding 5: under another they
    // are not read, and are no character map either.
    var elsewhere = builder.Cmap.init(2);
    elsewhere.begin(3, 10);
    elsewhere.variations(&sequences);
    elsewhere.begin(3, 1);
    elsewhere.segments(&letters);
    fontOf(&file, &elsewhere, 12);
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{.{ 'A', 1 }});
    try expectVariants(tb, outline, &.{ .{ 'A', 0xFE00, 0 }, .{ 'B', 0xFE00, 0 } });
    tb.CloseOutline(outline);

    var alone = builder.Cmap.init(1);
    alone.begin(0, 5);
    alone.variations(&sequences);
    fontOf(&file, &alone, 12);
    try testing.expect(tb.OpenOutline(&file.bytes, file.len, null) == null);
    try rig.down();
}

test "truetype: a character map in the Macintosh Roman encoding is asked by its bytes" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var glyphs: [256]u8 = @splat(0);
    glyphs['A'] = 1;
    glyphs[0x8A] = 2; // the a with two dots
    glyphs[0xDB] = 3; // the euro sign
    glyphs[0xE4] = 4; // the per mille sign, not the a with two dots
    var cmap = builder.Cmap.init(1);
    cmap.begin(1, 0);
    cmap.bytes(&glyphs);
    var file: builder.File = .{};
    fontOf(&file, &cmap, 8);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{
        .{ 'A', 1 },    .{ 0xE4, 2 }, .{ 0x20AC, 3 },   .{ 0x2030, 4 },
        // Characters the encoding has no byte for.
        .{ 0x0100, 0 }, .{ 0x8A, 0 }, .{ 0x1_0041, 0 },
    });
    tb.CloseOutline(outline);
    try rig.down();
}

test "truetype: character maps of formats 2 and 8, bytes of one and of two, and groups" {
    var rig = try Rig.up();
    const tb = rig.tb;

    // Format 2: 'A' to 'C' are characters of one byte; behind the first
    // byte 0x81 the second bytes 0x40 to 0x42, and behind 0x82 one glyph
    // that has something added.
    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    bytesOfTwo(&cmap, &.{.{ .first = 'A', .glyphs = &.{ 1, 2, 0 } }}, &.{
        .{ .high = 0x81, .first = 0x40, .glyphs = &.{ 3, 4, 5 } },
        .{ .high = 0x82, .first = 0x10, .glyphs = &.{2}, .delta = 4 },
    });
    var file: builder.File = .{};
    fontOf(&file, &cmap, 8);
    var outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{
        .{ 'A', 1 },    .{ 'B', 2 },    .{ 'C', 0 },      .{ 'D', 0 },    .{ '@', 0 },
        .{ 0x8140, 3 }, .{ 0x8142, 5 }, .{ 0x8143, 0 },   .{ 0x813F, 0 }, .{ 0x8210, 6 },
        // A first byte with no subheader, and a first byte by itself.
        .{ 0x8340, 0 }, .{ 0x81, 0 },   .{ 0x1_8140, 0 },
    });
    tb.CloseOutline(outline);

    // Format 8: groups, as format 12's.
    cmap = builder.Cmap.init(1);
    cmap.begin(3, 10);
    mixed(&cmap, &.{
        .{ .first = 'A', .last = 'C', .glyph = 1 },
        .{ .first = 0x1_F600, .last = 0x1_F601, .glyph = 5 },
    });
    fontOf(&file, &cmap, 8);
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{
        .{ 'A', 1 }, .{ 'C', 3 }, .{ 'D', 0 }, .{ 0x1_F600, 5 }, .{ 0x1_F601, 6 }, .{ 0x1_F602, 0 },
    });
    tb.CloseOutline(outline);
    try rig.down();
}

test "truetype: a glyph is drawn from its left side point, where its bearing differs from its box" {
    var rig = try Rig.up();
    const tb = rig.tb;

    // The square's box begins at 0. Said to stand 30 from its left side
    // point, it is drawn 30 to the right, and measured there.
    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    letter(&cmap, 4, 1);
    var file: builder.File = .{};
    const directory = builder.font(&file, .{ .cmap = cmap.written(), .glyphs = 3 });
    const hmtx = std.mem.readInt(u32, file.bytes[(try recordOf(file.written(), directory, "hmtx")) + 8 ..][0..4], .big);
    // The advance and glyph 0's bearing, then a bearing a glyph.
    file.setWord(hmtx + 4, 30);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    var metrics: truetype.GlyphMetrics = .{};
    try testing.expect(tb.GlyphMetrics(outline, 1, &metrics));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .left_bearing = 30, .x_min = 30, .x_max = 530, .y_max = 700 }, metrics);
    var verbs: [8]u8 = undefined;
    var points: [8]sdk.vector.Point = undefined;
    var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 8, .point_room = 8 };
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 1, &segments));
    var least: f32 = points[0].x;
    var most: f32 = points[0].x;
    for (points[0..segments.point_count]) |point| {
        least = @min(least, point.x);
        most = @max(most, point.x);
    }
    try testing.expectEqual(@as(f32, 30), least);
    try testing.expectEqual(@as(f32, 530), most);
    // The glyph beside it, whose bearing is its box's left, is where it
    // was.
    try testing.expect(tb.GlyphMetrics(outline, 2, &metrics));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .x_max = 500, .y_max = 700 }, metrics);
    tb.CloseOutline(outline);
    try rig.down();
}

test "truetype: a character map that says more than it holds is read as far as it goes" {
    var rig = try Rig.up();
    const tb = rig.tb;
    var file: builder.File = .{};

    // Each is the last of its table, which is where it ends; what says
    // how many entries it has says far more.
    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    var start = cmap.file.len;
    cmap.segments(&.{
        .{ .first = 'A', .last = 'C', .delta = delta(1 - 'A') },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });
    cmap.file.setWord(start + 6, 0xFFFE);
    fontOf(&file, &cmap, 8);
    var outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{ .{ 'A', 1 }, .{ 'C', 3 }, .{ 'D', 0 }, .{ 0x4000, 0 }, .{ 0xFFFF, 0 } });
    tb.CloseOutline(outline);

    cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    start = cmap.file.len;
    cmap.run(0x30, &.{ 1, 2, 3 });
    cmap.file.setWord(start + 8, 100);
    fontOf(&file, &cmap, 8);
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{ .{ 0x30, 1 }, .{ 0x32, 3 }, .{ 0x33, 0 }, .{ 0x93, 0 }, .{ 0x94, 0 } });
    tb.CloseOutline(outline);

    cmap = builder.Cmap.init(1);
    cmap.begin(3, 10);
    start = cmap.file.len;
    cmap.longRun(0x1F600, &.{ 1, 2, 3 });
    cmap.file.setLong(start + 16, 0xFFFF_FFFF);
    fontOf(&file, &cmap, 8);
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{ .{ 0x1F600, 1 }, .{ 0x1F602, 3 }, .{ 0x1F603, 0 }, .{ 0x10_FFFF, 0 }, .{ 0xFFFF_FFFF, 0 } });
    tb.CloseOutline(outline);

    cmap = builder.Cmap.init(1);
    cmap.begin(3, 10);
    start = cmap.file.len;
    cmap.groups(12, &.{
        .{ .first = 'A', .last = 'C', .glyph = 1 },
        .{ .first = 0x400, .last = 0x401, .glyph = 5 },
    });
    cmap.file.setLong(start + 12, 0xFFFF_FFFF);
    fontOf(&file, &cmap, 8);
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{ .{ 'A', 1 }, .{ 'C', 3 }, .{ 0x401, 6 }, .{ 0x402, 0 }, .{ 0x10_FFFF, 0 } });
    tb.CloseOutline(outline);

    // The sequences: more selectors said than there are, and more
    // characters of the one there is.
    cmap = builder.Cmap.init(2);
    cmap.begin(3, 1);
    letter(&cmap, 4, 1);
    cmap.begin(0, 5);
    start = cmap.file.len;
    cmap.variations(&.{.{ .selector = 0xFE00, .changes = &.{.{ 'A', 5 }} }});
    cmap.file.setLong(start + 6, 0xFFFF_FFFF);
    cmap.file.setLong(start + 10 + 11, 0xFFFF_FFFF);
    fontOf(&file, &cmap, 8);
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectVariants(tb, outline, &.{ .{ 'A', 0xFE00, 5 }, .{ 'B', 0xFE00, 0 }, .{ 'A', 0xFE01, 0 }, .{ 'A', 0xF_FFFF, 0 } });
    tb.CloseOutline(outline);
    try rig.down();
}

test "truetype: which character map is read, of the ones a font has" {
    var rig = try Rig.up();
    const tb = rig.tb;
    const none: ?u32 = null;

    // The Macintosh Roman encoding's is the last resort, after a symbol
    // font's; any other Macintosh encoding is passed over.
    try testing.expectEqual(@as(?u32, 1), letterOf(tb, &.{ .{ .platform = 1, .encoding = 0, .format = 6, .glyph = 3 }, .{ .platform = 3, .encoding = 1, .format = 4, .glyph = 1 } }));
    try testing.expectEqual(@as(?u32, 1), letterOf(tb, &.{ .{ .platform = 1, .encoding = 0, .format = 6, .glyph = 3 }, .{ .platform = 3, .encoding = 0, .format = 0, .glyph = 1 } }));
    try testing.expectEqual(@as(?u32, 3), letterOf(tb, &.{ .{ .platform = 1, .encoding = 1, .format = 6, .glyph = 2 }, .{ .platform = 1, .encoding = 0, .format = 6, .glyph = 3 } }));
    // The format that reaches furthest, wherever it stands: 12, 13, 8,
    // 10, 4, 2, 6, 0.
    try testing.expectEqual(@as(?u32, 2), letterOf(tb, &.{ .{ .platform = 3, .encoding = 10, .format = 8, .glyph = 1 }, .{ .platform = 3, .encoding = 10, .format = 13, .glyph = 2 } }));
    try testing.expectEqual(@as(?u32, 2), letterOf(tb, &.{ .{ .platform = 0, .encoding = 4, .format = 10, .glyph = 1 }, .{ .platform = 3, .encoding = 10, .format = 8, .glyph = 2 } }));
    try testing.expectEqual(@as(?u32, 2), letterOf(tb, &.{ .{ .platform = 3, .encoding = 1, .format = 2, .glyph = 1 }, .{ .platform = 3, .encoding = 1, .format = 4, .glyph = 2 } }));
    try testing.expectEqual(@as(?u32, 2), letterOf(tb, &.{ .{ .platform = 0, .encoding = 3, .format = 6, .glyph = 1 }, .{ .platform = 3, .encoding = 1, .format = 2, .glyph = 2 } }));
    try testing.expectEqual(@as(?u32, 2), letterOf(tb, &.{ .{ .platform = 3, .encoding = 1, .format = 4, .glyph = 1 }, .{ .platform = 3, .encoding = 10, .format = 12, .glyph = 2 } }));
    try testing.expectEqual(@as(?u32, 2), letterOf(tb, &.{ .{ .platform = 3, .encoding = 10, .format = 12, .glyph = 2 }, .{ .platform = 3, .encoding = 1, .format = 4, .glyph = 1 } }));
    try testing.expectEqual(@as(?u32, 2), letterOf(tb, &.{ .{ .platform = 0, .encoding = 4, .format = 13, .glyph = 1 }, .{ .platform = 3, .encoding = 10, .format = 12, .glyph = 2 } }));
    try testing.expectEqual(@as(?u32, 2), letterOf(tb, &.{ .{ .platform = 0, .encoding = 4, .format = 10, .glyph = 1 }, .{ .platform = 3, .encoding = 10, .format = 13, .glyph = 2 } }));
    try testing.expectEqual(@as(?u32, 2), letterOf(tb, &.{ .{ .platform = 3, .encoding = 1, .format = 4, .glyph = 1 }, .{ .platform = 0, .encoding = 4, .format = 10, .glyph = 2 } }));
    try testing.expectEqual(@as(?u32, 2), letterOf(tb, &.{ .{ .platform = 0, .encoding = 3, .format = 6, .glyph = 1 }, .{ .platform = 3, .encoding = 1, .format = 4, .glyph = 2 } }));
    try testing.expectEqual(@as(?u32, 2), letterOf(tb, &.{ .{ .platform = 3, .encoding = 1, .format = 0, .glyph = 1 }, .{ .platform = 0, .encoding = 3, .format = 6, .glyph = 2 } }));
    // Of two alike, the first.
    try testing.expectEqual(@as(?u32, 1), letterOf(tb, &.{ .{ .platform = 0, .encoding = 3, .format = 4, .glyph = 1 }, .{ .platform = 3, .encoding = 1, .format = 4, .glyph = 2 } }));
    // A Unicode map before a symbol font's, whatever their formats.
    try testing.expectEqual(@as(?u32, 2), letterOf(tb, &.{ .{ .platform = 3, .encoding = 0, .format = 12, .glyph = 1 }, .{ .platform = 0, .encoding = 3, .format = 0, .glyph = 2 } }));
    try testing.expectEqual(@as(?u32, 1), letterOf(tb, &.{.{ .platform = 3, .encoding = 0, .format = 4, .glyph = 1 }}));

    // No map the library reads: the font is not opened.
    try testing.expectEqual(none, letterOf(tb, &.{}));
    try testing.expectEqual(none, letterOf(tb, &.{.{ .platform = 1, .encoding = 1, .format = 0, .glyph = 1 }}));
    try testing.expectEqual(none, letterOf(tb, &.{.{ .platform = 2, .encoding = 1, .format = 4, .glyph = 1 }}));
    try testing.expectEqual(none, letterOf(tb, &.{.{ .platform = 3, .encoding = 3, .format = 4, .glyph = 1 }}));
    try testing.expectEqual(none, letterOf(tb, &.{.{ .platform = 4, .encoding = 0, .format = 4, .glyph = 1 }}));
    try testing.expectEqual(none, letterOf(tb, &.{.{ .platform = 3, .encoding = 1, .format = 9, .glyph = 1 }}));
    // One it does not read beside one it does.
    try testing.expectEqual(@as(?u32, 1), letterOf(tb, &.{ .{ .platform = 3, .encoding = 10, .format = 9, .glyph = 2 }, .{ .platform = 3, .encoding = 1, .format = 4, .glyph = 1 } }));

    var file: builder.File = .{};

    // A subtable said to be outside the table is passed over.
    var cmap = builder.Cmap.init(2);
    cmap.begin(3, 10);
    cmap.file.setLong(4 + 4, 0x7FFF_FFFF);
    cmap.begin(3, 1);
    letter(&cmap, 4, 1);
    fontOf(&file, &cmap, 8);
    var outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{.{ 'A', 1 }});
    tb.CloseOutline(outline);
    cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    letter(&cmap, 4, 1);
    cmap.file.setLong(4 + 4, cmap.file.len);
    fontOf(&file, &cmap, 8);
    try testing.expect(tb.OpenOutline(&file.bytes, file.len, null) == null);

    // A symbol font's characters are where the font has them.
    cmap = builder.Cmap.init(1);
    cmap.begin(3, 0);
    cmap.segments(&.{
        .{ .first = 0xF020, .last = 0xF022, .delta = delta(1 - 0xF020) },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });
    fontOf(&file, &cmap, 8);
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectGlyphs(tb, outline, &.{ .{ 0xF020, 1 }, .{ 0xF022, 3 }, .{ 0xF023, 0 }, .{ 0x20, 0 }, .{ 0x22, 0 } });
    tb.CloseOutline(outline);
    try rig.down();
}

test "truetype: a collection, each of its fonts by its number" {
    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;

    var first_map = builder.Cmap.init(1);
    first_map.begin(3, 1);
    letter(&first_map, 4, 1);
    var second_map = builder.Cmap.init(1);
    second_map.begin(3, 1);
    letter(&second_map, 4, 2);

    var file: builder.File = .{};
    builder.collection(&file, 2);
    const first = builder.font(&file, .{ .cmap = first_map.written(), .glyphs = 4 });
    builder.place(&file, 0, first);
    const second = builder.font(&file, .{ .cmap = second_map.written(), .glyphs = 6, .advance = 700, .style_bits = 1 });
    builder.place(&file, 1, second);
    const bytes = file.written();

    try testing.expect(!truetype.isTrueType(bytes));
    try testing.expectEqual(@as(u32, 2), truetype.fontCount(bytes));
    try testing.expectEqual(@as(?u32, first), truetype.fontDirectory(bytes, 0));
    try testing.expectEqual(@as(?u32, second), truetype.fontDirectory(bytes, 1));
    try testing.expectEqual(@as(?u32, null), truetype.fontDirectory(bytes, 2));
    try testing.expectEqual(graphics.FS_NORMAL, truetype.styleOf(bytes));

    var metrics: truetype.FontMetrics = .{};
    var glyph: truetype.GlyphMetrics = .{};

    // Without a number, and as number 0: the first.
    for ([_]?*truetype.Outline{ tb.OpenOutline(bytes.ptr, file.len, null), openFont(tb, bytes, 0) }) |opened| {
        const outline = opened orelse return error.NotRead;
        tb.FontMetrics(outline, &metrics);
        try testing.expectEqual(@as(u32, 4), metrics.glyph_count);
        try testing.expectEqual(graphics.FS_NORMAL, metrics.style);
        try expectGlyphs(tb, outline, &.{ .{ 'A', 1 }, .{ 'B', 0 } });
        try testing.expect(tb.GlyphMetrics(outline, 1, &glyph));
        try testing.expectEqual(@as(i32, 600), glyph.advance);
        try testing.expect(!tb.GlyphMetrics(outline, 4, &glyph));
        tb.CloseOutline(outline);
    }

    // The second: its own tables, their places counted from the start of
    // the file.
    const outline = openFont(tb, bytes, 1) orelse return error.NotRead;
    tb.FontMetrics(outline, &metrics);
    try testing.expectEqual(@as(u32, 6), metrics.glyph_count);
    try testing.expectEqual(graphics.FSF_BOLD, metrics.style);
    try expectGlyphs(tb, outline, &.{ .{ 'A', 2 }, .{ 'B', 0 } });
    try testing.expect(tb.GlyphMetrics(outline, 5, &glyph));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 700, .x_max = 500, .y_max = 700 }, glyph);
    var length: u32 = 0;
    const map = tb.FontTable(outline, truetype.tableTag("cmap"), &length) orelse return error.NoTable;
    try testing.expect(@intFromPtr(map) > @intFromPtr(bytes.ptr) + second);
    try testing.expectEqualSlices(u8, second_map.written(), map[0..length]);
    const maxp = tb.FontTable(outline, truetype.tableTag("maxp"), &length) orelse return error.NoTable;
    try testing.expectEqual(@as(u32, 32), length);
    try testing.expectEqual(@as(u8, 6), maxp[5]);
    // Rendered: its 'A' a square of 10 by 14 pixels, moving the point 14.
    const letters = [_]truetype.CodeRange{.{ .first = 'A', .last = 'Z' }};
    const image = tb.RenderFontImage(outline, 20, &letters, letters.len) orelse return error.NoImage;
    try testing.expect(fontimage.sound(@ptrCast(image), image.size));
    try testing.expectEqual(graphics.FSF_BOLD, image.style);
    const a = fontimage.find(image, 'A') orelse return error.NoGlyph;
    try testing.expectEqual(@as(u16, 10), a.width);
    try testing.expectEqual(@as(u16, 14), a.rows);
    try testing.expectEqual(@as(i16, 14), a.advance);
    try testing.expect(fontimage.find(image, 'B') == null);
    sys.FreeVec(image);
    tb.CloseOutline(outline);

    // A font the file does not hold, whatever the number's width.
    try testing.expect(openFont(tb, bytes, 2) == null);
    try testing.expect(openFont(tb, bytes, 0xFFFF_FFFF) == null);
    try testing.expect(openFont(tb, bytes, std.math.maxInt(usize)) == null);

    // A file of one font holds font 0 and no other.
    var plain: builder.File = .{};
    fontOf(&plain, &first_map, 4);
    try testing.expectEqual(@as(u32, 1), truetype.fontCount(plain.written()));
    const only = openFont(tb, plain.written(), 0) orelse return error.NotRead;
    tb.CloseOutline(only);
    try testing.expect(openFont(tb, plain.written(), 1) == null);

    // A font said to be outside the file, or too near its end to be one:
    // not opened, and the one before it still is.
    var damaged = file;
    builder.place(&damaged, 1, damaged.len);
    try testing.expect(openFont(tb, damaged.written(), 1) == null);
    builder.place(&damaged, 1, damaged.len - 8);
    try testing.expect(openFont(tb, damaged.written(), 1) == null);
    builder.place(&damaged, 1, 0xFFFF_FFF0);
    try testing.expect(openFont(tb, damaged.written(), 1) == null);
    const before = openFont(tb, damaged.written(), 0) orelse return error.NotRead;
    tb.CloseOutline(before);

    // A font that starts as none this library reads.
    damaged = file;
    @memcpy(damaged.bytes[second..][0..4], "typ1");
    try testing.expectEqual(@as(u32, 2), truetype.fontCount(damaged.written()));
    try testing.expect(openFont(tb, damaged.written(), 1) == null);

    // The header cut short, and the file cut within the second font.
    try testing.expect(tb.OpenOutline(bytes.ptr, 11, null) == null);
    try testing.expect(tb.OpenOutline(bytes.ptr, 14, null) == null);
    try testing.expect(tb.OpenOutline(bytes.ptr, 18, &[_]utility.TagItem{ .{ .tag = truetype.TTA_FontIndex, .data = 1 }, .{} }) == null);
    try testing.expect(tb.OpenOutline(bytes.ptr, second + 40, &[_]utility.TagItem{ .{ .tag = truetype.TTA_FontIndex, .data = 1 }, .{} }) == null);
    try rig.down();
}

test "truetype: a font's names, UTF-16 as UTF-8" {
    var rig = try Rig.up();
    const tb = rig.tb;

    const english = 0x0409;
    var table: builder.File = .{};
    builder.names(&table, &.{
        // The Macintosh Roman encoding's is taken only where there is
        // no other.
        .{ .platform = 1, .encoding = 0, .language = 0, .id = 1, .stored = "Mac Family" },
        .{ .platform = 3, .encoding = 1, .language = english, .id = 1, .stored = builder.utf16("Family") },
        // American English before another English, wherever it stands.
        .{ .platform = 3, .encoding = 1, .language = 0x0809, .id = 2, .stored = builder.utf16("British") },
        .{ .platform = 3, .encoding = 1, .language = english, .id = 2, .stored = builder.utf16("American") },
        // A byte a character: 0x8A is the a with two dots, 0xDB the euro.
        .{ .platform = 1, .encoding = 0, .language = 0, .id = 3, .stored = "M\x8Ac only \xDB" },
        // In another language than English, or another encoding: not read.
        .{ .platform = 1, .encoding = 0, .language = 2, .id = 23, .stored = "Deutsch" },
        .{ .platform = 1, .encoding = 1, .language = 0, .id = 24, .stored = "\x83\x41" },
        // The Unicode platform before another language than English.
        .{ .platform = 3, .encoding = 1, .language = 0x0407, .id = 4, .stored = builder.utf16("Deutsch") },
        .{ .platform = 0, .encoding = 3, .language = 0, .id = 4, .stored = builder.utf16("Unicode") },
        .{ .platform = 3, .encoding = 1, .language = 0x0407, .id = 5, .stored = builder.utf16("Deutsch") },
        // And after any English.
        .{ .platform = 0, .encoding = 4, .language = 0, .id = 6, .stored = builder.utf16("Unicode") },
        .{ .platform = 3, .encoding = 1, .language = 0x0C09, .id = 6, .stored = builder.utf16("Australian") },
        // A character of two units; halves of one, alone; a NUL.
        .{ .platform = 3, .encoding = 10, .language = english, .id = 16, .stored = builder.utf16("\u{1F600}!") },
        .{ .platform = 3, .encoding = 1, .language = english, .id = 17, .stored = builder.utf16Of(&.{ 0xD800, 'a', 0xDC00, 'b', 0xD83D }) },
        .{ .platform = 3, .encoding = 1, .language = english, .id = 13, .stored = builder.utf16Of(&.{ 'a', 0, 'b' }) },
        .{ .platform = 3, .encoding = 1, .language = english, .id = 14, .stored = builder.utf16("Größe") },
        // Its string made to lie outside the table, below: passed over
        // for the next of that name.
        .{ .platform = 3, .encoding = 1, .language = english, .id = 15, .stored = builder.utf16("Outside") },
        .{ .platform = 0, .encoding = 3, .language = 0, .id = 15, .stored = builder.utf16("Inside") },
        // Half a unit at the end, and half a unit alone.
        .{ .platform = 3, .encoding = 1, .language = english, .id = 18, .stored = "\x00A\x00" },
        .{ .platform = 3, .encoding = 1, .language = english, .id = 19, .stored = "\x00" },
        // A symbol font's names are UTF-16 too; other encodings are not.
        .{ .platform = 3, .encoding = 0, .language = english, .id = 20, .stored = builder.utf16("Symbol") },
        .{ .platform = 3, .encoding = 2, .language = 0x0411, .id = 21, .stored = "\x83\x41" },
        .{ .platform = 2, .encoding = 1, .language = 0, .id = 22, .stored = "ISO" },
    });
    table.setWord(6 + 16 * 12 + 10, 0xFFF0);

    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    letter(&cmap, 4, 1);
    var file: builder.File = .{};
    _ = builder.font(&file, .{ .cmap = cmap.written(), .more = &.{.{ .tag = "name", .bytes = table.written() }} });
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    try expectName(tb, outline, truetype.TTNAME_FAMILY, "Family");
    try expectName(tb, outline, truetype.TTNAME_STYLE, "American");
    try expectName(tb, outline, truetype.TTNAME_UNIQUE, "M\u{E4}c only \u{20AC}");
    try expectName(tb, outline, 23, "");
    try expectName(tb, outline, 24, "");
    try expectName(tb, outline, truetype.TTNAME_FULL, "Unicode");
    try expectName(tb, outline, truetype.TTNAME_VERSION, "Deutsch");
    try expectName(tb, outline, truetype.TTNAME_POSTSCRIPT, "Australian");
    try expectName(tb, outline, truetype.TTNAME_TYPO_FAMILY, "\u{1F600}!");
    try expectName(tb, outline, truetype.TTNAME_TYPO_STYLE, "\u{FFFD}a\u{FFFD}b\u{FFFD}");
    try expectName(tb, outline, truetype.TTNAME_LICENCE, "ab");
    try expectName(tb, outline, truetype.TTNAME_LICENCE_URL, "Größe");
    try expectName(tb, outline, 15, "Inside");
    try expectName(tb, outline, 18, "A");
    try expectName(tb, outline, 19, "");
    try expectName(tb, outline, 20, "Symbol");
    try expectName(tb, outline, 21, "");
    try expectName(tb, outline, 22, "");
    // A name the table has no record of.
    try expectName(tb, outline, 7, "");
    try expectName(tb, outline, 0x1_0001, "");
    try expectName(tb, outline, 0xFFFF_FFFF, "");

    // Cut to the room there is: after a whole character, NUL-terminated,
    // and nothing put after the first that does not fit. What the whole
    // name takes is answered whatever the room.
    const Cut = struct { room: u32, text: []const u8 };
    for ([_]Cut{
        .{ .room = 0, .text = "" },
        .{ .room = 1, .text = "" },
        .{ .room = 2, .text = "G" },
        .{ .room = 3, .text = "Gr" },
        .{ .room = 4, .text = "Gr" },
        .{ .room = 5, .text = "Grö" },
        .{ .room = 6, .text = "Grö" },
        .{ .room = 7, .text = "Größ" },
        .{ .room = 8, .text = "Größe" },
        .{ .room = 9, .text = "Größe" },
    }) |cut| {
        var buffer: [16]u8 = @splat(0xAA);
        try testing.expectEqual(@as(u32, 7), tb.FontName(outline, truetype.TTNAME_LICENCE_URL, &buffer, cut.room));
        if (cut.room == 0) {
            try testing.expectEqual(@as(u8, 0xAA), buffer[0]);
            continue;
        }
        try testing.expectEqualStrings(cut.text, buffer[0..cut.text.len]);
        try testing.expectEqual(@as(u8, 0), buffer[cut.text.len]);
        for (buffer[cut.text.len + 1 ..]) |byte| try testing.expectEqual(@as(u8, 0xAA), byte);
    }
    // A name the font does not have empties the buffer.
    var buffer: [4]u8 = @splat(0xAA);
    try testing.expectEqual(@as(u32, 0), tb.FontName(outline, 7, &buffer, 4));
    try testing.expectEqualSlices(u8, &.{ 0, 0xAA, 0xAA, 0xAA }, &buffer);
    try testing.expectEqual(@as(u32, 0), tb.FontName(outline, 7, &buffer, 0));
    tb.CloseOutline(outline);

    // A font without the table has no names.
    fontOf(&file, &cmap, 8);
    const nameless = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectName(tb, nameless, truetype.TTNAME_FAMILY, "");
    tb.CloseOutline(nameless);

    // A table that says more records than it holds, and one cut before
    // its first.
    var short: builder.File = .{};
    builder.names(&short, &.{.{ .platform = 3, .encoding = 1, .language = english, .id = 1, .stored = builder.utf16("One") }});
    short.setWord(2, 0xFFFF);
    _ = builder.font(resetOf(&file), .{ .cmap = cmap.written(), .more = &.{.{ .tag = "name", .bytes = short.written() }} });
    const one = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectName(tb, one, truetype.TTNAME_FAMILY, "One");
    try expectName(tb, one, truetype.TTNAME_STYLE, "");
    tb.CloseOutline(one);
    _ = builder.font(resetOf(&file), .{ .cmap = cmap.written(), .more = &.{.{ .tag = "name", .bytes = short.bytes[0..5] }} });
    const cut_short = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    try expectName(tb, cut_short, truetype.TTNAME_FAMILY, "");
    tb.CloseOutline(cut_short);
    try rig.down();
}

/// `file`, emptied.
fn resetOf(file: *builder.File) *builder.File {
    file.* = .{};
    return file;
}

test "truetype: a table handed out as the file has it" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    letter(&cmap, 4, 1);
    const held = "what a table holds";
    var file: builder.File = .{};
    const directory = builder.font(&file, .{ .cmap = cmap.written(), .more = &.{.{ .tag = "TEST", .bytes = held }} });
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    const start = @intFromPtr(&file.bytes);

    // The file's own bytes, where its directory says they are.
    var length: u32 = 1;
    const own = tb.FontTable(outline, truetype.tableTag("TEST"), &length) orelse return error.NoTable;
    try testing.expectEqualStrings(held, own[0..length]);
    const record = try recordOf(file.written(), directory, "TEST");
    try testing.expectEqual(start + std.mem.readInt(u32, file.bytes[record + 8 ..][0..4], .big), @intFromPtr(own));
    const map = tb.FontTable(outline, truetype.tableTag("cmap"), &length) orelse return error.NoTable;
    try testing.expectEqualSlices(u8, cmap.written(), map[0..length]);
    const head = tb.FontTable(outline, truetype.tableTag("head"), &length) orelse return error.NoTable;
    try testing.expectEqual(@as(u32, 54), length);
    try testing.expect(@intFromPtr(head) > start and @intFromPtr(head) + length <= start + file.len);

    // A table the font does not have: nothing, of no length. A tag is
    // its four letters as they are.
    length = 1;
    try testing.expect(tb.FontTable(outline, truetype.tableTag("GSUB"), &length) == null);
    try testing.expectEqual(@as(u32, 0), length);
    length = 1;
    try testing.expect(tb.FontTable(outline, truetype.tableTag("test"), &length) == null);
    try testing.expectEqual(@as(u32, 0), length);
    try testing.expect(tb.FontTable(outline, 0, &length) == null);
    try testing.expect(tb.FontTable(outline, 0xFFFF_FFFF, &length) == null);

    // One said to run past the file's end, or to start past it: none.
    const said = std.mem.readInt(u32, file.bytes[record + 12 ..][0..4], .big);
    file.setLong(record + 12, file.len);
    length = 1;
    try testing.expect(tb.FontTable(outline, truetype.tableTag("TEST"), &length) == null);
    try testing.expectEqual(@as(u32, 0), length);
    file.setLong(record + 12, 0xFFFF_FFFF);
    try testing.expect(tb.FontTable(outline, truetype.tableTag("TEST"), &length) == null);
    file.setLong(record + 12, said);
    file.setLong(record + 8, file.len + 4);
    try testing.expect(tb.FontTable(outline, truetype.tableTag("TEST"), &length) == null);
    try testing.expectEqual(@as(u32, 0), length);

    tb.CloseOutline(outline);
    try rig.down();
}

test "truetype: a font without outlines is read in all but them" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    cmap.segments(&.{
        .{ .first = 'A', .last = 'C', .delta = delta(1 - 'A') },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });
    var names: builder.File = .{};
    builder.names(&names, &.{.{ .platform = 3, .encoding = 1, .language = 0x0409, .id = 1, .stored = builder.utf16("Pictures") }});
    var file: builder.File = .{};
    _ = builder.font(&file, .{
        .cmap = cmap.written(),
        .glyphs = 6,
        .outlines = false,
        .more = &.{.{ .tag = "name", .bytes = names.written() }},
    });
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    var metrics: truetype.FontMetrics = .{};
    tb.FontMetrics(outline, &metrics);
    try testing.expectEqual(@as(u32, 6), metrics.glyph_count);
    try testing.expectEqual(@as(u32, builder.units_per_em), metrics.units_per_em);
    try testing.expectEqual(@as(i32, builder.ascender), metrics.ascender);
    try testing.expectEqual(@as(i32, builder.descender), metrics.descender);
    try testing.expectEqual(@as(i32, builder.line_gap), metrics.line_gap);
    try expectGlyphs(tb, outline, &.{ .{ 'A', 1 }, .{ 'C', 3 }, .{ 'D', 0 } });
    try expectName(tb, outline, truetype.TTNAME_FAMILY, "Pictures");

    // A glyph moves the point, and has no box and no outline.
    var glyph: truetype.GlyphMetrics = .{};
    try testing.expect(tb.GlyphMetrics(outline, 2, &glyph));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600 }, glyph);
    try testing.expect(!tb.GlyphMetrics(outline, 6, &glyph));
    var verbs: [8]u8 = undefined;
    var points: [8]sdk.vector.Point = undefined;
    var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 8, .point_room = 8 };
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 2, &segments));
    try testing.expectEqual(@as(u32, 0), segments.verb_count);
    try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.GlyphSegments(outline, 6, &segments));

    // No image is rendered of it, and it has neither table.
    const letters = [_]truetype.CodeRange{.{ .first = 'A', .last = 'Z' }};
    try testing.expect(tb.RenderFontImage(outline, 20, &letters, letters.len) == null);
    var length: u32 = 1;
    try testing.expect(tb.FontTable(outline, truetype.tableTag("glyf"), &length) == null);
    try testing.expect(tb.FontTable(outline, truetype.tableTag("loca"), &length) == null);
    tb.CloseOutline(outline);

    // Outlines are both tables or neither.
    _ = builder.font(resetOf(&file), .{
        .cmap = cmap.written(),
        .glyphs = 6,
        .outlines = false,
        .more = &.{.{ .tag = "glyf", .bytes = &[_]u8{0} ** 36 }},
    });
    try testing.expect(tb.OpenOutline(&file.bytes, file.len, null) == null);
    try rig.down();
}

test "truetype: a font that lacks what every font has is not opened" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    letter(&cmap, 4, 1);
    var sound: builder.File = .{};
    const directory = builder.font(&sound, .{ .cmap = cmap.written() });
    const whole = tb.OpenOutline(&sound.bytes, sound.len, null) orelse return error.NotRead;
    tb.CloseOutline(whole);
    const head = try recordOf(sound.written(), directory, "head");
    const hhea = try recordOf(sound.written(), directory, "hhea");
    const head_at = std.mem.readInt(u32, sound.bytes[head + 8 ..][0..4], .big);
    const hhea_at = std.mem.readInt(u32, sound.bytes[hhea + 8 ..][0..4], .big);

    // One table missing, each in turn.
    for ([_]*const [4]u8{ "head", "hhea", "maxp", "cmap", "hmtx", "loca", "glyf" }) |tag| {
        var file = sound;
        const record = try recordOf(file.written(), directory, tag);
        file.bytes[record] = 'x';
        try testing.expect(tb.OpenOutline(&file.bytes, file.len, null) == null);
    }
    // One too short to hold what is read of it.
    for ([_]struct { tag: *const [4]u8, len: u32 }{
        .{ .tag = "head", .len = 53 },
        .{ .tag = "hhea", .len = 35 },
        .{ .tag = "maxp", .len = 5 },
    }) |short| {
        var file = sound;
        file.setLong(try recordOf(file.written(), directory, short.tag) + 12, short.len);
        try testing.expect(tb.OpenOutline(&file.bytes, file.len, null) == null);
    }
    // An em of no units, no advance for any glyph, a line of no height.
    var file = sound;
    file.setWord(head_at + 18, 0);
    try testing.expect(tb.OpenOutline(&file.bytes, file.len, null) == null);
    file = sound;
    file.setWord(hhea_at + 34, 0);
    try testing.expect(tb.OpenOutline(&file.bytes, file.len, null) == null);
    file = sound;
    file.setWord(hhea_at + 4, @bitCast(@as(i16, builder.descender)));
    try testing.expect(tb.OpenOutline(&file.bytes, file.len, null) == null);

    // Not a font at all, and one cut within its directory.
    try testing.expect(tb.OpenOutline("FONT and more bytes", 19, null) == null);
    try testing.expect(tb.OpenOutline(&sound.bytes, 0, null) == null);
    try testing.expect(tb.OpenOutline(&sound.bytes, 11, null) == null);
    try testing.expect(tb.OpenOutline(&sound.bytes, 60, null) == null);
    try rig.down();
}

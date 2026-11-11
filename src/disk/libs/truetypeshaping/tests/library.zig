// SPDX-License-Identifier: MIT
//! Host tests of truetypeshaping.library as a program reaches it: the
//! library made from its ROM tag beside truetype.library on the ROM's
//! exec, a font the test builds with layout tables in it, and ShapeGlyphs
//! and ShapeText called through the jump table.
//!
//! What each kind of lookup does, and how a text is cut and shaped, is
//! the other files' here; these tests are about the calls: the tables,
//! the advances, the glyphs of characters and the kerning they take from
//! the font, the run they fill, their errors, and the memory they give
//! back.

const std = @import("std");
const sdk = @import("sdk");
const truetype = sdk.truetype;
const tts = sdk.truetypeshaping;
const host = @import("host_rom");
const kexec = host.exec;
const builder = @import("../../truetype/tests/builder.zig");
const FontRig = @import("../../truetype/tests/truetype.zig").Rig;
const truetypeshaping_init = @import("../truetypeshaping_init.zig");
const layout = @import("layout.zig");
const subtables = @import("subtables.zig");

const testing = std.testing;
const File = layout.File;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;
const TrueTypeShapingBase = sdk.interface.truetypeshaping.TrueTypeShapingBase;

test {
    _ = @import("../truetypeshaping_lvo.zig");
}

/// truetype.library up as its own tests have it, and
/// truetypeshaping.library made from its ROM tag and opened.
pub const Rig = struct {
    font: FontRig,
    library: *sdk.exec.Library,
    sb: *TrueTypeShapingBase,
    tb: *TrueTypeBase,

    pub fn up() !Rig {
        const font = try FontRig.up();
        const made = kexec.InitResident(kexec.SysBase, &truetypeshaping_init.truetypeshaping_library_tag, null) orelse return error.NoLibrary;
        return .{
            .font = font,
            .library = @ptrCast(@alignCast(made)),
            .sb = @ptrCast(font.sys.OpenLibrary(tts.TRUETYPESHAPINGNAME, tts.TRUETYPESHAPING_VERSION) orelse return error.NoBase),
            .tb = font.tb,
        };
    }

    /// The library closed and expunged, which closes truetype.library,
    /// and nothing of what the test made left behind.
    pub fn down(rig: *Rig) !void {
        rig.font.sys.CloseLibrary(rig.sb.lib());
        _ = rig.font.sys.RemLibrary(rig.library);
        try rig.font.down();
    }
};

const test_feature = [_]tts.Feature{ .{ .tag = tts.featureTag("test") }, .{ .tag = 0 } };

/// A font of 8 glyphs, each 600 wide, with the letters 'A' to 'G' as the
/// glyphs 1 to 7, and `more` beside the tables every font has.
fn fontWith(file: *builder.File, more: []const builder.Table) void {
    var letters = builder.Cmap.init(1);
    letters.begin(3, 1);
    letters.segments(&.{
        .{ .first = 'A', .last = 'G', .delta = 1 -% @as(u16, 'A') },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });
    file.* = .{};
    _ = builder.font(file, .{ .cmap = letters.written(), .more = more });
}

/// A run of `glyphs`, each its own cluster, with fields the shaping has
/// to fill set to values it would not give.
fn runOf(room: []tts.ShapedGlyph, glyphs: []const u32) tts.ShapedRun {
    for (room) |*glyph| glyph.* = .{ .glyph = 0xEEEE, .cluster = 0xEEEE, .advance = -7, .x_offset = -7, .y_offset = -7 };
    for (glyphs, 0..) |glyph, index| room[index].glyph = glyph;
    for (glyphs, 0..) |_, index| room[index].cluster = @intCast(index);
    return .{ .glyphs = room.ptr, .room = @intCast(room.len), .count = @intCast(glyphs.len) };
}

/// A `GSUB` whose feature `test` makes the glyphs 1 and 2 the glyph 3, a
/// `GPOS` whose feature `test` moves a glyph 4 behind a glyph 3 closer by
/// 50, and a `GDEF` that says nothing.
const Tables = struct {
    joined: File = .{},
    gsub: File = .{},
    closer: File = .{},
    gpos: File = .{},

    fn build(tables: *Tables) [2]builder.Table {
        subtables.ligature(&tables.joined, &.{1}, &.{&.{.{ .rest = &.{2}, .glyph = 3 }}});
        layout.tableOfOne(&tables.gsub, &.{.{ .kind = 4, .subtables = &.{tables.joined.written()} }});
        subtables.pairs(&tables.closer, &.{3}, subtables.X_ADVANCE, 0, &.{&.{.{ .second = 4, .values = &.{-50} }}});
        layout.tableOfOne(&tables.gpos, &.{.{ .kind = 2, .subtables = &.{tables.closer.written()} }});
        return .{
            .{ .tag = "GPOS", .bytes = tables.gpos.written() },
            .{ .tag = "GSUB", .bytes = tables.gsub.written() },
        };
    }
};

test "ShapeGlyphs: the font's tables applied, the advances the font's" {
    var rig = try Rig.up();
    var tables: Tables = .{};
    const more = tables.build();
    var file: builder.File = .{};
    fontWith(&file, &more);
    const outline = rig.tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    var room: [8]tts.ShapedGlyph = undefined;
    var run = runOf(&room, &.{ 1, 2, 4, 5 });
    try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeGlyphs(outline, tts.TTS_SCRIPT_DEFAULT, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &test_feature, &run));
    try testing.expectEqual(@as(u32, 3), run.count);
    try testing.expectEqual(@as(u32, 8), run.room);
    const shaped = [_]tts.ShapedGlyph{
        .{ .glyph = 3, .cluster = 0, .advance = 550, .x_offset = 0, .y_offset = 0 },
        .{ .glyph = 4, .cluster = 2, .advance = 600, .x_offset = 0, .y_offset = 0 },
        .{ .glyph = 5, .cluster = 3, .advance = 600, .x_offset = 0, .y_offset = 0 },
    };
    for (shaped, room[0..3]) |want, found| try testing.expectEqual(want, found);
    // What is behind the shaped run is not written.
    try testing.expectEqual(@as(u32, 5), room[3].glyph);
    try testing.expectEqual(@as(i32, -7), room[3].advance);
    try testing.expectEqual(@as(u32, 0xEEEE), room[4].glyph);

    // The same from the end of the line: the run comes back turned around.
    run = runOf(&room, &.{ 1, 2, 4, 5 });
    try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeGlyphs(outline, tts.TTS_SCRIPT_DEFAULT, tts.TTS_RIGHT_TO_LEFT, tts.TTS_LANGUAGE_DEFAULT, &test_feature, &run));
    try testing.expectEqual(@as(u32, 3), run.count);
    for ([_]u32{ 5, 4, 3 }, [_]u32{ 3, 2, 0 }, [_]i32{ 600, 600, 550 }, room[0..3]) |glyph, cluster, advance, found| {
        try testing.expectEqual(glyph, found.glyph);
        try testing.expectEqual(cluster, found.cluster);
        try testing.expectEqual(advance, found.advance);
    }

    rig.tb.CloseOutline(outline);
    try rig.down();
}

test "ShapeGlyphs: no features, and a font with no tables" {
    var rig = try Rig.up();
    var tables: Tables = .{};
    const more = tables.build();
    var file: builder.File = .{};
    fontWith(&file, &more);
    const outline = rig.tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    // No list, and a list of none: the glyphs as they came, with their
    // advances.
    const none = [_]tts.Feature{.{ .tag = 0 }};
    for ([_]?[*]const tts.Feature{ null, &none }) |features| {
        var room: [4]tts.ShapedGlyph = undefined;
        var run = runOf(&room, &.{ 1, 2, 4 });
        try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeGlyphs(outline, tts.TTS_SCRIPT_DEFAULT, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, features, &run));
        try testing.expectEqual(@as(u32, 3), run.count);
        for ([_]u32{ 1, 2, 4 }, room[0..3], 0..) |glyph, found, index| {
            try testing.expectEqual(tts.ShapedGlyph{ .glyph = glyph, .cluster = @intCast(index), .advance = 600, .x_offset = 0, .y_offset = 0 }, found);
        }
    }
    rig.tb.CloseOutline(outline);

    // A font without layout tables: the same, whatever is asked for.
    var plain: builder.File = .{};
    fontWith(&plain, &.{});
    const bare = rig.tb.OpenOutline(&plain.bytes, plain.len, null) orelse return error.NotRead;
    var room: [4]tts.ShapedGlyph = undefined;
    var run = runOf(&room, &.{ 1, 2, 4 });
    try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeGlyphs(bare, tts.scriptTag("latn"), tts.TTS_LEFT_TO_RIGHT, tts.languageTag("DEU "), &test_feature, &run));
    try testing.expectEqual(@as(u32, 3), run.count);
    for ([_]u32{ 1, 2, 4 }, room[0..3]) |glyph, found| {
        try testing.expectEqual(glyph, found.glyph);
        try testing.expectEqual(@as(i32, 600), found.advance);
    }
    // A glyph the font does not have has no advance.
    run = runOf(&room, &.{ 1, 900 });
    try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeGlyphs(bare, tts.TTS_SCRIPT_DEFAULT, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, null, &run));
    try testing.expectEqual(@as(u32, 900), room[1].glyph);
    try testing.expectEqual(@as(i32, 0), room[1].advance);
    // An empty run stays one.
    run = runOf(&room, &.{});
    try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeGlyphs(bare, tts.TTS_SCRIPT_DEFAULT, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &test_feature, &run));
    try testing.expectEqual(@as(u32, 0), run.count);

    rig.tb.CloseOutline(bare);
    try rig.down();
}

test "ShapeGlyphs: a run that needs more room says how much and writes nothing" {
    var rig = try Rig.up();
    var tripled: File = .{};
    subtables.multiple(&tripled, &.{1}, &.{&.{ 5, 6, 7 }});
    var gsub: File = .{};
    layout.tableOfOne(&gsub, &.{.{ .kind = 2, .subtables = &.{tripled.written()} }});
    var file: builder.File = .{};
    fontWith(&file, &.{.{ .tag = "GSUB", .bytes = gsub.written() }});
    const outline = rig.tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    var room: [6]tts.ShapedGlyph = undefined;
    var run = runOf(room[0..4], &.{ 1, 2, 1 });
    try testing.expectEqual(tts.TTSERR_ROOM, rig.sb.ShapeGlyphs(outline, tts.TTS_SCRIPT_DEFAULT, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &test_feature, &run));
    try testing.expectEqual(@as(u32, 7), run.count);
    try testing.expectEqual(@as(u32, 4), run.room);
    for ([_]u32{ 1, 2, 1, 0xEEEE }, room[0..4]) |glyph, found| {
        try testing.expectEqual(glyph, found.glyph);
        try testing.expectEqual(@as(i32, -7), found.advance);
    }

    // With the room it asked for, the run of before shapes.
    var wide: [7]tts.ShapedGlyph = undefined;
    run = runOf(&wide, &.{ 1, 2, 1 });
    try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeGlyphs(outline, tts.TTS_SCRIPT_DEFAULT, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &test_feature, &run));
    try testing.expectEqual(@as(u32, 7), run.count);
    for ([_]u32{ 5, 6, 7, 2, 5, 6, 7 }, [_]u32{ 0, 0, 0, 1, 2, 2, 2 }, wide) |glyph, cluster, found| {
        try testing.expectEqual(glyph, found.glyph);
        try testing.expectEqual(cluster, found.cluster);
    }

    rig.tb.CloseOutline(outline);
    try rig.down();
}

test "ShapeGlyphs: errors of the call" {
    var rig = try Rig.up();
    var tables: Tables = .{};
    const more = tables.build();
    var file: builder.File = .{};
    fontWith(&file, &more);
    const outline = rig.tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    // A direction that is none: nothing is done.
    var room: [4]tts.ShapedGlyph = undefined;
    var run = runOf(&room, &.{ 1, 2 });
    try testing.expectEqual(tts.TTSERR_DIRECTION, rig.sb.ShapeGlyphs(outline, tts.TTS_SCRIPT_DEFAULT, 2, tts.TTS_LANGUAGE_DEFAULT, &test_feature, &run));
    try testing.expectEqual(@as(u32, 2), run.count);
    try testing.expectEqual(@as(u32, 1), room[0].glyph);
    try testing.expectEqual(@as(i32, -7), room[0].advance);

    // More features for parts of the run than a call takes.
    var features: [33]tts.Feature = undefined;
    for (features[0..32], 0..) |*feature, index| {
        feature.* = .{ .tag = tts.featureTag("aaaa") + @as(u32, @intCast(index)), .first = 0, .last = 0 };
    }
    features[32] = .{ .tag = 0 };
    try testing.expectEqual(tts.TTSERR_FEATURES, rig.sb.ShapeGlyphs(outline, tts.TTS_SCRIPT_DEFAULT, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &features, &run));
    try testing.expectEqual(@as(u32, 2), run.count);
    try testing.expectEqual(@as(i32, -7), room[0].advance);

    rig.tb.CloseOutline(outline);
    try rig.down();
}

test "ShapeGlyphs: tables cut short or made of anything end the call" {
    var rig = try Rig.up();
    var tables: Tables = .{};
    const more = tables.build();
    var room: [16]tts.ShapedGlyph = undefined;

    // The substitution table cut at every length, the font around it whole.
    var length: usize = 0;
    while (length < more[1].bytes.len) : (length += 1) {
        var file: builder.File = .{};
        fontWith(&file, &.{ more[0], .{ .tag = "GSUB", .bytes = more[1].bytes[0..length] } });
        const outline = rig.tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
        var run = runOf(&room, &.{ 1, 2, 4, 5 });
        const result = rig.sb.ShapeGlyphs(outline, tts.TTS_SCRIPT_DEFAULT, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &test_feature, &run);
        try testing.expectEqual(tts.TTS_OK, result);
        try testing.expect(run.count == 3 or run.count == 4);
        rig.tb.CloseOutline(outline);
    }

    try rig.down();
}

/// A `GSUB` whose feature `liga` makes the glyphs 1 and 2 the glyph 3,
/// and a `GPOS` whose feature `kern` moves a glyph 4 behind a glyph 3
/// closer by 50: two of the features a text is shaped with unasked.
const TextTables = struct {
    joined: File = .{},
    gsub: File = .{},
    closer: File = .{},
    gpos: File = .{},

    fn build(tables: *TextTables) [2]builder.Table {
        subtables.ligature(&tables.joined, &.{1}, &.{&.{.{ .rest = &.{2}, .glyph = 3 }}});
        layout.table(&tables.gsub, &.{.{ .tag = "liga", .lookups = &.{0} }}, &.{.{ .kind = 4, .subtables = &.{tables.joined.written()} }});
        subtables.pairs(&tables.closer, &.{3}, subtables.X_ADVANCE, 0, &.{&.{.{ .second = 4, .values = &.{-50} }}});
        layout.table(&tables.gpos, &.{.{ .tag = "kern", .lookups = &.{0} }}, &.{.{ .kind = 2, .subtables = &.{tables.closer.written()} }});
        return .{
            .{ .tag = "GPOS", .bytes = tables.gpos.written() },
            .{ .tag = "GSUB", .bytes = tables.gsub.written() },
        };
    }
};

/// A run over `room` with every field set to a value the shaping would
/// not give - its count too, which ShapeText does not read.
fn runFor(room: []tts.ShapedGlyph) tts.ShapedRun {
    for (room) |*glyph| glyph.* = .{ .glyph = 0xEEEE, .cluster = 0xEEEE, .advance = -7, .x_offset = -7, .y_offset = -7 };
    return .{ .glyphs = room.ptr, .room = @intCast(room.len), .count = 0xDEAD };
}

/// `text` shaped from left to right with the features a text has.
fn shapeText(rig: *Rig, outline: *truetype.Outline, text: []const u8, run: *tts.ShapedRun) i32 {
    return rig.sb.ShapeText(outline, text.ptr, @intCast(text.len), tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, null, run);
}

/// `run` is `expected`: each glyph's number, cluster and advance, and no
/// offsets.
fn expectShaped(run: *const tts.ShapedRun, expected: []const [3]i32) !void {
    try testing.expectEqual(expected.len, @as(usize, run.count));
    for (expected, run.glyphs[0..run.count]) |want, found| {
        try testing.expectEqual(tts.ShapedGlyph{ .glyph = @intCast(want[0]), .cluster = @intCast(want[1]), .advance = want[2], .x_offset = 0, .y_offset = 0 }, found);
    }
}

test "ShapeText: a text's characters as the font's glyphs, shaped by its tables" {
    var rig = try Rig.up();
    var tables: TextTables = .{};
    const more = tables.build();
    var file: builder.File = .{};
    fontWith(&file, &more);
    const outline = rig.tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    var room: [8]tts.ShapedGlyph = undefined;
    var run = runFor(&room);
    try testing.expectEqual(tts.TTS_OK, shapeText(&rig, outline, "ABDE", &run));
    try testing.expectEqual(@as(u32, 8), run.room);
    try expectShaped(&run, &.{ .{ 3, 0, 550 }, .{ 4, 2, 600 }, .{ 5, 3, 600 } });
    // What is behind the shaped run is not written.
    try testing.expectEqual(@as(u32, 0xEEEE), room[3].glyph);
    try testing.expectEqual(@as(i32, -7), room[3].advance);

    // From the end of the line: the same, turned around.
    run = runFor(&room);
    try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeText(outline, "ABDE", 4, tts.TTS_RIGHT_TO_LEFT, tts.TTS_LANGUAGE_DEFAULT, null, &run));
    try expectShaped(&run, &.{ .{ 5, 3, 600 }, .{ 4, 2, 600 }, .{ 3, 0, 550 } });

    // A soft hyphen is no glyph of the run and the two join across it; a
    // character the font lacks is glyph 0.
    run = runFor(&room);
    try testing.expectEqual(tts.TTS_OK, shapeText(&rig, outline, "A\u{AD}BDxE", &run));
    try expectShaped(&run, &.{ .{ 3, 0, 550 }, .{ 4, 4, 600 }, .{ 0, 5, 600 }, .{ 5, 6, 600 } });

    // A feature of the text's own switched off, and a language the font
    // does not list.
    const apart = [_]tts.Feature{ .{ .tag = tts.featureTag("liga"), .value = 0 }, .{ .tag = 0 } };
    run = runFor(&room);
    try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeText(outline, "ABDE", 4, tts.TTS_LEFT_TO_RIGHT, tts.languageTag("TRK "), &apart, &run));
    try expectShaped(&run, &.{ .{ 1, 0, 600 }, .{ 2, 1, 600 }, .{ 4, 2, 600 }, .{ 5, 3, 600 } });

    // For a part of the text: the bytes 2 to 3.
    const partly = [_]tts.Feature{ .{ .tag = tts.featureTag("liga"), .value = 0, .first = 2, .last = 3 }, .{ .tag = 0 } };
    run = runFor(&room);
    try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeText(outline, "ABABAB", 6, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &partly, &run));
    try expectShaped(&run, &.{ .{ 3, 0, 600 }, .{ 1, 2, 600 }, .{ 2, 3, 600 }, .{ 3, 4, 600 } });

    rig.tb.CloseOutline(outline);
    try rig.down();
}

test "ShapeText: the font's kern table, its variation sequences and a character past U+FFFF" {
    var rig = try Rig.up();
    var file: builder.File = .{};
    builder.whole(&file);
    const outline = rig.tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    // The font has no `GPOS`: its `kern` table sets 'A' and 'B' closer
    // by 50 and 'B' and 'C' apart by 20.
    var room: [8]tts.ShapedGlyph = undefined;
    var run = runFor(&room);
    try testing.expectEqual(tts.TTS_OK, shapeText(&rig, outline, "ABCD", &run));
    try expectShaped(&run, &.{ .{ 1, 0, 550 }, .{ 2, 1, 620 }, .{ 3, 2, 600 }, .{ 4, 3, 600 } });

    // The pairs are the ones drawn: read from right to left "DCBA" is
    // drawn as the text before, and "ABCD" has none of the table's.
    run = runFor(&room);
    try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeText(outline, "DCBA", 4, tts.TTS_RIGHT_TO_LEFT, tts.TTS_LANGUAGE_DEFAULT, null, &run));
    try expectShaped(&run, &.{ .{ 1, 3, 550 }, .{ 2, 2, 620 }, .{ 3, 1, 600 }, .{ 4, 0, 600 } });
    run = runFor(&room);
    try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeText(outline, "ABCD", 4, tts.TTS_RIGHT_TO_LEFT, tts.TTS_LANGUAGE_DEFAULT, null, &run));
    try expectShaped(&run, &.{ .{ 4, 3, 600 }, .{ 3, 2, 600 }, .{ 2, 1, 600 }, .{ 1, 0, 600 } });

    const unkerned = [_]tts.Feature{ .{ .tag = tts.featureTag("kern"), .value = 0 }, .{ .tag = 0 } };
    run = runFor(&room);
    try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeText(outline, "ABCD", 4, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &unkerned, &run));
    try expectShaped(&run, &.{ .{ 1, 0, 600 }, .{ 2, 1, 600 }, .{ 3, 2, 600 }, .{ 4, 3, 600 } });

    // 'A' with its selector is a glyph of its own, 'B' with it stays 'B',
    // and behind 'D' the selector is nothing the font knows: it goes.
    run = runFor(&room);
    try testing.expectEqual(tts.TTS_OK, shapeText(&rig, outline, "A\u{FE00}B\u{FE00}D\u{FE00}\u{1F600}", &run));
    try expectShaped(&run, &.{ .{ 5, 0, 600 }, .{ 2, 4, 600 }, .{ 4, 8, 600 }, .{ 11, 12, 600 } });

    rig.tb.CloseOutline(outline);
    try rig.down();
}

test "ShapeText: a text that needs more room says how much" {
    var rig = try Rig.up();
    var tables: TextTables = .{};
    const more = tables.build();
    var file: builder.File = .{};
    fontWith(&file, &more);
    const outline = rig.tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    var room: [3]tts.ShapedGlyph = undefined;
    var run = runFor(&room);
    run.room = 2;
    try testing.expectEqual(tts.TTSERR_ROOM, shapeText(&rig, outline, "ABDE", &run));
    try testing.expectEqual(@as(u32, 3), run.count);
    try testing.expectEqual(@as(u32, 2), run.room);
    // Past the room nothing is written.
    try testing.expectEqual(@as(u32, 0xEEEE), room[2].glyph);

    // With the room it asked for, the text of before shapes.
    run = runFor(&room);
    try testing.expectEqual(tts.TTS_OK, shapeText(&rig, outline, "ABDE", &run));
    try expectShaped(&run, &.{ .{ 3, 0, 550 }, .{ 4, 2, 600 }, .{ 5, 3, 600 } });

    // A text of no bytes is a run of no glyphs, with no room either.
    run = runFor(room[0..0]);
    try testing.expectEqual(tts.TTS_OK, shapeText(&rig, outline, "", &run));
    try testing.expectEqual(@as(u32, 0), run.count);

    rig.tb.CloseOutline(outline);
    try rig.down();
}

test "ShapeText: errors of the call" {
    var rig = try Rig.up();
    var tables: TextTables = .{};
    const more = tables.build();
    var file: builder.File = .{};
    fontWith(&file, &more);
    const outline = rig.tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    // A direction that is none: nothing is done.
    var room: [4]tts.ShapedGlyph = undefined;
    var run = runFor(&room);
    try testing.expectEqual(tts.TTSERR_DIRECTION, rig.sb.ShapeText(outline, "AB", 2, 2, tts.TTS_LANGUAGE_DEFAULT, null, &run));
    try testing.expectEqual(@as(u32, 0xDEAD), run.count);
    try testing.expectEqual(@as(u32, 0xEEEE), room[0].glyph);

    // More features for parts of the text than a call takes.
    var features: [33]tts.Feature = undefined;
    for (features[0..32], 0..) |*feature, index| {
        feature.* = .{ .tag = tts.featureTag("aaaa") + @as(u32, @intCast(index)), .first = 0, .last = 0 };
    }
    features[32] = .{ .tag = 0 };
    try testing.expectEqual(tts.TTSERR_FEATURES, rig.sb.ShapeText(outline, "AB", 2, tts.TTS_LEFT_TO_RIGHT, tts.TTS_LANGUAGE_DEFAULT, &features, &run));
    try testing.expectEqual(@as(u32, 0xDEAD), run.count);
    try testing.expectEqual(@as(u32, 0xEEEE), room[0].glyph);

    rig.tb.CloseOutline(outline);
    try rig.down();
}

test "ShapeText: tables cut short end the call" {
    var rig = try Rig.up();
    var tables: TextTables = .{};
    const more = tables.build();
    var room: [16]tts.ShapedGlyph = undefined;

    // Each of the two tables cut at every length, the font around it whole.
    for (more, 0..) |whole, which| {
        var length: usize = 0;
        while (length < whole.bytes.len) : (length += 1) {
            var cut = more;
            cut[which].bytes = whole.bytes[0..length];
            var file: builder.File = .{};
            fontWith(&file, &cut);
            const outline = rig.tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
            var run = runFor(&room);
            try testing.expectEqual(tts.TTS_OK, shapeText(&rig, outline, "ABDE", &run));
            try testing.expect(run.count == 3 or run.count == 4);
            rig.tb.CloseOutline(outline);
        }
    }

    try rig.down();
}

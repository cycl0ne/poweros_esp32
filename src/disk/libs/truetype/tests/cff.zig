// SPDX-License-Identifier: MIT
//! Host tests of a font's cubic outlines, on `CFF ` tables the tests
//! build: what a glyph's program draws, operator by operator; its
//! subroutines, numbers, widths and hints; a table of many fonts under
//! one set of glyphs; the room a glyph is read into; programs and
//! tables that are damaged; a glyph's box; and what is rendered.
//!
//! A program is written as text (`builder.program`) and put into a
//! table (`builder.cff`) of a font that starts 'OTTO' and has no `glyf`.
//! What each draws was worked out apart from this library, by fontTools
//! from the same text, and stands beside it: a letter a verb - M a move,
//! L a line, C a cubic curve, Z a close - and the points they take. The
//! operators that calculate are the exception: fontTools does not run
//! them, and what stands beside those programs follows from what each
//! is defined to do. What a real font's programs draw is `fonts.zig`'s.

const std = @import("std");
const sdk = @import("sdk");
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const truetype = sdk.truetype;
const vector = sdk.vector;
const builder = @import("builder.zig");
const Rig = @import("truetype.zig").Rig;

const testing = std.testing;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;

/// A program and what it draws.
const Drawn = struct {
    program: []const u8,
    verbs: []const u8,
    points: []const [2]f32,
};

/// A font that starts 'OTTO', without `glyf`, of the `CFF ` table
/// `parts` make, alone in `file`: a glyph a program. `largest` gives it a
/// `maxp` that names a largest glyph, of four points in one contour.
pub fn build(file: *builder.File, parts: builder.CffParts, largest: bool) void {
    var table: builder.File = .{};
    builder.cff(&table, parts);
    wrap(file, "CFF ", table.written(), @intCast(parts.glyphs.len), largest);
}

/// The same around a table already written, under `tag`; 'A' is glyph 1.
fn wrap(file: *builder.File, tag: *const [4]u8, table: []const u8, glyphs: u16, largest: bool) void {
    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    cmap.segments(&.{
        .{ .first = 'A', .last = 'A', .delta = 1 -% @as(u16, 'A') },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });
    file.* = .{};
    _ = builder.font(file, .{
        .cmap = cmap.written(),
        .glyphs = glyphs,
        .outlines = false,
        .tag = 0x4F54_544F,
        .largest = largest,
        .more = &.{.{ .tag = tag, .bytes = table }},
    });
}

fn verbOf(letter: u8) u8 {
    return switch (letter) {
        'M' => vector.SEG_MOVE,
        'L' => vector.SEG_LINE,
        'C' => vector.SEG_CUBIC,
        'Z' => vector.SEG_CLOSE,
        else => unreachable,
    };
}

/// Room for the segments of any glyph the tests here draw.
const most_verbs = 512;
const most_points = 1024;

/// `glyph` of `outline` is drawn with `verbs` through `points`, and its
/// box is the box of those points, widened to whole units.
pub fn expectDrawn(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, verbs: []const u8, points: []const [2]f32) !void {
    var got_verbs: [most_verbs]u8 = undefined;
    var got_points: [most_points]vector.Point = undefined;
    var segments = truetype.Segments{ .verbs = &got_verbs, .points = &got_points, .verb_room = most_verbs, .point_room = most_points };
    const answer = tb.GlyphSegments(outline, glyph, &segments);
    errdefer {
        std.debug.print("glyph {d} answers {d}, {d} verbs:", .{ glyph, answer, segments.verb_count });
        for (got_verbs[0..@min(segments.verb_count, most_verbs)]) |verb| std.debug.print(" {d}", .{verb});
        std.debug.print("\n{d} points:", .{segments.point_count});
        for (got_points[0..@min(segments.point_count, most_points)]) |p| std.debug.print(" ({d}, {d})", .{ p.x, p.y });
        std.debug.print("\n", .{});
    }
    try testing.expectEqual(truetype.TRUETYPE_OK, answer);
    try testing.expectEqual(verbs.len, segments.verb_count);
    for (verbs, 0..) |letter, i| try testing.expectEqual(verbOf(letter), got_verbs[i]);
    try testing.expectEqual(points.len, segments.point_count);
    for (points, 0..) |p, i| {
        try testing.expectEqual(p[0], got_points[i].x);
        try testing.expectEqual(p[1], got_points[i].y);
    }

    var box = [4]i32{ 0, 0, 0, 0 };
    for (points, 0..) |p, i| {
        const low = [2]i32{ @intFromFloat(@floor(p[0])), @intFromFloat(@floor(p[1])) };
        const high = [2]i32{ @intFromFloat(@ceil(p[0])), @intFromFloat(@ceil(p[1])) };
        if (i == 0) box = .{ low[0], low[1], high[0], high[1] };
        box = .{ @min(box[0], low[0]), @min(box[1], low[1]), @max(box[2], high[0]), @max(box[3], high[1]) };
    }
    var measures: truetype.GlyphMetrics = .{};
    try testing.expect(tb.GlyphMetrics(outline, glyph, &measures));
    errdefer std.debug.print("glyph {d}'s box is {d}, {d} to {d}, {d}\n", .{ glyph, measures.x_min, measures.y_min, measures.x_max, measures.y_max });
    try testing.expectEqual(box, [4]i32{ measures.x_min, measures.y_min, measures.x_max, measures.y_max });
}

/// A font of `parts`, whose glyphs are `cases`' programs in their
/// order, draws each as it says.
fn expectAllDrawn(comptime cases: []const Drawn, parts: builder.CffParts, largest: bool) !void {
    var rig = try Rig.up();
    const tb = rig.tb;
    var file: builder.File = .{};
    var with = parts;
    with.glyphs = comptime programs: {
        var list: [cases.len][]const u8 = undefined;
        for (cases, 0..) |case, i| list[i] = case.program;
        const all = list;
        break :programs &all;
    };
    build(&file, with, largest);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    for (cases, 0..) |case, glyph| try expectDrawn(tb, outline, @intCast(glyph), case.verbs, case.points);
    tb.CloseOutline(outline);
    try rig.down();
}

const drawn = [_]Drawn{
    // Moves and lines.
    .{
        .program = builder.program("100 200 rmoveto 50 hlineto 60 vlineto -50 -60 rlineto endchar"),
        .verbs = "MLLLZ",
        .points = &.{ .{ 100, 200 }, .{ 150, 200 }, .{ 150, 260 }, .{ 100, 200 } },
    },
    .{
        .program = builder.program("10 hmoveto 20 30 rlineto 40 -50 rlineto 5 vmoveto 7 9 rlineto -3 4 rlineto endchar"),
        .verbs = "MLLZMLLZ",
        .points = &.{ .{ 10, 0 }, .{ 30, 30 }, .{ 70, -20 }, .{ 70, -15 }, .{ 77, -6 }, .{ 74, -2 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 50 hlineto 60 70 80 vlineto endchar"),
        .verbs = "MLLLLLLLLZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 20 }, .{ 40, 20 }, .{ 40, 60 }, .{ 90, 60 }, .{ 90, 120 }, .{ 160, 120 }, .{ 160, 200 } },
    },
    // A line before any move starts where the program does.
    .{
        .program = builder.program("10 20 rlineto 30 0 rlineto endchar"),
        .verbs = "MLLZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 20 }, .{ 40, 20 } },
    },
    // Each kind of curve.
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 50 60 -10 -20 -30 -40 -50 -60 rrcurveto endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 20 }, .{ 40, 60 }, .{ 90, 120 }, .{ 80, 100 }, .{ 50, 60 }, .{ 0, 0 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 1 2 3 4 5 6 7 8 9 10 11 12 100 200 rcurveline endchar"),
        .verbs = "MCCLZ",
        .points = &.{ .{ 0, 0 }, .{ 1, 2 }, .{ 4, 6 }, .{ 9, 12 }, .{ 16, 20 }, .{ 25, 30 }, .{ 36, 42 }, .{ 136, 242 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 1 2 3 4 10 20 30 40 50 60 rlinecurve endchar"),
        .verbs = "MLLCZ",
        .points = &.{ .{ 0, 0 }, .{ 1, 2 }, .{ 4, 6 }, .{ 14, 26 }, .{ 44, 66 }, .{ 94, 126 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 50 60 70 80 vvcurveto endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 0, 10 }, .{ 20, 40 }, .{ 20, 80 }, .{ 20, 130 }, .{ 80, 200 }, .{ 80, 280 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 5 10 20 30 40 50 60 70 80 vvcurveto endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 5, 10 }, .{ 25, 40 }, .{ 25, 80 }, .{ 25, 130 }, .{ 85, 200 }, .{ 85, 280 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 50 60 70 80 hhcurveto endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 30, 30 }, .{ 70, 30 }, .{ 120, 30 }, .{ 180, 100 }, .{ 260, 100 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 5 10 20 30 40 50 60 70 80 hhcurveto endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 5 }, .{ 30, 35 }, .{ 70, 35 }, .{ 120, 35 }, .{ 180, 105 }, .{ 260, 105 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 vhcurveto endchar"),
        .verbs = "MCZ",
        .points = &.{ .{ 0, 0 }, .{ 0, 10 }, .{ 20, 40 }, .{ 60, 40 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 50 60 70 80 vhcurveto endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 0, 10 }, .{ 20, 40 }, .{ 60, 40 }, .{ 110, 40 }, .{ 170, 110 }, .{ 170, 190 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 50 60 70 80 90 vhcurveto endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 0, 10 }, .{ 20, 40 }, .{ 60, 40 }, .{ 110, 40 }, .{ 170, 110 }, .{ 260, 190 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 50 60 70 80 90 100 110 120 vhcurveto endchar"),
        .verbs = "MCCCZ",
        .points = &.{ .{ 0, 0 }, .{ 0, 10 }, .{ 20, 40 }, .{ 60, 40 }, .{ 110, 40 }, .{ 170, 110 }, .{ 170, 190 }, .{ 170, 280 }, .{ 270, 390 }, .{ 390, 390 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 5 vhcurveto endchar"),
        .verbs = "MCZ",
        .points = &.{ .{ 0, 0 }, .{ 0, 10 }, .{ 20, 40 }, .{ 60, 45 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 hvcurveto endchar"),
        .verbs = "MCZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 30, 30 }, .{ 30, 70 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 50 60 70 80 hvcurveto endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 30, 30 }, .{ 30, 70 }, .{ 30, 120 }, .{ 90, 190 }, .{ 170, 190 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 50 60 70 80 90 hvcurveto endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 30, 30 }, .{ 30, 70 }, .{ 30, 120 }, .{ 90, 190 }, .{ 170, 280 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 5 hvcurveto endchar"),
        .verbs = "MCZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 30, 30 }, .{ 35, 70 } },
    },
    // Two curves in one.
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 50 60 70 hflex endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 30, 30 }, .{ 70, 30 }, .{ 120, 30 }, .{ 180, 0 }, .{ 250, 0 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 1 2 3 4 5 6 7 8 9 10 11 12 50 flex endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 1, 2 }, .{ 4, 6 }, .{ 9, 12 }, .{ 16, 20 }, .{ 25, 30 }, .{ 36, 42 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 50 60 70 80 90 hflex1 endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 20 }, .{ 40, 60 }, .{ 90, 60 }, .{ 150, 60 }, .{ 220, 140 }, .{ 310, 0 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 10 1 20 2 30 3 40 4 50 5 60 flex1 endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 1 }, .{ 30, 3 }, .{ 60, 6 }, .{ 100, 10 }, .{ 150, 15 }, .{ 210, 0 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 1 10 2 20 3 30 4 40 5 50 60 flex1 endchar"),
        .verbs = "MCCZ",
        .points = &.{ .{ 0, 0 }, .{ 1, 10 }, .{ 3, 30 }, .{ 6, 60 }, .{ 10, 100 }, .{ 15, 150 }, .{ 0, 210 } },
    },
    // Numbers in each of their forms.
    .{
        .program = builder.program("107 -107 rmoveto 108 -108 rlineto 1131 -1131 rlineto 1132 -1132 rlineto s:5 s:-5 rlineto f:3 f:-3 rlineto 0.5 -0.25 rlineto endchar"),
        .verbs = "MLLLLLLZ",
        .points = &.{ .{ 107, -107 }, .{ 215, -215 }, .{ 1346, -1346 }, .{ 2478, -2478 }, .{ 2483, -2483 }, .{ 2486, -2486 }, .{ 2486.5, -2486.25 } },
    },
    // The width before the first move, each kind, and before the end.
    .{
        .program = builder.program("500 10 20 rmoveto 5 5 rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 10, 20 }, .{ 15, 25 } },
    },
    .{
        .program = builder.program("500 10 hmoveto 5 5 rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 10, 0 }, .{ 15, 5 } },
    },
    .{
        .program = builder.program("500 10 vmoveto 5 5 rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 0, 10 }, .{ 5, 15 } },
    },
    .{
        .program = builder.program("500 endchar"),
        .verbs = "",
        .points = &.{},
    },
    // Hints: stems counted for the mask's length, the width before them.
    .{
        .program = builder.program("500 10 20 30 40 hstem 5 6 vstem 0 0 rmoveto 9 9 rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 0, 0 }, .{ 9, 9 } },
    },
    .{
        .program = builder.program("10 20 hstemhm 30 40 vstemhm hintmask #c0 0 0 rmoveto 9 9 rlineto cntrmask #80 1 1 rlineto endchar"),
        .verbs = "MLLZ",
        .points = &.{ .{ 0, 0 }, .{ 9, 9 }, .{ 10, 10 } },
    },
    .{
        .program = builder.program("500 1 2 hstemhm 3 4 5 6 hintmask #e0 7 hmoveto 9 9 rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 7, 0 }, .{ 16, 9 } },
    },
    .{
        .program = builder.program("1 2 3 4 5 6 7 8 9 10 hstemhm 1 2 3 4 5 6 7 8 vstemhm cntrmask #ff #80 3 3 rmoveto 9 9 rlineto hintmask #00 #00 1 1 rlineto endchar"),
        .verbs = "MLLZ",
        .points = &.{ .{ 3, 3 }, .{ 12, 12 }, .{ 13, 13 } },
    },
    // A move nothing is drawn from is no contour.
    .{
        .program = builder.program("5 5 rmoveto 10 10 rmoveto 1 2 rlineto 50 hmoveto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 15, 15 }, .{ 16, 17 } },
    },
};

test "cubic outlines: what each operator of a program draws" {
    // With the room of a font that does not name its largest glyph, and
    // with one that names a smaller: each glyph read once more.
    try expectAllDrawn(&drawn, .{ .glyphs = &.{} }, false);
    try expectAllDrawn(&drawn, .{ .glyphs = &.{} }, true);
}

// --- subroutines ---------------------------------------------------------------

const few_locals = [_][]const u8{
    builder.program("10 20 rlineto return"),
    builder.program("30 hlineto -107 callsubr return"),
    builder.program("1 2 3 4 5 6 rrcurveto"),
    builder.program("7 7 rmoveto -107 callgsubr return"),
    builder.program("50 60 return"),
    builder.program("3 3 rlineto endchar"),
};

const few_globals = [_][]const u8{
    builder.program("-9 -9 rlineto return"),
    builder.program("-105 callsubr return"),
};

const few = [_]Drawn{
    // A local one, and one that calls another.
    .{
        .program = builder.program("0 0 rmoveto -107 callsubr endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 20 } },
    },
    .{
        .program = builder.program("0 0 rmoveto -106 callsubr 4 4 rlineto endchar"),
        .verbs = "MLLLZ",
        .points = &.{ .{ 0, 0 }, .{ 30, 0 }, .{ 40, 20 }, .{ 44, 24 } },
    },
    // One that ends without saying so.
    .{
        .program = builder.program("0 0 rmoveto -105 callsubr 9 9 rlineto endchar"),
        .verbs = "MCLZ",
        .points = &.{ .{ 0, 0 }, .{ 1, 2 }, .{ 4, 6 }, .{ 9, 12 }, .{ 18, 21 } },
    },
    // A local one that calls a global one, and the other way round.
    .{
        .program = builder.program("-104 callsubr 2 2 rlineto endchar"),
        .verbs = "MLLZ",
        .points = &.{ .{ 7, 7 }, .{ -2, -2 }, .{ 0, 0 } },
    },
    .{
        .program = builder.program("1 1 rmoveto -106 callgsubr -107 callgsubr endchar"),
        .verbs = "MCLZ",
        .points = &.{ .{ 1, 1 }, .{ 2, 3 }, .{ 5, 7 }, .{ 10, 13 }, .{ 1, 4 } },
    },
    // One that only leaves numbers, for the line and for the width and the move.
    .{
        .program = builder.program("0 0 rmoveto -103 callsubr rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 0, 0 }, .{ 50, 60 } },
    },
    .{
        .program = builder.program("500 -103 callsubr rmoveto 1 1 rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 50, 60 }, .{ 51, 61 } },
    },
    // The glyph ended inside one.
    .{
        .program = builder.program("2 2 rmoveto 8 8 rlineto -102 callsubr"),
        .verbs = "MLLZ",
        .points = &.{ .{ 2, 2 }, .{ 10, 10 }, .{ 13, 13 } },
    },
};

const many = [_]Drawn{
    // The first, the one called by 0 and the last of 1240, local and global.
    .{
        .program = builder.program("0 0 rmoveto -1131 callsubr 0 callsubr 108 callsubr -1131 callgsubr 0 callgsubr 108 callgsubr endchar"),
        .verbs = "MLLLLLLZ",
        .points = &.{ .{ 0, 0 }, .{ 11, 12 }, .{ 44, 46 }, .{ 99, 102 }, .{ 121, 125 }, .{ 165, 170 }, .{ 231, 237 } },
    },
};

const deep_locals = [_][]const u8{
    builder.program("1 1 rlineto -106 callsubr return"),
    builder.program("1 1 rlineto -105 callsubr return"),
    builder.program("1 1 rlineto -104 callsubr return"),
    builder.program("1 1 rlineto -103 callsubr return"),
    builder.program("1 1 rlineto -102 callsubr return"),
    builder.program("1 1 rlineto -101 callsubr return"),
    builder.program("1 1 rlineto -100 callsubr return"),
    builder.program("1 1 rlineto -99 callsubr return"),
    builder.program("1 1 rlineto -98 callsubr return"),
    builder.program("2 2 rlineto return"),
};

const deep = [_]Drawn{
    // Ten, each called by the one before.
    .{
        .program = builder.program("0 0 rmoveto -107 callsubr endchar"),
        .verbs = "MLLLLLLLLLLZ",
        .points = &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 }, .{ 4, 4 }, .{ 5, 5 }, .{ 6, 6 }, .{ 7, 7 }, .{ 8, 8 }, .{ 9, 9 }, .{ 11, 11 } },
    },
};

/// 1240 subroutines, as many as are numbered from -1131: each returns
/// at once but the first, the one 0 calls and the last, which draw a
/// line `first`, `middle` and `last` units right and one more up.
fn manyOf(comptime first: u32, comptime middle: u32, comptime last: u32) [1240][]const u8 {
    comptime {
        var all: [1240][]const u8 = @splat(builder.program("return"));
        all[0] = builder.program(std.fmt.comptimePrint("{d} {d} rlineto return", .{ first, first + 1 }));
        all[1131] = builder.program(std.fmt.comptimePrint("{d} {d} rlineto return", .{ middle, middle + 1 }));
        all[1239] = builder.program(std.fmt.comptimePrint("{d} {d} rlineto return", .{ last, last + 1 }));
        return all;
    }
}

const many_locals = manyOf(11, 33, 55);
const many_globals = manyOf(22, 44, 66);

test "cubic outlines: subroutines local and global, one in another, numbered from -107 and from -1131" {
    try expectAllDrawn(&few, .{ .glyphs = &.{}, .locals = &few_locals, .globals = &few_globals }, false);
    try expectAllDrawn(&many, .{ .glyphs = &.{}, .locals = &many_locals, .globals = &many_globals }, false);
    try expectAllDrawn(&deep, .{ .glyphs = &.{}, .locals = &deep_locals }, false);
}

// --- calculating -----------------------------------------------------------------

const calculated = [_]Drawn{
    // Sums, differences, products and quotients.
    .{
        .program = builder.program("0 0 rmoveto 3 4 add 10 2 sub rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 0, 0 }, .{ 7, 8 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 6 7 mul 9 2 div rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 0, 0 }, .{ 42, 4.5 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 1 3 div 2 3 div rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 0, 0 }, .{ 1.0 / 3.0, 2.0 / 3.0 } },
    },
    // A number without its sign, with the other one, and a root.
    .{
        .program = builder.program("0 0 rmoveto -5 abs 5 neg rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 0, 0 }, .{ 5, -5 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 16 sqrt 2.25 sqrt rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 0, 0 }, .{ 4, 1.5 } },
    },
    // Both, either, neither, and the same: 1 or 0.
    .{
        .program = builder.program("0 0 rmoveto 1 0 and 1 0 or rlineto 0 not 5 5 eq rlineto 3 4 eq 7 not rlineto endchar"),
        .verbs = "MLLLZ",
        .points = &.{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 2 }, .{ 1, 2 } },
    },
    // The first of two numbers when a third is no more than a fourth.
    .{
        .program = builder.program("0 0 rmoveto 10 20 1 2 ifelse 10 20 2 1 ifelse rlineto 30 40 5 5 ifelse 0 rlineto endchar"),
        .verbs = "MLLZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 20 }, .{ 40, 20 } },
    },
    // The top once more, the top two the other way round, the top left out.
    .{
        .program = builder.program("0 0 rmoveto 7 dup rlineto 1 2 exch rlineto 3 4 5 drop rlineto endchar"),
        .verbs = "MLLLZ",
        .points = &.{ .{ 0, 0 }, .{ 7, 7 }, .{ 9, 8 }, .{ 12, 12 } },
    },
    // A number further down once more; the top one for a place below 0.
    .{
        .program = builder.program("0 0 rmoveto 10 20 1 index 0 index rlineto endchar"),
        .verbs = "MLLZ",
        .points = &.{ .{ 0, 0 }, .{ 10, 20 }, .{ 20, 30 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 5 6 -1 index 9 rlineto endchar"),
        .verbs = "MLLZ",
        .points = &.{ .{ 0, 0 }, .{ 5, 6 }, .{ 11, 15 } },
    },
    // The top numbers turned round: up, down, and further than they are many.
    .{
        .program = builder.program("0 0 rmoveto 1 2 3 4 4 1 roll rlineto endchar"),
        .verbs = "MLLZ",
        .points = &.{ .{ 0, 0 }, .{ 4, 1 }, .{ 6, 4 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 1 2 3 4 4 -1 roll rlineto endchar"),
        .verbs = "MLLZ",
        .points = &.{ .{ 0, 0 }, .{ 2, 3 }, .{ 6, 4 } },
    },
    .{
        .program = builder.program("0 0 rmoveto 1 2 3 3 5 roll 7 rlineto endchar"),
        .verbs = "MLLZ",
        .points = &.{ .{ 0, 0 }, .{ 2, 3 }, .{ 3, 10 } },
    },
    // A number put aside and taken back, in the first place and the last.
    .{
        .program = builder.program("0 0 rmoveto 42 3 put 17 31 put 3 get 31 get rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 0, 0 }, .{ 42, 17 } },
    },
    // A number above 0 and no more than 1, by chance: here always 1.
    .{
        .program = builder.program("0 0 rmoveto random random rlineto endchar"),
        .verbs = "MLZ",
        .points = &.{ .{ 0, 0 }, .{ 1, 1 } },
    },
};

test "cubic outlines: the operators that calculate" {
    try expectAllDrawn(&calculated, .{ .glyphs = &.{} }, false);
}

// --- many fonts under one set of glyphs ------------------------------------------

/// `glyph` of `outline` is damaged: it has no segments and an empty
/// box, and is rendered as a glyph of no ink - with its advance, of 600
/// units, all the same.
pub fn expectDamaged(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32) !void {
    errdefer std.debug.print("glyph {d} is not read as damaged\n", .{glyph});
    var verbs: [8]u8 = undefined;
    var points: [8]vector.Point = undefined;
    var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 8, .point_room = 8 };
    try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.GlyphSegments(outline, glyph, &segments));
    try testing.expectEqual(@as(u32, 0), segments.verb_count);
    try testing.expectEqual(@as(u32, 0), segments.point_count);
    var measures: truetype.GlyphMetrics = .{};
    try testing.expect(tb.GlyphMetrics(outline, glyph, &measures));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600 }, measures);
    var pixels: [64]u8 = undefined;
    var image = truetype.GlyphImage{ .pixels = &pixels, .room = pixels.len };
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, glyph, 20, &image));
    try testing.expectEqual(@as(u32, 0), image.size);
    try testing.expectEqual(fontimage.Glyph{ .advance = 12 }, image.glyph);
}

test "cubic outlines: many fonts under one set of glyphs, each glyph with the subroutines of its own" {
    // Six glyphs that call their font's first subroutine, and one that
    // calls none; three fonts whose first subroutine is a line of its
    // own, and one without subroutines.
    const calls = builder.program("0 0 rmoveto -107 callsubr endchar");
    const plain = builder.program("0 0 rmoveto 4 4 rlineto endchar");
    const fonts = [_][]const []const u8{
        &.{builder.program("10 0 rlineto return")},
        &.{builder.program("0 20 rlineto return")},
        &.{builder.program("30 30 rlineto return")},
        &.{},
    };
    const lines = [_][2]f32{ .{ 10, 0 }, .{ 0, 20 }, .{ 30, 30 } };
    const Select = struct {
        /// `FDSelect`, whole.
        bytes: []const u8,
        /// The font whose line each of the six draws; null for a glyph
        /// that finds no subroutine.
        draws: [6]?u8,
    };
    const selects = [_]Select{
        // A byte a glyph.
        .{ .bytes = &.{ 0, 0, 1, 2, 2, 1, 0, 3 }, .draws = .{ 0, 1, 2, 2, 1, 0 } },
        // Ranges: from glyph 0, from 2, from 4, and the glyph after the last.
        .{ .bytes = &.{ 3, 0, 3, 0, 0, 0, 0, 2, 2, 0, 4, 1, 0, 7 }, .draws = .{ 0, 0, 2, 2, 1, 1 } },
        // A font that is not there, and the one without subroutines.
        .{ .bytes = &.{ 0, 0, 9, 2, 3, 1, 0, 9 }, .draws = .{ 0, null, 2, null, 1, 0 } },
        // Ranges that start after the first glyph.
        .{ .bytes = &.{ 3, 0, 1, 0, 2, 1, 0, 7 }, .draws = .{ null, null, 1, 1, 1, 1 } },
        // A form this library does not read: no glyph has a font.
        .{ .bytes = &.{ 7, 0, 0, 0, 0, 0, 0, 0 }, .draws = .{ null, null, null, null, null, null } },
    };
    var rig = try Rig.up();
    const tb = rig.tb;
    var file: builder.File = .{};
    for (selects) |select| {
        build(&file, .{
            .glyphs = &.{ calls, calls, calls, calls, calls, calls, plain },
            .fonts = &fonts,
            .select = select.bytes,
        }, false);
        const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
        for (select.draws, 0..) |font, glyph| {
            if (font) |number| {
                try expectDrawn(tb, outline, @intCast(glyph), "MLZ", &.{ .{ 0, 0 }, lines[number] });
            } else try expectDamaged(tb, outline, @intCast(glyph));
        }
        // The one that calls none is drawn whatever font it has.
        try expectDrawn(tb, outline, 6, "MLZ", &.{ .{ 0, 0 }, .{ 4, 4 } });
        tb.CloseOutline(outline);
    }
    try rig.down();
}

// --- damaged programs ------------------------------------------------------------

/// The subroutines the damaged programs call, by the number that calls
/// each: one that calls itself; eleven, each calling the next; ten,
/// each calling the next four times; and 24 lines, called sixteen times
/// by one that another calls sixteen times.
const damaged_locals = locals: {
    var all: [25][]const u8 = undefined;
    // -107.
    all[0] = builder.program("-107 callsubr return");
    // -106 to -96.
    for (1..11) |number| all[number] = builder.program(std.fmt.comptimePrint("{d} callsubr return", .{@as(i32, number) + 1 - 107}));
    all[11] = builder.program("return");
    // -95 to -86.
    for (12..21) |number| all[number] = builder.program(std.fmt.comptimePrint("{d} callsubr ", .{@as(i32, number) + 1 - 107}) ** 4 ++ "return");
    all[21] = builder.program("return");
    // -85, -84 and -83.
    all[22] = builder.program("1 0 " ** 24 ++ "rlineto return");
    all[23] = builder.program("-85 callsubr " ** 16 ++ "return");
    all[24] = builder.program("-84 callsubr " ** 16 ++ "return");
    const made = all;
    break :locals made;
};

const damaged = [_][]const u8{
    // An operator with fewer numbers than it takes, and more numbers
    // than are kept.
    builder.program("add endchar"),
    builder.program("0 0 rmoveto 7 exch rlineto endchar"),
    builder.program("1 " ** 49 ++ "rlineto endchar"),
    builder.program("0 0 rmoveto " ++ "1 " ** 48 ++ "dup rlineto endchar"),
    // What is no operator, of one byte and of two.
    builder.program("0 0 rmoveto 1 1 rlineto #02 endchar"),
    builder.program("0 0 rmoveto 1 1 rlineto #0c #63 endchar"),
    builder.program("0 0 rmoveto 1 1 rlineto #0c"),
    // What has no answer.
    builder.program("0 0 rmoveto 1 0 div 1 rlineto endchar"),
    builder.program("0 0 rmoveto -4 sqrt 1 rlineto endchar"),
    // A place to put a number aside that is not there, a number further
    // down than there are numbers, and more turned round than there are.
    builder.program("0 0 rmoveto 5 32 put 1 1 rlineto endchar"),
    builder.program("0 0 rmoveto 5 -1 put 1 1 rlineto endchar"),
    builder.program("0 0 rmoveto 32 get 1 rlineto endchar"),
    builder.program("0 0 rmoveto 1 2 2 index rlineto endchar"),
    builder.program("0 0 rmoveto 1 2 3 4 1 roll rlineto endchar"),
    // A subroutine that is not there: past the last, before the first,
    // and of a list with none.
    builder.program("0 0 rmoveto 500 callsubr endchar"),
    builder.program("0 0 rmoveto -108 callsubr endchar"),
    builder.program("0 0 rmoveto -107 callgsubr endchar"),
    builder.program("0 0 rmoveto callsubr endchar"),
    // One that calls itself, eleven one in another, and more steps than
    // a glyph is given.
    builder.program("0 0 rmoveto -107 callsubr endchar"),
    builder.program("0 0 rmoveto -106 callsubr endchar"),
    builder.program("0 0 rmoveto 1 1 rlineto " ++ "-95 callsubr " ** 4 ++ "endchar"),
    // A number cut short, in each form of more than a byte, and a mask.
    builder.program("0 0 rmoveto 1 1 rlineto #1c #01"),
    builder.program("0 0 rmoveto 1 1 rlineto #f7"),
    builder.program("0 0 rmoveto 1 1 rlineto #fb"),
    builder.program("0 0 rmoveto 1 1 rlineto #ff #00 #00 #01"),
    builder.program("1 2 hstemhm 0 0 rmoveto 1 1 rlineto hintmask"),
    builder.program("1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 hstemhm 0 0 rmoveto 1 1 rlineto cntrmask #ff"),
    // A point too far out, and more points than a glyph may have.
    builder.program("0 0 rmoveto 32767 32767 mul 0 rlineto endchar"),
    builder.program("0 0 rmoveto 1 1 rlineto 0 32767 -32767 mul rmoveto 1 1 rlineto endchar"),
    builder.program("0 0 rmoveto " ++ "-83 callsubr " ** 11 ++ "endchar"),
};

test "cubic outlines: a damaged program is a glyph of nothing, and the glyphs beside it are drawn" {
    var rig = try Rig.up();
    const tb = rig.tb;
    var file: builder.File = .{};
    // After the damaged ones: a glyph of ten times 6144 lines, which is
    // not too many, and one that only draws a line.
    const many_lines = builder.program("0 0 rmoveto " ++ "-83 callsubr " ** 10 ++ "endchar");
    const one_line = builder.program("0 0 rmoveto 5 5 rlineto endchar");
    build(&file, .{ .glyphs = &(damaged ++ [_][]const u8{ many_lines, one_line }), .locals = &damaged_locals }, false);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    for (0..damaged.len) |glyph| try expectDamaged(tb, outline, @intCast(glyph));

    var verbs: [8]u8 = undefined;
    var points: [8]vector.Point = undefined;
    var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 8, .point_room = 8 };
    try testing.expectEqual(truetype.TRUETYPEERR_ROOM, tb.GlyphSegments(outline, damaged.len, &segments));
    try testing.expectEqual(@as(u32, 61442), segments.verb_count);
    try testing.expectEqual(@as(u32, 61441), segments.point_count);
    var measures: truetype.GlyphMetrics = .{};
    try testing.expect(tb.GlyphMetrics(outline, damaged.len, &measures));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .x_max = 61440 }, measures);

    try expectDrawn(tb, outline, damaged.len + 1, "MLZ", &.{ .{ 0, 0 }, .{ 5, 5 } });
    tb.CloseOutline(outline);
    try rig.down();
}

// --- the table's forms -----------------------------------------------------------

/// Whether a font around `table`, under `tag`, is opened.
fn opens(tb: *TrueTypeBase, tag: *const [4]u8, table: []const u8, glyphs: u16) bool {
    var file: builder.File = .{};
    wrap(&file, tag, table, glyphs, false);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return false;
    tb.CloseOutline(outline);
    return true;
}

test "cubic outlines: offsets of one to four bytes" {
    for (1..5) |off_size| {
        try expectAllDrawn(&few, .{ .glyphs = &.{}, .locals = &few_locals, .globals = &few_globals, .off_size = @intCast(off_size) }, false);
    }
}

test "cubic outlines: which tables are read and which are refused" {
    var rig = try Rig.up();
    const tb = rig.tb;
    const nothing = builder.program("endchar");
    const line = builder.program("0 0 rmoveto 5 5 rlineto endchar");
    var table: builder.File = .{};

    // Version 1 and no other.
    builder.cff(&table, .{ .glyphs = &.{ nothing, line } });
    try testing.expect(opens(tb, "CFF ", table.written(), 2));
    table = .{};
    builder.cff(&table, .{ .glyphs = &.{ nothing, line }, .major = 2 });
    try testing.expect(!opens(tb, "CFF ", table.written(), 2));
    table = .{};
    builder.cff(&table, .{ .glyphs = &.{ nothing, line }, .major = 0 });
    try testing.expect(!opens(tb, "CFF ", table.written(), 2));

    // Programs said to be of the kind this library runs, and of another.
    table = .{};
    builder.cff(&table, .{ .glyphs = &.{ nothing, line }, .charstring_type = 2 });
    try testing.expect(opens(tb, "CFF ", table.written(), 2));
    table = .{};
    builder.cff(&table, .{ .glyphs = &.{ nothing, line }, .charstring_type = 1 });
    try testing.expect(!opens(tb, "CFF ", table.written(), 2));

    // The same table under the later form's name is not that form's.
    table = .{};
    builder.cff(&table, .{ .glyphs = &.{ nothing, line } });
    try testing.expect(!opens(tb, "CFF2", table.written(), 2));

    // A top dictionary that does not say where the programs are: the
    // operator that does is the first byte 17 that follows a number of
    // five bytes.
    var broken = table;
    var at: u32 = 5;
    while (at < broken.len and !(broken.bytes[at] == 17 and broken.bytes[at - 5] == 29)) at += 1;
    try testing.expect(at < broken.len);
    broken.bytes[at] = 16;
    try testing.expect(!opens(tb, "CFF ", broken.written(), 2));

    // Cut short anywhere, it is refused or read, and what is read of it
    // is asked for without harm.
    var file: builder.File = .{};
    var verbs: [8]u8 = undefined;
    var points: [8]vector.Point = undefined;
    var opened: u32 = 0;
    for (0..table.len) |length| {
        wrap(&file, "CFF ", table.bytes[0..length], 2, false);
        const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse continue;
        opened += 1;
        for (0..2) |glyph| {
            var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 8, .point_room = 8 };
            _ = tb.GlyphSegments(outline, @intCast(glyph), &segments);
            var measures: truetype.GlyphMetrics = .{};
            try testing.expect(tb.GlyphMetrics(outline, @intCast(glyph), &measures));
        }
        tb.CloseOutline(outline);
    }
    // What may be missing is the end of the table: the private
    // dictionary's two bytes, which these programs do not need, and the
    // eight of the programs themselves, whose glyphs then have no outline.
    try testing.expectEqual(@as(u32, 10), opened);

    // More glyphs in the font than programs in the table: the ones past
    // the last have no outline.
    wrap(&file, "CFF ", table.written(), 4, false);
    var outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    try expectDrawn(tb, outline, 1, "MLZ", &.{ .{ 0, 0 }, .{ 5, 5 } });
    try expectDrawn(tb, outline, 2, "", &.{});
    try expectDrawn(tb, outline, 3, "", &.{});
    tb.CloseOutline(outline);

    // Beside `glyf`, the table is left alone: glyph 1 is the square of
    // four lines, not the program's one.
    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    cmap.segments(&.{.{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 }});
    file = .{};
    _ = builder.font(&file, .{ .cmap = cmap.written(), .glyphs = 2, .more = &.{.{ .tag = "CFF ", .bytes = table.written() }} });
    outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 8, .point_room = 8 };
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 1, &segments));
    try testing.expectEqual(@as(u32, 5), segments.verb_count);
    try testing.expectEqual(@as(u32, 4), segments.point_count);
    tb.CloseOutline(outline);
    try rig.down();
}

// --- room and rendering ----------------------------------------------------------

/// How much of its pixels a rendered glyph covers, in pixels: the sum
/// of each one's four bits, of which fifteen are a whole pixel.
fn coverageOf(image: *const truetype.GlyphImage) f64 {
    var sum: u64 = 0;
    const box = image.glyph;
    for (0..box.rows) |y| for (0..box.width) |x| {
        const byte = image.pixels[y * box.pitch + x / 2];
        sum += if (x & 1 == 0) byte >> 4 else byte & 0xF;
    };
    return @as(f64, @floatFromInt(sum)) / 15.0;
}

test "cubic outlines: a glyph of more points than the font is read with" {
    var rig = try Rig.up();
    const tb = rig.tb;
    // Stairs of 54 times 24 steps up to the right, each 10 units, then
    // left to above the start: 1298 points.
    const stairs = builder.program("0 0 rmoveto " ++ "-107 callsubr " ** 54 ++ "-6480 hlineto endchar");
    const steps = builder.program("10 0 0 10 " ** 12 ++ "rlineto return");
    var file: builder.File = .{};
    build(&file, .{ .glyphs = &.{ builder.program("endchar"), stairs }, .locals = &.{steps} }, false);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;

    // A font that does not name its largest glyph is read with room for
    // 1024 points in 128 contours.
    var metrics: truetype.FontMetrics = .{};
    tb.FontMetrics(outline, &metrics);
    try testing.expectEqual(@as(u32, 1025 + 2 * 129), metrics.most_verbs);
    try testing.expectEqual(@as(u32, 2 * 1025 + 129), metrics.most_points);

    // The glyph takes more verbs than that: the answer says how many,
    // and with that room it is read.
    var verbs: [1299]u8 = undefined;
    var points: [2179]vector.Point = undefined;
    var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = metrics.most_verbs, .point_room = metrics.most_points };
    try testing.expectEqual(truetype.TRUETYPEERR_ROOM, tb.GlyphSegments(outline, 1, &segments));
    try testing.expectEqual(@as(u32, 1299), segments.verb_count);
    try testing.expectEqual(@as(u32, 1298), segments.point_count);
    segments.verb_room = segments.verb_count;
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 1, &segments));
    try testing.expectEqual(@as(u32, 1299), segments.verb_count);
    try testing.expectEqual(@as(u32, 1298), segments.point_count);
    try testing.expectEqual(vector.SEG_MOVE, verbs[0]);
    for (verbs[1..1298]) |verb| try testing.expectEqual(vector.SEG_LINE, verb);
    try testing.expectEqual(vector.SEG_CLOSE, verbs[1298]);
    try testing.expectEqual(vector.Point{ .x = 0, .y = 0 }, points[0]);
    try testing.expectEqual(vector.Point{ .x = 10, .y = 0 }, points[1]);
    try testing.expectEqual(vector.Point{ .x = 10, .y = 10 }, points[2]);
    try testing.expectEqual(vector.Point{ .x = 6480, .y = 6480 }, points[1296]);
    try testing.expectEqual(vector.Point{ .x = 0, .y = 6480 }, points[1297]);
    var measures: truetype.GlyphMetrics = .{};
    try testing.expect(tb.GlyphMetrics(outline, 1, &measures));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .x_max = 6480, .y_max = 6480 }, measures);

    // And it is rendered: at 20 rows a unit is a fiftieth of a pixel, and
    // the ink is the triangle's above the stairs.
    const pixels = try testing.allocator.alloc(u8, 16 * 1024);
    defer testing.allocator.free(pixels);
    var image = truetype.GlyphImage{ .pixels = pixels.ptr, .room = @intCast(pixels.len) };
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, 1, 20, &image));
    try testing.expectEqual(@as(u16, 130), image.glyph.width);
    try testing.expectEqual(@as(u16, 130), image.glyph.rows);
    const area = (6480.0 * 6480.0 / 2.0 - 54.0 * 12.0 * 50.0) / 2500.0;
    try testing.expectApproxEqRel(@as(f64, area), coverageOf(&image), 0.01);

    tb.CloseOutline(outline);
    try rig.down();
}

test "cubic outlines: rendered, a square as the same square of a font of quadratic curves, a circle by its area" {
    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;
    const nothing = builder.program("endchar");
    // The square every glyph of a built font with `glyf` is, 500 units
    // wide and 700 tall, and a circle of four arcs, 400 units in radius
    // around 400, 300: 220.914 units is how far an arc's control points
    // are from its ends.
    const square = builder.program("0 0 rmoveto 500 hlineto 700 vlineto -500 hlineto endchar");
    const circle = builder.program("800 300 rmoveto " ++
        "0 220.914 -179.086 179.086 -220.914 0 " ++
        "-220.914 0 -179.086 -179.086 0 -220.914 " ++
        "0 -220.914 179.086 -179.086 220.914 0 " ++
        "220.914 0 179.086 179.086 0 220.914 rrcurveto endchar");

    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    cmap.segments(&.{
        .{ .first = 'A', .last = 'A', .delta = 1 -% @as(u16, 'A') },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });
    var quadratic: builder.File = .{};
    _ = builder.font(&quadratic, .{ .cmap = cmap.written(), .glyphs = 3 });
    const model = tb.OpenOutline(&quadratic.bytes, quadratic.len, null) orelse return error.NoOutline;
    const letter = [_]truetype.CodeRange{.{ .first = 'A', .last = 'A' }};
    const model_image = tb.RenderFontImage(model, 20, &letter, letter.len) orelse return error.NoImage;
    const model_block: [*]const u8 = @ptrCast(model_image);

    var file: builder.File = .{};
    var theirs: [16 * 1024]u8 = undefined;
    var ours: [16 * 1024]u8 = undefined;
    // With a font that names a largest glyph smaller than the circle,
    // and with one that names none.
    for ([_]bool{ true, false }) |largest| {
        build(&file, .{ .glyphs = &.{ nothing, square, circle } }, largest);
        const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;

        for ([_]u32{ 1, 7, 16, 17, 20, 64, 211 }) |rows| {
            var want = truetype.GlyphImage{ .pixels = &theirs, .room = theirs.len };
            var got = truetype.GlyphImage{ .pixels = &ours, .room = ours.len };
            try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(model, 1, rows, &want));
            try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, 1, rows, &got));
            try testing.expectEqual(want.glyph, got.glyph);
            try testing.expectEqual(want.size, got.size);
            try testing.expectEqualSlices(u8, theirs[0..want.size], ours[0..got.size]);
        }

        // A font image of it is the other font's, byte for byte.
        const image = tb.RenderFontImage(outline, 20, &letter, letter.len) orelse return error.NoImage;
        const block: [*]const u8 = @ptrCast(image);
        try testing.expect(fontimage.sound(block, image.size));
        try testing.expectEqualSlices(u8, model_block[0..model_image.size], block[0..image.size]);
        sys.FreeVec(image);

        // The circle at 100 rows, a tenth of a pixel a unit: 80 pixels
        // across, and as much ink as a circle of 40 pixels in radius has.
        var round = truetype.GlyphImage{ .pixels = &ours, .room = ours.len };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, 2, 100, &round));
        try testing.expectEqual(@as(u16, 80), round.glyph.width);
        try testing.expectEqual(@as(u16, 80), round.glyph.rows);
        try testing.expectEqual(@as(i16, 0), round.glyph.left);
        try testing.expectEqual(@as(i16, 10), round.glyph.top);
        try testing.expectApproxEqRel(@as(f64, std.math.pi * 40.0 * 40.0), coverageOf(&round), 0.005);
        // Its middle is covered, its box's corners are not.
        const pitch: u32 = round.glyph.pitch;
        try testing.expectEqual(@as(u8, 0xFF), ours[40 * pitch + 20]);
        try testing.expectEqual(@as(u8, 0), ours[0] >> 4);
        try testing.expectEqual(@as(u8, 0), ours[79 * pitch + 39] & 0xF);

        tb.CloseOutline(outline);
    }
    sys.FreeVec(model_image);
    tb.CloseOutline(model);
    try rig.down();
}

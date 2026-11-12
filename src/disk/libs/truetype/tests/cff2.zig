// SPDX-License-Identifier: MIT
//! Host tests of a variable font's cubic outlines, on `CFF2` tables the
//! tests build: what a glyph's program draws at a place on the font's
//! axis, a number with its deltas; which of the store's data the deltas
//! are for; the table's lists, font dictionaries and store; programs
//! and tables that are damaged; and a glyph's measures.
//!
//! The font has one axis, weight, from 100 over 400 to 900, and a store
//! of three regions: the first counts whole at the heaviest and falls
//! to nothing at the default, the second the same toward the lightest,
//! and the third counts whole half way to the heaviest and nothing at
//! both its ends. What stands beside a program follows from what a
//! blend is defined to do: each number and, for every region, its delta
//! as far as the region counts. Every number here is one a float holds
//! exactly. What a real font's programs draw is `fonts.zig`'s.

const std = @import("std");
const sdk = @import("sdk");
const truetype = sdk.truetype;
const vector = sdk.vector;
const builder = @import("builder.zig");
const cubic = @import("cff.zig");
const varied = @import("variation.zig");
const Rig = @import("truetype.zig").Rig;

const testing = std.testing;
const File = builder.File;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;

// --- the font --------------------------------------------------------------

const axes = [_]varied.Axis{.{ .tag = "wght", .least = 100, .middle = 400, .most = 900, .name = 256 }};

const regions = [_][]const [3]i16{
    &.{.{ 0, 16384, 16384 }},
    &.{.{ -16384, -16384, 0 }},
    &.{.{ 0, 8192, 16384 }},
};

/// The store's data: the first for the two regions toward the ends,
/// the second for the one half way, the third for all three.
const sets = [_]varied.Rows{
    .{ .regions = &.{ 0, 1 }, .wide = 0, .rows = &.{} },
    .{ .regions = &.{2}, .wide = 0, .rows = &.{} },
    .{ .regions = &.{ 0, 1, 2 }, .wide = 0, .rows = &.{} },
};

/// What a built font is made of around its table's parts.
const Made = struct {
    parts: builder.Cff2Parts,
    /// Whether it has an axis at all.
    axis: bool = true,
    /// Whether the table has a store, and for how many axes.
    store: bool = true,
    store_axes: u16 = 1,
    /// The tag the table is under.
    tag: *const [4]u8 = "CFF2",
    /// Whether `HVAR` moves the advances: glyph g's by ten units g
    /// times, at the heaviest.
    advances: bool = false,
};

/// A font that starts 'OTTO', without `glyf`, around the `CFF2` table
/// `made` describes; 'A' is glyph 1.
fn fontOf(file: *File, made: Made) void {
    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    cmap.segments(&.{
        .{ .first = 'A', .last = 'A', .delta = 1 -% @as(u16, 'A') },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });

    var items: File = .{};
    var parts = made.parts;
    if (made.store) {
        varied.store(&items, made.store_axes, if (made.store_axes == 1) &regions else &.{
            &.{ .{ 0, 16384, 16384 }, .{ 0, 0, 0 } },
            &.{ .{ -16384, -16384, 0 }, .{ 0, 0, 0 } },
            &.{ .{ 0, 8192, 16384 }, .{ 0, 0, 0 } },
        }, &sets);
        parts.store = items.written();
    }
    var table: File = .{};
    builder.cff2(&table, parts);

    var more: [3]builder.Table = undefined;
    var count: usize = 0;
    more[count] = .{ .tag = made.tag, .bytes = table.written() };
    count += 1;

    var axis: File = .{};
    if (made.axis) {
        varied.fvar(&axis, &axes, &.{});
        more[count] = .{ .tag = "fvar", .bytes = axis.written() };
        count += 1;
    }

    var moved: File = .{};
    var advances: File = .{};
    if (made.advances) {
        var rows: [16][1]i32 = undefined;
        var list: [16][]const i32 = undefined;
        for (0..parts.glyphs.len) |glyph| {
            rows[glyph] = .{@intCast(glyph * 10)};
            list[glyph] = &rows[glyph];
        }
        varied.store(&moved, 1, &regions, &.{.{ .regions = &.{0}, .wide = 1, .rows = list[0..parts.glyphs.len] }});
        varied.hvar(&advances, moved.written(), null);
        more[count] = .{ .tag = "HVAR", .bytes = advances.written() };
        count += 1;
    }

    file.* = .{};
    _ = builder.font(file, .{
        .cmap = cmap.written(),
        .glyphs = @intCast(parts.glyphs.len),
        .outlines = false,
        .tag = 0x4F54_544F,
        .largest = false,
        .more = more[0..count],
    });
}

/// The font of `file` opened at `weight`.
fn openAt(tb: *TrueTypeBase, file: *const File, weight: f32) !*truetype.Outline {
    const place = [_]truetype.AxisValue{.{ .tag = truetype.tableTag("wght"), .value = weight }};
    return varied.openAt(tb, file, &place);
}

// --- what a program draws ----------------------------------------------------

/// The weights a font is opened at, and how far each of the store's
/// three regions counts there: the default, the heaviest, three
/// quarters of the way to it, and half way to the lightest.
const weights = [_]f32{ 400, 900, 775, 250 };

/// A program and what it draws at each of `weights`; a place with no
/// points draws what the default does.
const Blended = struct {
    program: []const u8,
    verbs: []const u8,
    points: [weights.len][]const [2]f32,
};

/// Every `cases`' glyph of the font of `file` is drawn as it says at
/// each of `weights`, the first case glyph `first`.
fn expectBlended(tb: *TrueTypeBase, file: *const File, first: u32, cases: []const Blended) !void {
    for (weights, 0..) |weight, place| {
        errdefer std.debug.print("at weight {d}\n", .{weight});
        const outline = try openAt(tb, file, weight);
        for (cases, 0..) |case, index| {
            const points = if (case.points[place].len != 0) case.points[place] else case.points[0];
            try cubic.expectDrawn(tb, outline, first + @as(u32, @intCast(index)), case.verbs, points);
        }
        tb.CloseOutline(outline);
    }
}

/// The programs of `cases` after a glyph of no outline.
fn programsOf(comptime cases: []const Blended) []const []const u8 {
    return comptime programs: {
        var list: [cases.len + 1][]const u8 = undefined;
        list[0] = "";
        for (cases, 0..) |case, i| list[i + 1] = case.program;
        const all = list;
        break :programs &all;
    };
}

const blended = [_]Blended{
    // One number with its two deltas, and two numbers with theirs after
    // both.
    .{
        .program = builder.program("10 20 rmoveto 100 40 -20 1 blend 0 rlineto 0 50 6 -4 10 8 2 blend rlineto"),
        .verbs = "MLLZ",
        .points = .{
            &.{ .{ 10, 20 }, .{ 110, 20 }, .{ 110, 70 } },
            &.{ .{ 10, 20 }, .{ 150, 20 }, .{ 156, 80 } },
            &.{ .{ 10, 20 }, .{ 140, 20 }, .{ 144.5, 77.5 } },
            &.{ .{ 10, 20 }, .{ 100, 20 }, .{ 98, 74 } },
        },
    },
    // The program names the data its deltas are for: the one region
    // half way.
    .{
        .program = builder.program("1 vsindex 0 0 rmoveto 100 30 1 blend 0 rlineto 0 100 rlineto"),
        .verbs = "MLLZ",
        .points = .{
            &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 100 } },
            &.{},
            &.{ .{ 0, 0 }, .{ 115, 0 }, .{ 115, 100 } },
            &.{},
        },
    },
    // Hints take blended numbers and are passed over; the mask is a
    // byte for the two stems.
    .{
        .program = builder.program("10 20 4 0 1 blend hstemhm 5 10 vstemhm hintmask #C0 0 0 rmoveto 50 8 0 1 blend 0 rlineto 0 50 rlineto"),
        .verbs = "MLLZ",
        .points = .{
            &.{ .{ 0, 0 }, .{ 50, 0 }, .{ 50, 50 } },
            &.{ .{ 0, 0 }, .{ 58, 0 }, .{ 58, 50 } },
            &.{ .{ 0, 0 }, .{ 56, 0 }, .{ 56, 50 } },
            &.{},
        },
    },
    // Blends in a local and in a global subroutine.
    .{
        .program = builder.program("0 0 rmoveto -107 callsubr -107 callgsubr"),
        .verbs = "MLLZ",
        .points = .{
            &.{ .{ 0, 0 }, .{ 50, 0 }, .{ 50, 40 } },
            &.{ .{ 0, 0 }, .{ 60, 0 }, .{ 60, 40 } },
            &.{ .{ 0, 0 }, .{ 57.5, 0 }, .{ 57.5, 40 } },
            &.{ .{ 0, 0 }, .{ 50, 0 }, .{ 50, 44 } },
        },
    },
    // The data a program names counts in the subroutines it calls: all
    // three regions.
    .{
        .program = builder.program("2 vsindex 0 0 rmoveto -106 callsubr"),
        .verbs = "MLLZ",
        .points = .{
            &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 } },
            &.{ .{ 0, 0 }, .{ 11, 0 }, .{ 11, 10 } },
            &.{ .{ 0, 0 }, .{ 12.25, 0 }, .{ 12.25, 10 } },
            &.{ .{ 0, 0 }, .{ 11, 0 }, .{ 11, 10 } },
        },
    },
    // A glyph of the second font dictionary: its private dictionary
    // names the data, and the subroutine is its own.
    .{
        .program = builder.program("0 0 rmoveto 100 30 1 blend 0 rlineto -107 callsubr"),
        .verbs = "MLLZ",
        .points = .{
            &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 20 } },
            &.{},
            &.{ .{ 0, 0 }, .{ 115, 0 }, .{ 115, 20 } },
            &.{},
        },
    },
    // Six numbers of a curve in one blend.
    .{
        .program = builder.program("0 0 rmoveto 10 20 30 40 50 60 1 0 2 0 3 0 4 0 5 0 6 0 6 blend rrcurveto"),
        .verbs = "MCZ",
        .points = .{
            &.{ .{ 0, 0 }, .{ 10, 20 }, .{ 40, 60 }, .{ 90, 120 } },
            &.{ .{ 0, 0 }, .{ 11, 22 }, .{ 44, 66 }, .{ 99, 132 } },
            &.{ .{ 0, 0 }, .{ 10.75, 21.5 }, .{ 43, 64.5 }, .{ 96.75, 129 } },
            &.{},
        },
    },
    // Two curves in one, the first number blended.
    .{
        .program = builder.program("0 0 rmoveto 10 4 0 1 blend 20 30 40 50 60 70 hflex"),
        .verbs = "MCCZ",
        .points = .{
            &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 30, 30 }, .{ 70, 30 }, .{ 120, 30 }, .{ 180, 0 }, .{ 250, 0 } },
            &.{ .{ 0, 0 }, .{ 14, 0 }, .{ 34, 30 }, .{ 74, 30 }, .{ 124, 30 }, .{ 184, 0 }, .{ 254, 0 } },
            &.{ .{ 0, 0 }, .{ 13, 0 }, .{ 33, 30 }, .{ 73, 30 }, .{ 123, 30 }, .{ 183, 0 }, .{ 253, 0 } },
            &.{},
        },
    },
    // A program may say where it ends, and a subroutine that it
    // returns.
    .{
        .program = builder.program("0 0 rmoveto -105 callsubr 0 10 rlineto endchar"),
        .verbs = "MLLZ",
        .points = .{
            &.{ .{ 0, 0 }, .{ 30, 0 }, .{ 30, 10 } },
            &.{ .{ 0, 0 }, .{ 33, 0 }, .{ 33, 10 } },
            &.{ .{ 0, 0 }, .{ 32.25, 0 }, .{ 32.25, 10 } },
            &.{},
        },
    },
};

const locals = [_][]const u8{
    builder.program("50 10 0 1 blend 0 rlineto"),
    builder.program("10 1 2 3 1 blend 0 rlineto 0 10 rlineto"),
    builder.program("30 3 0 1 blend 0 rlineto return"),
};
const second_locals = [_][]const u8{builder.program("0 20 rlineto")};
const globals = [_][]const u8{builder.program("0 40 0 8 1 blend rlineto")};

/// Glyph 6 - the sixth case - is the second font dictionary's, every
/// other the first's.
const select = [_]u8{ 3, 0, 3, 0, 0, 0, 0, 6, 1, 0, 7, 0, 0, 10 };

/// The table of `blended`, with offsets of `off_size` bytes.
fn blendedParts(off_size: u8) builder.Cff2Parts {
    return .{
        .glyphs = programsOf(&blended),
        .globals = &globals,
        .fonts = &.{ .{ .locals = &locals }, .{ .locals = &second_locals, .data = 1 } },
        .select = &select,
        .off_size = off_size,
    };
}

/// The font the tests of other things - that damaged bytes are read
/// without a fault - read: every glyph of `blended`, and advances that
/// move.
pub fn standardFont(file: *File) void {
    fontOf(file, .{ .parts = blendedParts(2), .advances = true });
}

test "blended outlines: a number takes its deltas as far as each region counts at the font's place" {
    var rig = try Rig.up();
    const tb = rig.tb;
    var file: File = .{};
    fontOf(&file, .{ .parts = blendedParts(2) });
    try expectBlended(tb, &file, 1, &blended);

    // Opened without a place, the font is at its default.
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    for (blended, 1..) |case, glyph| try cubic.expectDrawn(tb, outline, @intCast(glyph), case.verbs, case.points[0]);
    // The glyph of no outline.
    try cubic.expectDrawn(tb, outline, 0, "", &.{});
    tb.CloseOutline(outline);
    try rig.down();
}

test "blended outlines: offsets of one to four bytes, and a header longer than its five" {
    var rig = try Rig.up();
    const tb = rig.tb;
    var file: File = .{};
    for (1..5) |off_size| {
        fontOf(&file, .{ .parts = blendedParts(@intCast(off_size)) });
        try expectBlended(tb, &file, 1, &blended);
    }
    var parts = blendedParts(2);
    parts.header = 8;
    fontOf(&file, .{ .parts = parts });
    try expectBlended(tb, &file, 1, &blended);
    try rig.down();
}

// --- the table's forms -------------------------------------------------------

/// Six glyphs that call their font dictionary's first subroutine, and
/// three dictionaries whose first draws a corner of ten, twenty and
/// thirty units.
const calls = builder.program("0 0 rmoveto -107 callsubr");
const corners = [_]builder.Cff2Font{
    .{ .locals = &.{builder.program("10 0 rlineto 0 10 rlineto")} },
    .{ .locals = &.{builder.program("20 0 rlineto 0 20 rlineto")} },
    .{ .locals = &.{builder.program("30 0 rlineto 0 30 rlineto")} },
};

/// Each glyph of a font whose table has `chosen` for its `FDSelect`
/// draws the corner of the font dictionary `fonts` names for it; one
/// named 9 is damaged.
fn expectSelected(tb: *TrueTypeBase, chosen: []const u8, fonts: [6]u8) !void {
    var file: File = .{};
    fontOf(&file, .{ .parts = .{ .glyphs = &.{ calls, calls, calls, calls, calls, calls }, .fonts = &corners, .select = chosen } });
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    for (fonts, 0..) |dictionary, glyph| {
        if (dictionary == 9) {
            try cubic.expectDamaged(tb, outline, @intCast(glyph));
            continue;
        }
        const side: f32 = @floatFromInt((@as(u32, dictionary) + 1) * 10);
        try cubic.expectDrawn(tb, outline, @intCast(glyph), "MLLZ", &.{ .{ 0, 0 }, .{ side, 0 }, .{ side, side } });
    }
    tb.CloseOutline(outline);
}

test "blended outlines: which font dictionary a glyph has, in each form and with none said" {
    var rig = try Rig.up();
    const tb = rig.tb;
    // Without the table every glyph is the first dictionary's.
    try expectSelected(tb, &.{}, .{ 0, 0, 0, 0, 0, 0 });
    // A byte a glyph.
    try expectSelected(tb, &.{ 0, 0, 0, 1, 1, 2, 0 }, .{ 0, 0, 1, 1, 2, 0 });
    // Ranges, where each starts in a word and its dictionary in a byte.
    try expectSelected(tb, &.{ 3, 0, 4, 0, 0, 0, 0, 2, 1, 0, 4, 2, 0, 5, 0, 0, 6 }, .{ 0, 0, 1, 1, 2, 0 });
    // Ranges, each start a long word and the dictionary a word.
    try expectSelected(tb, &.{
        4, 0, 0, 0, 4,
        0, 0, 0, 0, 0,
        0, 0, 0, 0, 2,
        0, 1, 0, 0, 0,
        4, 0, 2, 0, 0,
        0, 5, 0, 0, 0,
        0, 0, 6,
    }, .{ 0, 0, 1, 1, 2, 0 });
    // A dictionary the table does not have, and a form that is none.
    try expectSelected(tb, &.{ 0, 0, 7, 1, 1, 2, 0 }, .{ 0, 9, 1, 1, 2, 0 });
    try expectSelected(tb, &.{ 1, 0, 0, 0, 0, 0, 0 }, .{ 9, 9, 9, 9, 9, 9 });
    try rig.down();
}

/// Whether the font of `file` is opened.
fn opens(tb: *TrueTypeBase, file: *const File) bool {
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return false;
    tb.CloseOutline(outline);
    return true;
}

test "blended outlines: which tables are read and which are refused" {
    var rig = try Rig.up();
    const tb = rig.tb;
    var file: File = .{};
    const sound = blendedParts(2);

    fontOf(&file, .{ .parts = sound });
    try testing.expect(opens(tb, &file));

    // Version 2 and no other; under the earlier form's name the table is
    // not that form's.
    var parts = sound;
    parts.major = 1;
    fontOf(&file, .{ .parts = parts });
    try testing.expect(!opens(tb, &file));
    parts.major = 3;
    fontOf(&file, .{ .parts = parts });
    try testing.expect(!opens(tb, &file));
    fontOf(&file, .{ .parts = sound, .tag = "CFF " });
    try testing.expect(!opens(tb, &file));

    // A header shorter than its five bytes.
    parts = sound;
    parts.header = 4;
    fontOf(&file, .{ .parts = parts });
    try testing.expect(!opens(tb, &file));

    // A top dictionary longer than the table.
    fontOf(&file, .{ .parts = sound });
    file.setWord(varied.tableAt(&file, "CFF2") + 3, 0xFFFF);
    try testing.expect(!opens(tb, &file));

    // No font dictionary.
    parts = sound;
    parts.fonts = &.{};
    parts.select = &.{};
    fontOf(&file, .{ .parts = parts });
    try testing.expect(!opens(tb, &file));

    // A store said to be longer than what is left of the table.
    parts = sound;
    parts.store_length = 0xFFFF;
    fontOf(&file, .{ .parts = parts });
    try testing.expect(!opens(tb, &file));

    // One said to be shorter than a store is: the font is opened, a
    // glyph that blends is damaged, and one that does not is drawn.
    const plain = builder.program("0 0 rmoveto 10 0 rlineto 0 10 rlineto");
    parts = .{ .glyphs = &.{ "", blended[0].program, plain }, .store_length = 4 };
    fontOf(&file, .{ .parts = parts });
    var outline = try openAt(tb, &file, 900);
    try cubic.expectDamaged(tb, outline, 1);
    try cubic.expectDrawn(tb, outline, 2, "MLLZ", &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 } });
    tb.CloseOutline(outline);

    // Without a store a blend has no deltas to take.
    const bare = builder.program("0 0 rmoveto 100 1 blend 0 rlineto 0 10 rlineto");
    fontOf(&file, .{ .parts = .{ .glyphs = &.{ "", bare } }, .store = false });
    outline = try openAt(tb, &file, 900);
    try cubic.expectDrawn(tb, outline, 1, "MLLZ", &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 10 } });
    tb.CloseOutline(outline);

    // A font without an axis, and one whose store counts another number
    // of axes than the font has: the deltas are passed over, and every
    // glyph is drawn as at the default.
    for ([_]Made{ .{ .parts = sound, .axis = false }, .{ .parts = sound, .store_axes = 2 } }) |made| {
        fontOf(&file, made);
        outline = try openAt(tb, &file, 900);
        for (blended, 1..) |case, glyph| try cubic.expectDrawn(tb, outline, @intCast(glyph), case.verbs, case.points[0]);
        tb.CloseOutline(outline);
    }
    try rig.down();
}

// --- damaged programs --------------------------------------------------------

const damaged = [_][]const u8{
    // A blend with fewer deltas than its numbers take, with no numbers
    // at all, and with a count below 0.
    builder.program("0 0 rmoveto 100 40 1 blend 0 rlineto 0 10 rlineto"),
    builder.program("0 0 rmoveto 100 40 -20 2 blend rlineto 0 10 rlineto"),
    builder.program("0 0 rmoveto blend 0 rlineto 0 10 rlineto"),
    builder.program("0 0 rmoveto 100 40 -20 -1 blend 0 rlineto 0 10 rlineto"),
    // Data the store does not have, once a blend asks for it.
    builder.program("3 vsindex 0 0 rmoveto 100 1 blend 0 rlineto 0 10 rlineto"),
    // Data named by nothing, and by a number below 0.
    builder.program("vsindex 0 0 rmoveto 100 0 rlineto 0 10 rlineto"),
    builder.program("-1 vsindex 0 0 rmoveto 100 0 rlineto 0 10 rlineto"),
    // The operators that calculate are not this form's.
    builder.program("0 0 rmoveto 5 5 add 0 rlineto 0 10 rlineto"),
    builder.program("0 0 rmoveto 10 dup rlineto 0 10 rlineto"),
    builder.program("0 0 rmoveto 10 0 2 1 roll rlineto 0 10 rlineto"),
    // One number more than a program may hold.
    builder.program("0 0 rmoveto" ++ " 1 2" ** 257 ++ " rlineto"),
};

/// As many numbers as a program may hold, 513, the last of them left
/// over: 256 lines.
const deepest = builder.program("0 0 rmoveto" ++ " 1 2" ** 256 ++ " 1 rlineto");

test "blended outlines: a damaged program draws nothing, and the glyphs beside it are drawn" {
    var rig = try Rig.up();
    const tb = rig.tb;
    // Data the store lacks does no harm in a glyph that never blends.
    const unasked = builder.program("3 vsindex 0 0 rmoveto 100 0 rlineto 0 10 rlineto");
    var file: File = .{};
    fontOf(&file, .{ .parts = .{ .glyphs = &([_][]const u8{ "", unasked } ++ damaged ++ [_][]const u8{deepest}) } });
    for ([_]f32{ 400, 900 }) |weight| {
        const outline = try openAt(tb, &file, weight);
        try cubic.expectDrawn(tb, outline, 1, "MLLZ", &.{ .{ 0, 0 }, .{ 100, 0 }, .{ 100, 10 } });
        for (0..damaged.len) |index| try cubic.expectDamaged(tb, outline, @intCast(2 + index));

        var verbs: [300]u8 = undefined;
        var points: [300]vector.Point = undefined;
        var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 300, .point_room = 300 };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 2 + damaged.len, &segments));
        try testing.expectEqual(@as(u32, 258), segments.verb_count);
        try testing.expectEqual(@as(u32, 257), segments.point_count);
        try testing.expectEqual(vector.Point{ .x = 256, .y = 512 }, points[256]);
        tb.CloseOutline(outline);
    }

    // The two operators are no part of the earlier form, whose programs
    // hold 48 numbers.
    cubic.build(&file, .{ .glyphs = &.{
        builder.program("endchar"),
        builder.program("0 0 rmoveto 100 1 blend 0 rlineto 0 10 rlineto endchar"),
        builder.program("0 vsindex 0 0 rmoveto 100 0 rlineto 0 10 rlineto endchar"),
        builder.program("0 0 rmoveto" ++ " 1 2" ** 24 ++ " 1 rlineto endchar"),
    } }, false);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    try cubic.expectDamaged(tb, outline, 1);
    try cubic.expectDamaged(tb, outline, 2);
    try cubic.expectDamaged(tb, outline, 3);
    tb.CloseOutline(outline);
    try rig.down();
}

// --- a glyph's measures ------------------------------------------------------

/// The glyph's measures.
fn metricsOf(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32) !truetype.GlyphMetrics {
    var metrics: truetype.GlyphMetrics = .{};
    try testing.expect(tb.GlyphMetrics(outline, glyph, &metrics));
    return metrics;
}

test "blended outlines: away from the default a glyph's bearing is its box's left, and its advance HVAR's" {
    var rig = try Rig.up();
    const tb = rig.tb;
    // A corner whose start moves left by thirty units at the heaviest.
    const moving = builder.program("50 -30 0 1 blend 20 rmoveto 100 0 rlineto 0 50 rlineto");
    var file: File = .{};
    for ([_]bool{ true, false }) |advances| {
        fontOf(&file, .{ .parts = .{ .glyphs = &.{ "", moving } }, .advances = advances });
        const step: i32 = if (advances) 1 else 0;

        // At the default the bearing is the one the font states, 0.
        var outline = try openAt(tb, &file, 400);
        try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .x_min = 50, .y_min = 20, .x_max = 150, .y_max = 70 }, try metricsOf(tb, outline, 1));
        try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, 1));
        tb.CloseOutline(outline);

        outline = try openAt(tb, &file, 900);
        try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600 + 10 * step, .left_bearing = 20, .x_min = 20, .y_min = 20, .x_max = 120, .y_max = 70 }, try metricsOf(tb, outline, 1));
        try testing.expectEqual(600 + 10 * step, tb.GlyphAdvance(outline, 1));
        // A glyph of no outline has no box, and a bearing of 0.
        try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600 }, try metricsOf(tb, outline, 0));
        tb.CloseOutline(outline);

        // Three quarters of the way: the start at 27.5, the box outward
        // to whole units, and the advance's 7.5 to 8.
        outline = try openAt(tb, &file, 775);
        try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600 + 8 * step, .left_bearing = 27, .x_min = 27, .y_min = 20, .x_max = 128, .y_max = 70 }, try metricsOf(tb, outline, 1));
        tb.CloseOutline(outline);

        // Toward the lightest nothing of this glyph moves; the bearing
        // is still the box's.
        outline = try openAt(tb, &file, 250);
        try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .left_bearing = 50, .x_min = 50, .y_min = 20, .x_max = 150, .y_max = 70 }, try metricsOf(tb, outline, 1));
        tb.CloseOutline(outline);
    }
    try rig.down();
}

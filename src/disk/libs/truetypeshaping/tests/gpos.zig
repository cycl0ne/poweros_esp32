// SPDX-License-Identifier: MIT
//! Host tests of the positionings: each kind of `GPOS` lookup on a table
//! built here. Every glyph's advance is 1000 before the lookups run.

const layout = @import("layout.zig");
const subtables = @import("subtables.zig");
const harness = @import("harness.zig");

const File = layout.File;
const shape = harness.shape;
const X_PLACEMENT = subtables.X_PLACEMENT;
const Y_PLACEMENT = subtables.Y_PLACEMENT;
const X_ADVANCE = subtables.X_ADVANCE;
const Y_ADVANCE = subtables.Y_ADVANCE;

/// A `GPOS` of one feature with one lookup of one subtable.
fn gposOf(file: *File, kind: u16, flags: u16, subtable: []const u8) []const u8 {
    layout.tableOfOne(file, &.{.{ .kind = kind, .flags = flags, .subtables = &.{subtable} }});
    return file.written();
}

/// 5 and 6 are base glyphs, 40 is a ligature, 50 and 51 are marks.
const kinds = [_]layout.InClass{
    .{ .glyph = 5, .class = 1 },
    .{ .glyph = 6, .class = 1 },
    .{ .glyph = 40, .class = 2 },
    .{ .glyph = 50, .class = 3 },
    .{ .glyph = 51, .class = 3 },
};

test "single positioning, format 1: one record for every glyph of the coverage" {
    var subtable: File = .{};
    subtables.positionAll(&subtable, &.{ 5, 6 }, X_PLACEMENT | Y_PLACEMENT | X_ADVANCE, &.{ 10, 20, -30 });
    var file: File = .{};
    const run = shape(.{ .gpos = gposOf(&file, 1, 0, subtable.written()) }, &.{ 5, 7, 6 }, .{});
    try run.expectGlyphs(&.{ 5, 7, 6 });
    try run.expectAdvances(&.{ 970, 1000, 970 });
    try run.expectOffsets(&.{ .{ 10, 20 }, .{ 0, 0 }, .{ 10, 20 } });
}

test "single positioning, format 2: each glyph its own record, of the parts the format names" {
    var subtable: File = .{};
    subtables.positionEach(&subtable, &.{ 5, 6 }, Y_PLACEMENT | X_ADVANCE, &.{ &.{ 20, -30 }, &.{ -5, 40 } });
    var file: File = .{};
    const run = shape(.{ .gpos = gposOf(&file, 1, 0, subtable.written()) }, &.{ 6, 5 }, .{});
    try run.expectAdvances(&.{ 1040, 970 });
    try run.expectOffsets(&.{ .{ 0, -5 }, .{ 0, 20 } });
}

test "single positioning: an advance down the page is not read" {
    var subtable: File = .{};
    subtables.positionAll(&subtable, &.{5}, Y_ADVANCE, &.{-30});
    var file: File = .{};
    const run = shape(.{ .gpos = gposOf(&file, 1, 0, subtable.written()) }, &.{5}, .{});
    try run.expectAdvances(&.{1000});
    try run.expectOffsets(&.{.{ 0, 0 }});
}

test "pair positioning, format 1: a second glyph not moved is the first of the next pair" {
    var subtable: File = .{};
    subtables.pairs(&subtable, &.{ 5, 6 }, X_ADVANCE, 0, &.{
        &.{ .{ .second = 6, .values = &.{-50} }, .{ .second = 8, .values = &.{-70} } },
        &.{.{ .second = 7, .values = &.{-20} }},
    });
    var file: File = .{};
    const gpos = gposOf(&file, 2, 0, subtable.written());
    try shape(.{ .gpos = gpos }, &.{ 5, 6, 7 }, .{}).expectAdvances(&.{ 950, 980, 1000 });
    try shape(.{ .gpos = gpos }, &.{ 5, 8, 5 }, .{}).expectAdvances(&.{ 930, 1000, 1000 });
    try shape(.{ .gpos = gpos }, &.{ 5, 7 }, .{}).expectAdvances(&.{ 1000, 1000 });
    try shape(.{ .gpos = gpos }, &.{5}, .{}).expectAdvances(&.{1000});
}

test "pair positioning, format 1: a second glyph that was moved is done with" {
    var subtable: File = .{};
    subtables.pairs(&subtable, &.{ 5, 6 }, X_ADVANCE, X_PLACEMENT, &.{
        &.{.{ .second = 6, .values = &.{ -50, 5 } }},
        &.{.{ .second = 7, .values = &.{ -20, 3 } }},
    });
    var file: File = .{};
    const run = shape(.{ .gpos = gposOf(&file, 2, 0, subtable.written()) }, &.{ 5, 6, 7 }, .{});
    try run.expectAdvances(&.{ 950, 1000, 1000 });
    try run.expectOffsets(&.{ .{ 0, 0 }, .{ 5, 0 }, .{ 0, 0 } });
}

test "pair positioning, format 2: by the classes of the two glyphs" {
    var subtable: File = .{};
    subtables.pairClasses(
        &subtable,
        &.{5},
        X_ADVANCE,
        0,
        &.{.{ .glyph = 5, .class = 1 }},
        &.{ .{ .glyph = 6, .class = 1 }, .{ .glyph = 7, .class = 2 } },
        3,
        &.{ &.{ 0, 0, 0 }, &.{ 0, -40, -60 } },
    );
    var file: File = .{};
    const gpos = gposOf(&file, 2, 0, subtable.written());
    try shape(.{ .gpos = gpos }, &.{ 5, 6 }, .{}).expectAdvances(&.{ 960, 1000 });
    try shape(.{ .gpos = gpos }, &.{ 5, 7 }, .{}).expectAdvances(&.{ 940, 1000 });
    try shape(.{ .gpos = gpos }, &.{ 5, 8 }, .{}).expectAdvances(&.{ 1000, 1000 });
    try shape(.{ .gpos = gpos }, &.{ 6, 7 }, .{}).expectAdvances(&.{ 1000, 1000 });
}

test "a pair is found across a mark the lookup's flags leave out" {
    var gdef: File = .{};
    layout.gdef(&gdef, .{ .kinds = &kinds });
    var subtable: File = .{};
    subtables.pairs(&subtable, &.{5}, X_ADVANCE, 0, &.{&.{.{ .second = 6, .values = &.{-50} }}});
    var file: File = .{};
    const tables: harness.Tables = .{ .gdef = gdef.written(), .gpos = gposOf(&file, 2, 0x0008, subtable.written()) };
    try shape(tables, &.{ 5, 50, 6 }, .{}).expectAdvances(&.{ 950, 1000, 1000 });
    var seeing: File = .{};
    const plain: harness.Tables = .{ .gdef = gdef.written(), .gpos = gposOf(&seeing, 2, 0, subtable.written()) };
    try shape(plain, &.{ 5, 50, 6 }, .{}).expectAdvances(&.{ 1000, 1000, 1000 });
}

test "a run read from right to left is answered turned around" {
    var subtable: File = .{};
    subtables.pairs(&subtable, &.{5}, X_ADVANCE, 0, &.{&.{.{ .second = 6, .values = &.{-50} }}});
    var file: File = .{};
    const run = shape(.{ .gpos = gposOf(&file, 2, 0, subtable.written()) }, &.{ 5, 6, 7 }, .{ .backward = true });
    try run.expectGlyphs(&.{ 7, 6, 5 });
    try run.expectClusters(&.{ 2, 1, 0 });
    try run.expectAdvances(&.{ 1000, 1000, 950 });
}

const joints = [_]subtables.Joint{
    .{ .exit = .{ .x = 600, .y = 100 } },
    .{ .entry = .{ .x = 50, .y = 300 }, .exit = .{ .x = 500, .y = 0 } },
};

test "cursive attachment: the later glyph's entry on the earlier one's exit" {
    var subtable: File = .{};
    subtables.cursive(&subtable, &.{ 5, 6 }, &joints);
    var file: File = .{};
    const gpos = gposOf(&file, 3, 0, subtable.written());
    const two = shape(.{ .gpos = gpos }, &.{ 5, 6 }, .{});
    try two.expectAdvances(&.{ 600, 950 });
    try two.expectOffsets(&.{ .{ 0, 0 }, .{ -50, -200 } });
    // Each glyph of a chain follows the one before it.
    const three = shape(.{ .gpos = gpos }, &.{ 5, 6, 6 }, .{});
    try three.expectAdvances(&.{ 600, 450, 950 });
    try three.expectOffsets(&.{ .{ 0, 0 }, .{ -50, -200 }, .{ -50, -500 } });
    // A glyph with no entry is not joined to what stands before it.
    const apart = shape(.{ .gpos = gpos }, &.{ 6, 5 }, .{});
    try apart.expectAdvances(&.{ 1000, 1000 });
}

test "cursive attachment: with the lookup's flag the earlier glyph follows the later" {
    var subtable: File = .{};
    subtables.cursive(&subtable, &.{ 5, 6 }, &joints);
    var file: File = .{};
    const gpos = gposOf(&file, 3, 0x0001, subtable.written());
    const two = shape(.{ .gpos = gpos }, &.{ 5, 6 }, .{});
    try two.expectAdvances(&.{ 600, 950 });
    try two.expectOffsets(&.{ .{ 0, 200 }, .{ -50, 0 } });
    // The last glyph stays on the line, and the chain rises towards the
    // first.
    const three = shape(.{ .gpos = gpos }, &.{ 5, 6, 6 }, .{});
    try three.expectOffsets(&.{ .{ 0, 500 }, .{ -50, 300 }, .{ -50, 0 } });
}

test "cursive attachment in a run read from right to left" {
    var subtable: File = .{};
    subtables.cursive(&subtable, &.{ 5, 6 }, &joints);
    var file: File = .{};
    const run = shape(.{ .gpos = gposOf(&file, 3, 0, subtable.written()) }, &.{ 5, 6 }, .{ .backward = true });
    try run.expectGlyphs(&.{ 6, 5 });
    try run.expectAdvances(&.{ 50, 400 });
    try run.expectOffsets(&.{ .{ 0, -200 }, .{ -600, 0 } });
}

const marks = [_]subtables.Mark{
    .{ .class = 0, .anchor = .{ .x = 100, .y = 0 } },
    .{ .class = 1, .anchor = .{ .x = 200, .y = -50 } },
};

test "mark-to-base attachment: the mark's anchor on the base glyph's for its class" {
    var gdef: File = .{};
    layout.gdef(&gdef, .{ .kinds = &kinds });
    var subtable: File = .{};
    subtables.markToBase(&subtable, &.{ 50, 51 }, &marks, &.{5}, 2, &.{
        &.{ .{ .x = 300, .y = 700 }, .{ .x = 250, .y = -100 } },
    });
    var file: File = .{};
    const tables: harness.Tables = .{ .gdef = gdef.written(), .gpos = gposOf(&file, 4, 0, subtable.written()) };
    // A mark's offsets reach back over the advances before it.
    const one = shape(tables, &.{ 5, 50 }, .{});
    try one.expectAdvances(&.{ 1000, 1000 });
    try one.expectOffsets(&.{ .{ 0, 0 }, .{ -800, 700 } });
    // Two marks sit on the one base glyph.
    const two = shape(tables, &.{ 5, 50, 51 }, .{});
    try two.expectOffsets(&.{ .{ 0, 0 }, .{ -800, 700 }, .{ -1950, -50 } });
    // A glyph with no anchors carries none, and a mark at the run's start
    // has nothing to sit on.
    try shape(tables, &.{ 6, 50 }, .{}).expectOffsets(&.{ .{ 0, 0 }, .{ 0, 0 } });
    try shape(tables, &.{ 50, 5 }, .{}).expectOffsets(&.{ .{ 0, 0 }, .{ 0, 0 } });
}

test "mark-to-base attachment in a run read from right to left" {
    var gdef: File = .{};
    layout.gdef(&gdef, .{ .kinds = &kinds });
    var subtable: File = .{};
    subtables.markToBase(&subtable, &.{50}, marks[0..1], &.{5}, 1, &.{&.{.{ .x = 300, .y = 700 }}});
    var file: File = .{};
    const tables: harness.Tables = .{ .gdef = gdef.written(), .gpos = gposOf(&file, 4, 0, subtable.written()) };
    const run = shape(tables, &.{ 5, 50 }, .{ .backward = true });
    try run.expectGlyphs(&.{ 50, 5 });
    // The mark is drawn first, its glyph an advance further on.
    try run.expectOffsets(&.{ .{ 1200, 700 }, .{ 0, 0 } });
}

test "mark-to-base attachment: a base with no anchor for the class leaves it to the next subtable" {
    var gdef: File = .{};
    layout.gdef(&gdef, .{ .kinds = &kinds });
    var first: File = .{};
    subtables.markToBase(&first, &.{ 50, 51 }, &marks, &.{5}, 2, &.{&.{ .{ .x = 300, .y = 700 }, null }});
    var second: File = .{};
    subtables.markToBase(&second, &.{51}, marks[1..2], &.{5}, 2, &.{&.{ null, .{ .x = 0, .y = 0 } }});
    var file: File = .{};
    layout.tableOfOne(&file, &.{.{ .kind = 4, .subtables = &.{ first.written(), second.written() } }});
    const tables: harness.Tables = .{ .gdef = gdef.written(), .gpos = file.written() };
    try shape(tables, &.{ 5, 51 }, .{}).expectOffsets(&.{ .{ 0, 0 }, .{ -1200, 50 } });
}

/// A `GSUB` that makes 40 of 5 and 6, across marks.
fn ligatureAcrossMarks(file: *File, subtable: *File) []const u8 {
    subtables.ligature(subtable, &.{5}, &.{&.{.{ .glyph = 40, .rest = &.{6} }}});
    layout.tableOfOne(file, &.{.{ .kind = 4, .flags = 0x0008, .subtables = &.{subtable.written()} }});
    return file.written();
}

test "mark-to-ligature attachment: on the part the mark stood behind" {
    var gdef: File = .{};
    layout.gdef(&gdef, .{ .kinds = &kinds });
    var ligature: File = .{};
    var gsub: File = .{};
    var subtable: File = .{};
    subtables.markToLigature(&subtable, &.{50}, marks[0..1], &.{40}, 1, &.{&.{
        &.{.{ .x = 200, .y = 500 }},
        &.{.{ .x = 700, .y = 500 }},
    }});
    var file: File = .{};
    const tables: harness.Tables = .{
        .gdef = gdef.written(),
        .gsub = ligatureAcrossMarks(&gsub, &ligature),
        .gpos = gposOf(&file, 5, 0, subtable.written()),
    };
    const run = shape(tables, &.{ 5, 50, 6, 50 }, .{});
    try run.expectGlyphs(&.{ 40, 50, 50 });
    try run.expectOffsets(&.{ .{ 0, 0 }, .{ -900, 500 }, .{ -1400, 500 } });
    // A ligature that was not made here carries its marks on its last
    // part.
    try shape(tables, &.{ 40, 50 }, .{}).expectOffsets(&.{ .{ 0, 0 }, .{ -400, 500 } });
}

test "mark-to-mark attachment: on the mark before it, which sits on the same glyph" {
    var gdef: File = .{};
    layout.gdef(&gdef, .{ .kinds = &kinds });
    var on_base: File = .{};
    subtables.markToBase(&on_base, &.{50}, marks[0..1], &.{5}, 1, &.{&.{.{ .x = 300, .y = 700 }}});
    var on_mark: File = .{};
    subtables.markToBase(&on_mark, &.{51}, &.{.{ .class = 0, .anchor = .{ .x = 10, .y = 0 } }}, &.{50}, 1, &.{&.{.{ .x = 20, .y = 300 }}});
    var file: File = .{};
    layout.tableOfOne(&file, &.{
        .{ .kind = 4, .subtables = &.{on_base.written()} },
        .{ .kind = 6, .subtables = &.{on_mark.written()} },
    });
    const tables: harness.Tables = .{ .gdef = gdef.written(), .gpos = file.written() };
    // The upper mark's place takes in the lower one's.
    const run = shape(tables, &.{ 5, 50, 51 }, .{});
    try run.expectOffsets(&.{ .{ 0, 0 }, .{ -800, 700 }, .{ -1790, 1000 } });
    // No mark before it: nothing to sit on.
    try shape(tables, &.{ 5, 51 }, .{}).expectOffsets(&.{ .{ 0, 0 }, .{ 0, 0 } });
}

test "mark-to-mark attachment: not across the parts of a ligature" {
    var gdef: File = .{};
    layout.gdef(&gdef, .{ .kinds = &kinds });
    var ligature: File = .{};
    var gsub: File = .{};
    var on_mark: File = .{};
    subtables.markToBase(&on_mark, &.{51}, &.{.{ .class = 0, .anchor = .{ .x = 10, .y = 0 } }}, &.{50}, 1, &.{&.{.{ .x = 20, .y = 300 }}});
    var file: File = .{};
    const tables: harness.Tables = .{
        .gdef = gdef.written(),
        .gsub = ligatureAcrossMarks(&gsub, &ligature),
        .gpos = gposOf(&file, 6, 0, on_mark.written()),
    };
    // The two marks stood behind different parts.
    const apart = shape(tables, &.{ 5, 50, 6, 51 }, .{});
    try apart.expectGlyphs(&.{ 40, 50, 51 });
    try apart.expectOffsets(&.{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } });
    // Behind the same part they meet.
    const together = shape(tables, &.{ 5, 6, 50, 51 }, .{});
    try together.expectGlyphs(&.{ 40, 50, 51 });
    try together.expectOffsets(&.{ .{ 0, 0 }, .{ 0, 0 }, .{ -990, 300 } });
}

test "a chained context applies a positioning at a place" {
    var narrow: File = .{};
    subtables.positionAll(&narrow, &.{5}, X_ADVANCE, &.{-100});
    var subtable: File = .{};
    subtables.chain3(&subtable, &.{}, &.{&.{5}}, &.{&.{6}}, &.{.{ .at = 0, .lookup = 1 }});
    var file: File = .{};
    layout.table(&file, &.{.{ .tag = "test", .lookups = &.{0} }}, &.{
        .{ .kind = 8, .subtables = &.{subtable.written()} },
        .{ .kind = 1, .subtables = &.{narrow.written()} },
    });
    try shape(.{ .gpos = file.written() }, &.{ 5, 6, 5, 7 }, .{}).expectAdvances(&.{ 900, 1000, 1000, 1000 });
}

test "a context applies a positioning at a place" {
    var narrow: File = .{};
    subtables.positionAll(&narrow, &.{6}, X_ADVANCE, &.{-100});
    var subtable: File = .{};
    subtables.context1(&subtable, &.{5}, &.{&.{.{ .rest = &.{6}, .records = &.{.{ .at = 1, .lookup = 1 }} }}});
    var file: File = .{};
    layout.table(&file, &.{.{ .tag = "test", .lookups = &.{0} }}, &.{
        .{ .kind = 7, .subtables = &.{subtable.written()} },
        .{ .kind = 1, .subtables = &.{narrow.written()} },
    });
    try shape(.{ .gpos = file.written() }, &.{ 5, 6, 6 }, .{}).expectAdvances(&.{ 1000, 900, 1000 });
}

test "an extension subtable of a positioning is followed" {
    var inner: File = .{};
    subtables.positionAll(&inner, &.{5}, X_ADVANCE, &.{-100});
    var subtable: File = .{};
    subtables.extension(&subtable, 1, inner.written());
    var file: File = .{};
    try shape(.{ .gpos = gposOf(&file, 9, 0, subtable.written()) }, &.{5}, .{}).expectAdvances(&.{900});
}

test "the glyphs are replaced before they are placed" {
    var replaced: File = .{};
    subtables.singleDelta(&replaced, &.{5}, 1);
    var gsub: File = .{};
    layout.tableOfOne(&gsub, &.{.{ .kind = 1, .subtables = &.{replaced.written()} }});
    var subtable: File = .{};
    subtables.positionAll(&subtable, &.{6}, X_ADVANCE, &.{-100});
    var file: File = .{};
    const run = shape(.{ .gsub = gsub.written(), .gpos = gposOf(&file, 1, 0, subtable.written()) }, &.{5}, .{});
    try run.expectGlyphs(&.{6});
    try run.expectAdvances(&.{900});
}

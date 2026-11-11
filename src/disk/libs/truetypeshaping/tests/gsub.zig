// SPDX-License-Identifier: MIT
//! Host tests of the substitutions: each kind of `GSUB` lookup on a table
//! built here, and the flags by which a lookup leaves glyphs out.

const std = @import("std");
const sdk = @import("sdk");
const tts = sdk.truetypeshaping;
const layout = @import("layout.zig");
const subtables = @import("subtables.zig");
const harness = @import("harness.zig");

const File = layout.File;
const shape = harness.shape;

/// A `GSUB` of one feature with one lookup of one subtable.
fn gsubOf(file: *File, kind: u16, flags: u16, subtable: []const u8) []const u8 {
    layout.tableOfOne(file, &.{.{ .kind = kind, .flags = flags, .subtables = &.{subtable} }});
    return file.written();
}

test "single substitution, format 1: the glyph's number plus a difference" {
    var subtable: File = .{};
    subtables.singleDelta(&subtable, &.{ 5, 6 }, 10);
    var file: File = .{};
    const run = shape(.{ .gsub = gsubOf(&file, 1, 0, subtable.written()) }, &.{ 4, 5, 6, 7 }, .{});
    try run.expectGlyphs(&.{ 4, 15, 16, 7 });
    try run.expectClusters(&.{ 0, 1, 2, 3 });
}

test "single substitution, format 1: the sum wraps at 65536" {
    var subtable: File = .{};
    subtables.singleDelta(&subtable, &.{5}, -10);
    var file: File = .{};
    const run = shape(.{ .gsub = gsubOf(&file, 1, 0, subtable.written()) }, &.{5}, .{});
    try run.expectGlyphs(&.{65531});
}

test "single substitution, format 2: each glyph its own substitute" {
    var subtable: File = .{};
    subtables.singleList(&subtable, &.{ 5, 7 }, &.{ 20, 21 });
    var file: File = .{};
    const run = shape(.{ .gsub = gsubOf(&file, 1, 0, subtable.written()) }, &.{ 7, 6, 5 }, .{});
    try run.expectGlyphs(&.{ 21, 6, 20 });
}

test "multiple substitution: one glyph becomes several, all of its cluster" {
    var subtable: File = .{};
    subtables.multiple(&subtable, &.{5}, &.{&.{ 20, 21, 22 }});
    var file: File = .{};
    const run = shape(.{ .gsub = gsubOf(&file, 2, 0, subtable.written()) }, &.{ 4, 5, 6 }, .{});
    try run.expectGlyphs(&.{ 4, 20, 21, 22, 6 });
    try run.expectClusters(&.{ 0, 1, 1, 1, 2 });
}

test "multiple substitution: a sequence of one replaces, a sequence of none deletes" {
    var subtable: File = .{};
    subtables.multiple(&subtable, &.{ 5, 8 }, &.{ &.{20}, &.{} });
    var file: File = .{};
    const run = shape(.{ .gsub = gsubOf(&file, 2, 0, subtable.written()) }, &.{ 4, 8, 5, 8 }, .{});
    try run.expectGlyphs(&.{ 4, 20 });
    try run.expectClusters(&.{ 0, 2 });
}

test "multiple substitution: a run does not grow past its limit" {
    // Each lookup makes 128 glyphs of every glyph: the second fills what
    // a short run may grow to, and the third finds no room.
    const many: [128]u16 = @splat(5);
    var manifold: File = .{};
    subtables.multiple(&manifold, &.{5}, &.{&many});
    var folds: [3]layout.Lookup = undefined;
    for (&folds) |*lookup| lookup.* = .{ .kind = 2, .subtables = &.{manifold.written()} };
    var short: File = .{};
    layout.tableOfOne(&short, &folds);
    const run = shape(.{ .gsub = short.written() }, &.{5}, .{});
    try std.testing.expectEqual(tts.TTSERR_ROOM, run.result);
    try std.testing.expectEqual(@as(u32, 16384), run.count);

    // A longer run grows to 64 times its length: each lookup doubles
    // every glyph, and the feature has more of them than the limit has
    // doublings.
    var subtable: File = .{};
    subtables.multiple(&subtable, &.{5}, &.{&.{ 5, 5 }});
    var lookups: [20]layout.Lookup = undefined;
    for (&lookups) |*lookup| lookup.* = .{ .kind = 2, .subtables = &.{subtable.written()} };
    var file: File = .{};
    layout.tableOfOne(&file, &lookups);
    var long: [300]u16 = @splat(5);
    _ = &long;
    try std.testing.expectEqual(@as(u32, 300 * 64), shape(.{ .gsub = file.written() }, &long, .{}).count);
}

test "alternate substitution: the feature's value picks the form" {
    var subtable: File = .{};
    subtables.multiple(&subtable, &.{5}, &.{&.{ 30, 31, 32 }});
    var file: File = .{};
    const gsub = gsubOf(&file, 3, 0, subtable.written());
    const tag = tts.featureTag("test");
    try shape(.{ .gsub = gsub }, &.{5}, .{}).expectGlyphs(&.{30});
    try shape(.{ .gsub = gsub }, &.{5}, .{ .features = &.{.{ .tag = tag, .value = 2 }} }).expectGlyphs(&.{31});
    try shape(.{ .gsub = gsub }, &.{5}, .{ .features = &.{.{ .tag = tag, .value = 3 }} }).expectGlyphs(&.{32});
    try shape(.{ .gsub = gsub }, &.{5}, .{ .features = &.{.{ .tag = tag, .value = 4 }} }).expectGlyphs(&.{5});
    try shape(.{ .gsub = gsub }, &.{5}, .{ .features = &.{.{ .tag = tag, .value = 0 }} }).expectGlyphs(&.{5});
}

test "ligature substitution: the first of a glyph's ligatures that is there, with the lowest cluster" {
    var subtable: File = .{};
    subtables.ligature(&subtable, &.{5}, &.{&.{
        .{ .glyph = 41, .rest = &.{ 6, 7 } },
        .{ .glyph = 40, .rest = &.{6} },
    }});
    var file: File = .{};
    const run = shape(.{ .gsub = gsubOf(&file, 4, 0, subtable.written()) }, &.{ 5, 6, 7, 5, 6, 9, 5 }, .{});
    try run.expectGlyphs(&.{ 41, 40, 9, 5 });
    try run.expectClusters(&.{ 0, 3, 5, 6 });
}

test "ligature substitution: a ligature of one glyph replaces it" {
    var subtable: File = .{};
    subtables.ligature(&subtable, &.{5}, &.{&.{.{ .glyph = 40, .rest = &.{} }}});
    var file: File = .{};
    try shape(.{ .gsub = gsubOf(&file, 4, 0, subtable.written()) }, &.{ 5, 6 }, .{}).expectGlyphs(&.{ 40, 6 });
}

const kinds = [_]layout.InClass{
    .{ .glyph = 5, .class = 1 },
    .{ .glyph = 6, .class = 1 },
    .{ .glyph = 40, .class = 2 },
    .{ .glyph = 50, .class = 3 },
    .{ .glyph = 51, .class = 3 },
};

fn fiLigature(subtable: *File) void {
    subtables.ligature(subtable, &.{5}, &.{&.{.{ .glyph = 40, .rest = &.{6} }}});
}

test "a lookup that ignores marks makes a ligature across one, which stays behind it" {
    var gdef: File = .{};
    layout.gdef(&gdef, .{ .kinds = &kinds });
    var subtable: File = .{};
    fiLigature(&subtable);
    var file: File = .{};
    const tables: harness.Tables = .{ .gdef = gdef.written(), .gsub = gsubOf(&file, 4, 0x0008, subtable.written()) };
    const run = shape(tables, &.{ 5, 50, 6, 51 }, .{});
    try run.expectGlyphs(&.{ 40, 50, 51 });
    try run.expectClusters(&.{ 0, 0, 3 });
    // A lookup that sees the mark finds the two glyphs apart.
    var seeing: File = .{};
    const plain: harness.Tables = .{ .gdef = gdef.written(), .gsub = gsubOf(&seeing, 4, 0, subtable.written()) };
    try shape(plain, &.{ 5, 50, 6 }, .{}).expectGlyphs(&.{ 5, 50, 6 });
}

test "a lookup sees only the marks of the class its flags name" {
    var gdef: File = .{};
    layout.gdef(&gdef, .{ .kinds = &kinds, .mark_classes = &.{ .{ .glyph = 50, .class = 1 }, .{ .glyph = 51, .class = 2 } } });
    var subtable: File = .{};
    fiLigature(&subtable);
    var file: File = .{};
    const tables: harness.Tables = .{ .gdef = gdef.written(), .gsub = gsubOf(&file, 4, 0x0100, subtable.written()) };
    try shape(tables, &.{ 5, 51, 6 }, .{}).expectGlyphs(&.{ 40, 51 });
    try shape(tables, &.{ 5, 50, 6 }, .{}).expectGlyphs(&.{ 5, 50, 6 });
}

test "a lookup sees only the marks of the set its flags name" {
    var gdef: File = .{};
    layout.gdef(&gdef, .{ .kinds = &kinds, .mark_sets = &.{ &.{51}, &.{50} } });
    var subtable: File = .{};
    fiLigature(&subtable);
    var file: File = .{};
    layout.tableOfOne(&file, &.{.{ .kind = 4, .flags = 0x0010, .mark_set = 1, .subtables = &.{subtable.written()} }});
    const tables: harness.Tables = .{ .gdef = gdef.written(), .gsub = file.written() };
    try shape(tables, &.{ 5, 51, 6 }, .{}).expectGlyphs(&.{ 40, 51 });
    try shape(tables, &.{ 5, 50, 6 }, .{}).expectGlyphs(&.{ 5, 50, 6 });
}

test "a lookup that ignores base glyphs or ligatures does not replace one" {
    var gdef: File = .{};
    layout.gdef(&gdef, .{ .kinds = &kinds });
    var subtable: File = .{};
    subtables.singleDelta(&subtable, &.{ 5, 40, 50 }, 100);
    var bases: File = .{};
    const no_bases: harness.Tables = .{ .gdef = gdef.written(), .gsub = gsubOf(&bases, 1, 0x0002, subtable.written()) };
    try shape(no_bases, &.{ 5, 40, 50 }, .{}).expectGlyphs(&.{ 5, 140, 150 });
    var ligatures: File = .{};
    const no_ligatures: harness.Tables = .{ .gdef = gdef.written(), .gsub = gsubOf(&ligatures, 1, 0x0004, subtable.written()) };
    try shape(no_ligatures, &.{ 5, 40, 50 }, .{}).expectGlyphs(&.{ 105, 40, 150 });
}

test "reverse chained substitution: from the run's end, each glyph by what stands around it" {
    var subtable: File = .{};
    subtables.reverse(&subtable, &.{5}, &.{}, &.{&.{6}}, &.{20});
    var file: File = .{};
    // The last 5 stands before a 6; the one before it stands before what
    // that became, which is no 6.
    try shape(.{ .gsub = gsubOf(&file, 8, 0, subtable.written()) }, &.{ 5, 5, 6 }, .{}).expectGlyphs(&.{ 5, 20, 6 });
    var both: File = .{};
    subtables.reverse(&both, &.{5}, &.{&.{4}}, &.{&.{6}}, &.{20});
    var second: File = .{};
    const gsub = gsubOf(&second, 8, 0, both.written());
    try shape(.{ .gsub = gsub }, &.{ 4, 5, 6 }, .{}).expectGlyphs(&.{ 4, 20, 6 });
    try shape(.{ .gsub = gsub }, &.{ 5, 6 }, .{}).expectGlyphs(&.{ 5, 6 });
    try shape(.{ .gsub = gsub }, &.{ 4, 5 }, .{}).expectGlyphs(&.{ 4, 5 });
}

test "an extension subtable is followed to the subtable it names" {
    var inner: File = .{};
    subtables.singleDelta(&inner, &.{5}, 10);
    var subtable: File = .{};
    subtables.extension(&subtable, 1, inner.written());
    var file: File = .{};
    try shape(.{ .gsub = gsubOf(&file, 7, 0, subtable.written()) }, &.{5}, .{}).expectGlyphs(&.{15});
    // One that names an extension again is not followed.
    var twice: File = .{};
    subtables.extension(&twice, 7, subtable.written());
    var second: File = .{};
    try shape(.{ .gsub = gsubOf(&second, 7, 0, twice.written()) }, &.{5}, .{}).expectGlyphs(&.{5});
}

test "of a lookup's subtables the first that applies at a glyph does" {
    var first: File = .{};
    subtables.singleDelta(&first, &.{5}, 10);
    var second: File = .{};
    subtables.singleDelta(&second, &.{ 5, 6 }, 100);
    var file: File = .{};
    layout.tableOfOne(&file, &.{.{ .kind = 1, .subtables = &.{ first.written(), second.written() } }});
    try shape(.{ .gsub = file.written() }, &.{ 5, 6 }, .{}).expectGlyphs(&.{ 15, 106 });
}

test "lookups are applied in the table's order, each to the whole run" {
    var to_six: File = .{};
    subtables.singleDelta(&to_six, &.{5}, 1);
    var to_seven: File = .{};
    subtables.singleDelta(&to_seven, &.{6}, 1);
    var file: File = .{};
    // The feature names the second lookup first; the table's order holds.
    layout.table(&file, &.{.{ .tag = "test", .lookups = &.{ 1, 0 } }}, &.{
        .{ .kind = 1, .subtables = &.{to_six.written()} },
        .{ .kind = 1, .subtables = &.{to_seven.written()} },
    });
    try shape(.{ .gsub = file.written() }, &.{ 5, 6 }, .{}).expectGlyphs(&.{ 7, 7 });
}

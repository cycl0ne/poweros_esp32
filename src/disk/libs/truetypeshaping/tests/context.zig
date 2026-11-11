// SPDX-License-Identifier: MIT
//! Host tests of the lookups that apply other lookups: the three formats
//! of the context and of the chained context, on tables built here, and
//! what holds when a lookup applied at a place changes the run's length.

const std = @import("std");
const tts = @import("sdk").truetypeshaping;
const layout = @import("layout.zig");
const subtables = @import("subtables.zig");
const harness = @import("harness.zig");

const File = layout.File;
const Record = subtables.Record;
const shape = harness.shape;

/// A `GSUB` whose feature has its first lookup alone - of the kind `kind`
/// with the subtable `first` - and whose other lookups are `others`,
/// numbered from 1 on, for the first to apply.
fn gsubAround(file: *File, kind: u16, first: []const u8, others: []const layout.Lookup) []const u8 {
    var lookups: [8]layout.Lookup = undefined;
    lookups[0] = .{ .kind = kind, .subtables = &.{first} };
    for (others, 1..) |other, index| lookups[index] = other;
    layout.table(file, &.{.{ .tag = "test", .lookups = &.{0} }}, lookups[0 .. others.len + 1]);
    return file.written();
}

test "context, format 1: a sequence of glyphs, a lookup at one of its places" {
    var single: File = .{};
    subtables.singleDelta(&single, &.{ 5, 6, 7 }, 10);
    const add_ten: layout.Lookup = .{ .kind = 1, .subtables = &.{single.written()} };
    var subtable: File = .{};
    subtables.context1(&subtable, &.{5}, &.{&.{
        .{ .rest = &.{ 6, 7 }, .records = &.{.{ .at = 1, .lookup = 1 }} },
        .{ .rest = &.{6}, .records = &.{.{ .at = 0, .lookup = 1 }} },
    }});
    var file: File = .{};
    const gsub = gsubAround(&file, 5, subtable.written(), &.{add_ten});
    try shape(.{ .gsub = gsub }, &.{ 5, 6, 7 }, .{}).expectGlyphs(&.{ 5, 16, 7 });
    // The second rule, where the first does not match.
    try shape(.{ .gsub = gsub }, &.{ 5, 6, 8 }, .{}).expectGlyphs(&.{ 15, 6, 8 });
    try shape(.{ .gsub = gsub }, &.{ 5, 7, 6 }, .{}).expectGlyphs(&.{ 5, 7, 6 });
    // After a sequence the run goes on behind it.
    try shape(.{ .gsub = gsub }, &.{ 5, 6, 5, 6, 7 }, .{}).expectGlyphs(&.{ 15, 6, 5, 16, 7 });
}

test "context, format 2: a sequence of classes" {
    var single: File = .{};
    subtables.singleDelta(&single, &.{ 5, 6, 7, 8 }, 10);
    const add_ten: layout.Lookup = .{ .kind = 1, .subtables = &.{single.written()} };
    var subtable: File = .{};
    const class_list = [_]layout.InClass{
        .{ .glyph = 5, .class = 1 },
        .{ .glyph = 6, .class = 2 },
        .{ .glyph = 7, .class = 2 },
    };
    // A sequence that starts with class 1 and goes on with two of class 2.
    subtables.context2(&subtable, &.{ 5, 6, 7, 8 }, &class_list, &.{
        &.{},
        &.{.{ .rest = &.{ 2, 2 }, .records = &.{ .{ .at = 0, .lookup = 1 }, .{ .at = 2, .lookup = 1 } } }},
    });
    var file: File = .{};
    const gsub = gsubAround(&file, 5, subtable.written(), &.{add_ten});
    try shape(.{ .gsub = gsub }, &.{ 5, 6, 7 }, .{}).expectGlyphs(&.{ 15, 6, 17 });
    try shape(.{ .gsub = gsub }, &.{ 5, 7, 6 }, .{}).expectGlyphs(&.{ 15, 7, 16 });
    try shape(.{ .gsub = gsub }, &.{ 5, 6, 8 }, .{}).expectGlyphs(&.{ 5, 6, 8 });
    try shape(.{ .gsub = gsub }, &.{ 6, 6, 6 }, .{}).expectGlyphs(&.{ 6, 6, 6 });
}

test "context, format 3: a coverage for each place" {
    var single: File = .{};
    subtables.singleDelta(&single, &.{ 5, 6, 7, 8 }, 10);
    const add_ten: layout.Lookup = .{ .kind = 1, .subtables = &.{single.written()} };
    var subtable: File = .{};
    subtables.context3(&subtable, &.{ &.{ 5, 6 }, &.{ 7, 8 } }, &.{.{ .at = 1, .lookup = 1 }});
    var file: File = .{};
    const gsub = gsubAround(&file, 5, subtable.written(), &.{add_ten});
    try shape(.{ .gsub = gsub }, &.{ 5, 7 }, .{}).expectGlyphs(&.{ 5, 17 });
    try shape(.{ .gsub = gsub }, &.{ 6, 8 }, .{}).expectGlyphs(&.{ 6, 18 });
    try shape(.{ .gsub = gsub }, &.{ 7, 5 }, .{}).expectGlyphs(&.{ 7, 5 });
    try shape(.{ .gsub = gsub }, &.{6}, .{}).expectGlyphs(&.{6});
}

test "chained context, format 1: what stands before and after is not part of the sequence" {
    var single: File = .{};
    subtables.singleDelta(&single, &.{ 4, 5, 6, 7 }, 10);
    const add_ten: layout.Lookup = .{ .kind = 1, .subtables = &.{single.written()} };
    var subtable: File = .{};
    // Before the sequence a 4 and before that a 3; after it a 7.
    subtables.chain1(&subtable, &.{5}, &.{&.{
        .{ .before = &.{ 4, 3 }, .rest = &.{6}, .after = &.{7}, .records = &.{.{ .at = 1, .lookup = 1 }} },
    }});
    var file: File = .{};
    const gsub = gsubAround(&file, 6, subtable.written(), &.{add_ten});
    try shape(.{ .gsub = gsub }, &.{ 3, 4, 5, 6, 7 }, .{}).expectGlyphs(&.{ 3, 4, 5, 16, 7 });
    try shape(.{ .gsub = gsub }, &.{ 4, 3, 5, 6, 7 }, .{}).expectGlyphs(&.{ 4, 3, 5, 6, 7 });
    try shape(.{ .gsub = gsub }, &.{ 3, 4, 5, 6 }, .{}).expectGlyphs(&.{ 3, 4, 5, 6 });
    try shape(.{ .gsub = gsub }, &.{ 4, 5, 6, 7 }, .{}).expectGlyphs(&.{ 4, 5, 6, 7 });
    // A record's place counts in the sequence alone.
    try shape(.{ .gsub = gsub }, &.{ 3, 4, 5, 6, 7, 3, 4, 5, 6, 7 }, .{}).expectGlyphs(&.{ 3, 4, 5, 16, 7, 3, 4, 5, 16, 7 });
}

test "chained context, format 2: three class definitions" {
    var single: File = .{};
    subtables.singleDelta(&single, &.{ 5, 6 }, 10);
    const add_ten: layout.Lookup = .{ .kind = 1, .subtables = &.{single.written()} };
    var subtable: File = .{};
    subtables.chain2(
        &subtable,
        &.{ 5, 6 },
        &.{.{ .glyph = 4, .class = 1 }},
        &.{ .{ .glyph = 5, .class = 1 }, .{ .glyph = 6, .class = 2 } },
        &.{.{ .glyph = 7, .class = 3 }},
        &.{
            &.{},
            &.{.{ .before = &.{1}, .rest = &.{2}, .after = &.{3}, .records = &.{.{ .at = 0, .lookup = 1 }} }},
        },
    );
    var file: File = .{};
    const gsub = gsubAround(&file, 6, subtable.written(), &.{add_ten});
    try shape(.{ .gsub = gsub }, &.{ 4, 5, 6, 7 }, .{}).expectGlyphs(&.{ 4, 15, 6, 7 });
    try shape(.{ .gsub = gsub }, &.{ 7, 5, 6, 7 }, .{}).expectGlyphs(&.{ 7, 5, 6, 7 });
    try shape(.{ .gsub = gsub }, &.{ 4, 5, 6, 4 }, .{}).expectGlyphs(&.{ 4, 5, 6, 4 });
    try shape(.{ .gsub = gsub }, &.{ 4, 6, 6, 7 }, .{}).expectGlyphs(&.{ 4, 6, 6, 7 });
}

test "chained context, format 3: coverages before, for and after the sequence" {
    var single: File = .{};
    subtables.singleDelta(&single, &.{ 5, 6 }, 10);
    const add_ten: layout.Lookup = .{ .kind = 1, .subtables = &.{single.written()} };
    var subtable: File = .{};
    subtables.chain3(&subtable, &.{ &.{4}, &.{ 2, 3 } }, &.{ &.{5}, &.{6} }, &.{ &.{7}, &.{ 8, 9 } }, &.{
        .{ .at = 0, .lookup = 1 },
        .{ .at = 1, .lookup = 1 },
    });
    var file: File = .{};
    const gsub = gsubAround(&file, 6, subtable.written(), &.{add_ten});
    try shape(.{ .gsub = gsub }, &.{ 3, 4, 5, 6, 7, 9 }, .{}).expectGlyphs(&.{ 3, 4, 15, 16, 7, 9 });
    try shape(.{ .gsub = gsub }, &.{ 4, 4, 5, 6, 7, 9 }, .{}).expectGlyphs(&.{ 4, 4, 5, 6, 7, 9 });
    try shape(.{ .gsub = gsub }, &.{ 3, 4, 5, 6, 7 }, .{}).expectGlyphs(&.{ 3, 4, 5, 6, 7 });
    try shape(.{ .gsub = gsub }, &.{ 4, 5, 6, 7, 9 }, .{}).expectGlyphs(&.{ 4, 5, 6, 7, 9 });
}

test "a chained context with nothing to do stops the rules after it" {
    var single: File = .{};
    subtables.singleDelta(&single, &.{5}, 10);
    const add_ten: layout.Lookup = .{ .kind = 1, .subtables = &.{single.written()} };
    var subtable: File = .{};
    // A 5 before a 6 is left alone; any other 5 is replaced.
    subtables.chain1(&subtable, &.{5}, &.{&.{
        .{ .after = &.{6}, .records = &.{} },
        .{ .records = &.{.{ .at = 0, .lookup = 1 }} },
    }});
    var file: File = .{};
    const gsub = gsubAround(&file, 6, subtable.written(), &.{add_ten});
    try shape(.{ .gsub = gsub }, &.{ 5, 6, 5, 7 }, .{}).expectGlyphs(&.{ 5, 6, 15, 7 });
}

test "a context sees through the glyphs its lookup's flags leave out" {
    var gdef: File = .{};
    layout.gdef(&gdef, .{ .kinds = &.{ .{ .glyph = 5, .class = 1 }, .{ .glyph = 6, .class = 1 }, .{ .glyph = 50, .class = 3 } } });
    var single: File = .{};
    subtables.singleDelta(&single, &.{ 5, 6 }, 10);
    const add_ten: layout.Lookup = .{ .kind = 1, .subtables = &.{single.written()} };
    var subtable: File = .{};
    subtables.context1(&subtable, &.{5}, &.{&.{.{ .rest = &.{6}, .records = &.{.{ .at = 1, .lookup = 1 }} }}});
    var file: File = .{};
    layout.table(&file, &.{.{ .tag = "test", .lookups = &.{0} }}, &.{
        .{ .kind = 5, .flags = 0x0008, .subtables = &.{subtable.written()} },
        add_ten,
    });
    const tables: harness.Tables = .{ .gdef = gdef.written(), .gsub = file.written() };
    try shape(tables, &.{ 5, 50, 6 }, .{}).expectGlyphs(&.{ 5, 50, 16 });
}

test "a ligature made at a place moves the places behind it" {
    var ligature: File = .{};
    subtables.ligature(&ligature, &.{5}, &.{&.{.{ .glyph = 40, .rest = &.{6} }}});
    var single: File = .{};
    subtables.singleDelta(&single, &.{ 6, 7 }, 10);
    const add_ten: layout.Lookup = .{ .kind = 1, .subtables = &.{single.written()} };
    var subtable: File = .{};
    // 5 6 7: the first two joined, then the lookup at the place after.
    subtables.context3(&subtable, &.{ &.{5}, &.{6}, &.{7} }, &.{
        .{ .at = 0, .lookup = 1 },
        .{ .at = 1, .lookup = 2 },
    });
    var file: File = .{};
    const gsub = gsubAround(&file, 5, subtable.written(), &.{
        .{ .kind = 4, .subtables = &.{ligature.written()} },
        add_ten,
    });
    const run = shape(.{ .gsub = gsub }, &.{ 5, 6, 7, 6 }, .{});
    try run.expectGlyphs(&.{ 40, 17, 6 });
    try run.expectClusters(&.{ 0, 2, 3 });
}

test "glyphs a place became move the places behind it" {
    var multiple: File = .{};
    subtables.multiple(&multiple, &.{5}, &.{&.{ 30, 31, 32 }});
    var single: File = .{};
    subtables.singleDelta(&single, &.{ 6, 31 }, 10);
    const add_ten: layout.Lookup = .{ .kind = 1, .subtables = &.{single.written()} };
    var subtable: File = .{};
    // 5 6: the first becomes three, then the lookup at the place after it,
    // which is the second of the three.
    subtables.context3(&subtable, &.{ &.{5}, &.{6} }, &.{
        .{ .at = 0, .lookup = 1 },
        .{ .at = 1, .lookup = 2 },
    });
    var file: File = .{};
    const gsub = gsubAround(&file, 5, subtable.written(), &.{
        .{ .kind = 2, .subtables = &.{multiple.written()} },
        add_ten,
    });
    const run = shape(.{ .gsub = gsub }, &.{ 5, 6, 5 }, .{});
    try run.expectGlyphs(&.{ 30, 41, 32, 6, 5 });
    try run.expectClusters(&.{ 0, 0, 0, 1, 2 });
}

test "lookups that apply each other end" {
    var subtable: File = .{};
    // Lookup 0 applies itself at its own place.
    subtables.context3(&subtable, &.{&.{5}}, &.{.{ .at = 0, .lookup = 0 }});
    var file: File = .{};
    const gsub = gsubAround(&file, 5, subtable.written(), &.{});
    try shape(.{ .gsub = gsub }, &.{ 5, 5, 5 }, .{}).expectGlyphs(&.{ 5, 5, 5 });

    // Two that double a glyph and apply each other on what it became.
    var doubling: File = .{};
    subtables.multiple(&doubling, &.{5}, &.{&.{ 5, 5 }});
    var again: File = .{};
    subtables.context3(&again, &.{&.{5}}, &.{
        .{ .at = 0, .lookup = 1 },
        .{ .at = 0, .lookup = 0 },
        .{ .at = 1, .lookup = 0 },
    });
    var second: File = .{};
    const growing = gsubAround(&second, 5, again.written(), &.{.{ .kind = 2, .subtables = &.{doubling.written()} }});
    const run = shape(.{ .gsub = growing }, &.{5}, .{});
    try std.testing.expect(run.result == tts.TTS_OK or run.result == tts.TTSERR_ROOM);
    try std.testing.expect(run.count <= 16384);
}

test "a sequence longer than a lookup may match does nothing" {
    var single: File = .{};
    subtables.singleDelta(&single, &.{5}, 10);
    const add_ten: layout.Lookup = .{ .kind = 1, .subtables = &.{single.written()} };
    var rest: [64]u16 = @splat(5);
    _ = &rest;
    var fits: File = .{};
    subtables.context1(&fits, &.{5}, &.{&.{.{ .rest = rest[0..63], .records = &.{.{ .at = 0, .lookup = 1 }} }}});
    var long: [70]u16 = @splat(5);
    _ = &long;
    var file: File = .{};
    const run = shape(.{ .gsub = gsubAround(&file, 5, fits.written(), &.{add_ten}) }, &long, .{});
    try std.testing.expectEqual(@as(u32, 15), run.glyphs[0].glyph);
    try std.testing.expectEqual(@as(u32, 5), run.glyphs[1].glyph);

    var too_long: File = .{};
    subtables.context1(&too_long, &.{5}, &.{&.{.{ .rest = &rest, .records = &.{.{ .at = 0, .lookup = 1 }} }}});
    var second: File = .{};
    const untouched = shape(.{ .gsub = gsubAround(&second, 5, too_long.written(), &.{add_ten}) }, &long, .{});
    try std.testing.expectEqual(@as(u32, 5), untouched.glyphs[0].glyph);
}

test "a chained context that ends behind its sequence's count does nothing" {
    // Format 3 with nothing before and a sequence of one glyph; the table
    // ends where that glyph's coverage would be named, and one number
    // further on.
    for ([_][]const u8{ &.{ 0, 3, 0, 0, 0, 1 }, &.{ 0, 3, 0, 0, 0, 1, 0, 0 } }) |cut| {
        var file: File = .{};
        layout.tableOfOne(&file, &.{.{ .kind = 6, .subtables = &.{cut} }});
        const run = shape(.{ .gsub = file.written() }, &.{ 5, 6 }, .{});
        try run.expectGlyphs(&.{ 5, 6 });
    }
}

test "a table's work on a run is bounded" {
    // The feature's first lookup matches at every glyph and applies, as
    // often as it has records, a lookup of rules none of which matches;
    // its second makes 6 of 5.
    const most = 1000;
    const calls: [most]Record = @splat(.{ .at = 0, .lookup = 1 });
    const misses: [most]subtables.Rule = @splat(.{ .rest = &.{99}, .records = &.{} });
    const fives: [8]u16 = @splat(5);
    for ([_]u32{ 10, most }) |count| {
        var caller: File = .{};
        subtables.context1(&caller, &.{5}, &.{&.{.{ .records = calls[0..count] }}});
        var missing: File = .{};
        subtables.context1(&missing, &.{5}, &.{misses[0..count]});
        var single: File = .{};
        subtables.singleDelta(&single, &.{5}, 1);
        var file: File = .{};
        layout.table(&file, &.{.{ .tag = "test", .lookups = &.{ 0, 2 } }}, &.{
            .{ .kind = 5, .subtables = &.{caller.written()} },
            .{ .kind = 5, .subtables = &.{missing.written()} },
            .{ .kind = 1, .subtables = &.{single.written()} },
        });
        const run = shape(.{ .gsub = file.written() }, &fives, .{});
        try std.testing.expectEqual(tts.TTS_OK, run.result);
        // Ten times ten rules are soon tried. A thousand times a thousand
        // at each glyph is more than a run of eight has: the table's work
        // ends in the first lookup, and the second is not applied.
        const expected: [8]u32 = @splat(if (count == 10) 6 else 5);
        try run.expectGlyphs(&expected);
    }
}

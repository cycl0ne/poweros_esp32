// SPDX-License-Identifier: MIT
//! Host tests of a variable font's place: what an item of a store of
//! deltas adds there, and the positionings that take it - a value
//! record's devices, an anchor's - on tables built here. The stores are
//! read by truetype.library's reader, as a font's outline reads them.
//! Every glyph's advance is 1000 before the lookups run.

const std = @import("std");
const layout = @import("layout.zig");
const subtables = @import("subtables.zig");
const harness = @import("harness.zig");
const Place = @import("../shape/_variation.zig").Place;

const File = layout.File;
const shape = harness.shape;
const testing = std.testing;
const X_PLACEMENT = subtables.X_PLACEMENT;
const Y_PLACEMENT = subtables.Y_PLACEMENT;
const X_ADVANCE = subtables.X_ADVANCE;
const Y_ADVANCE = subtables.Y_ADVANCE;

/// The bits of a value record's format for its devices.
const X_PLACEMENT_DEVICE: u16 = 0x0010;
const Y_PLACEMENT_DEVICE: u16 = 0x0020;
const X_ADVANCE_DEVICE: u16 = 0x0040;
const Y_ADVANCE_DEVICE: u16 = 0x0080;

const store = layout.store;

/// What the item `item` of the list `list` of the store `bytes` adds at
/// the place `coords`.
fn deltaAt(bytes: []const u8, coords: []const i16, list: u16, item: u16) i32 {
    var named: File = .{};
    subtables.device(&named, list, item);
    var work: u32 = 1000;
    var at = coords;
    return placeAt(&at, bytes).delta(.{ .bytes = named.written() }, &work);
}

/// The place `coords` of a font whose store of deltas is `bytes`.
fn placeAt(coords: *[]const i16, bytes: []const u8) Place {
    return .{ .varied = coords.len != 0, .store = .{ .bytes = bytes }, .context = @ptrCast(coords), .deltaFn = harness.deltaAt };
}

const full = 16384;
const half = 8192;

/// A region that counts the further an axis goes above its default, and
/// one for below it.
const above = [3]i16{ 0, full, full };
const below = [3]i16{ -full, -full, 0 };
const unsaid = [3]i16{ 0, 0, 0 };

test "a store's delta: each of a row's deltas as far as its region counts at the font's place" {
    var file: File = .{};
    store(&file, 2, &.{
        &.{ above, unsaid },
        &.{ unsaid, below },
        &.{ above, above },
        &.{ .{ 0, half, full }, unsaid },
    }, &.{.{ .regions = &.{ 0, 1, 2, 3 }, .wide = 4, .rows = &.{&.{ 100, -60, 40, 20 }} }});
    const bytes = file.written();
    // Along the first axis: its own region, and the one with a peak
    // halfway, which counts less again past that.
    try testing.expectEqual(@as(i32, 100), deltaAt(bytes, &.{ full, 0 }, 0, 0));
    try testing.expectEqual(@as(i32, 70), deltaAt(bytes, &.{ half, 0 }, 0, 0));
    try testing.expectEqual(@as(i32, 35), deltaAt(bytes, &.{ 4096, 0 }, 0, 0));
    try testing.expectEqual(@as(i32, 85), deltaAt(bytes, &.{ 12288, 0 }, 0, 0));
    // Down the second.
    try testing.expectEqual(@as(i32, -60), deltaAt(bytes, &.{ 0, -full }, 0, 0));
    try testing.expectEqual(@as(i32, -30), deltaAt(bytes, &.{ 0, -half }, 0, 0));
    // A region of two axes counts as far as both do, multiplied.
    try testing.expectEqual(@as(i32, 140), deltaAt(bytes, &.{ full, full }, 0, 0));
    try testing.expectEqual(@as(i32, 80), deltaAt(bytes, &.{ half, half }, 0, 0));
    // No region counts on the other side of an axis, and none at the
    // default.
    try testing.expectEqual(@as(i32, 0), deltaAt(bytes, &.{ -full, full }, 0, 0));
    try testing.expectEqual(@as(i32, 0), deltaAt(bytes, &.{ 0, 0 }, 0, 0));
    try testing.expectEqual(@as(i32, 0), deltaAt(bytes, &.{}, 0, 0));
}

test "a store's delta: a region whose numbers are out of order, or on both sides of 0, counts in full" {
    var file: File = .{};
    store(&file, 1, &.{
        &.{.{ full, half, 0 }},
        &.{.{ -full, half, full }},
        &.{.{ half, full, full }},
    }, &.{.{ .regions = &.{ 0, 1, 2 }, .wide = 3, .rows = &.{ &.{ 10, 0, 0 }, &.{ 0, 10, 0 }, &.{ 0, 0, 10 } } }});
    const bytes = file.written();
    try testing.expectEqual(@as(i32, 10), deltaAt(bytes, &.{-full}, 0, 0));
    try testing.expectEqual(@as(i32, 10), deltaAt(bytes, &.{-full}, 0, 1));
    // One that starts above the default does not count below its start,
    // its start included.
    try testing.expectEqual(@as(i32, 0), deltaAt(bytes, &.{half}, 0, 2));
    try testing.expectEqual(@as(i32, 5), deltaAt(bytes, &.{12288}, 0, 2));
}

test "a store's delta is rounded to a whole unit, a half upward" {
    var file: File = .{};
    store(&file, 1, &.{&.{above}}, &.{.{ .regions = &.{0}, .wide = 1, .rows = &.{ &.{3}, &.{-3}, &.{1}, &.{-1}, &.{5} } }});
    const bytes = file.written();
    try testing.expectEqual(@as(i32, 2), deltaAt(bytes, &.{half}, 0, 0));
    try testing.expectEqual(@as(i32, -1), deltaAt(bytes, &.{half}, 0, 1));
    try testing.expectEqual(@as(i32, 1), deltaAt(bytes, &.{half}, 0, 2));
    try testing.expectEqual(@as(i32, 0), deltaAt(bytes, &.{half}, 0, 3));
    try testing.expectEqual(@as(i32, 3), deltaAt(bytes, &.{half}, 0, 4));
    // A quarter of the way: nothing lies on a half.
    try testing.expectEqual(@as(i32, 1), deltaAt(bytes, &.{4096}, 0, 0));
    try testing.expectEqual(@as(i32, -1), deltaAt(bytes, &.{4096}, 0, 1));
    try testing.expectEqual(@as(i32, 0), deltaAt(bytes, &.{4096}, 0, 2));
    try testing.expectEqual(@as(i32, 0), deltaAt(bytes, &.{4096}, 0, 3));
}

test "a store's delta: rows of bytes, of words and of long words, in each of its lists" {
    var file: File = .{};
    store(&file, 1, &.{ &.{above}, &.{below} }, &.{
        .{ .regions = &.{0}, .wide = 0, .rows = &.{ &.{-128}, &.{127} } },
        .{ .regions = &.{ 0, 1 }, .wide = 1, .rows = &.{ &.{ -30000, 100 }, &.{ 30000, -100 } } },
        .{ .regions = &.{ 1, 0 }, .wide = 1, .long_words = true, .rows = &.{ &.{ 7, 7 }, &.{ -20000, 30000 } } },
        .{ .regions = &.{0}, .wide = 0, .long_words = true, .rows = &.{&.{-30000}} },
    });
    const bytes = file.written();
    try testing.expectEqual(@as(i32, -128), deltaAt(bytes, &.{full}, 0, 0));
    try testing.expectEqual(@as(i32, 127), deltaAt(bytes, &.{full}, 0, 1));
    try testing.expectEqual(@as(i32, -30000), deltaAt(bytes, &.{full}, 1, 0));
    try testing.expectEqual(@as(i32, 100), deltaAt(bytes, &.{-full}, 1, 0));
    try testing.expectEqual(@as(i32, -100), deltaAt(bytes, &.{-full}, 1, 1));
    try testing.expectEqual(@as(i32, 30000), deltaAt(bytes, &.{full}, 2, 1));
    try testing.expectEqual(@as(i32, -20000), deltaAt(bytes, &.{-full}, 2, 1));
    try testing.expectEqual(@as(i32, -30000), deltaAt(bytes, &.{full}, 3, 0));
}

test "a store's delta is held to what a 16-bit number holds" {
    var file: File = .{};
    store(&file, 1, &.{&.{above}}, &.{
        .{ .regions = &.{ 0, 0 }, .wide = 2, .long_words = true, .rows = &.{ &.{ 2000000000, 2000000000 }, &.{ -2000000000, -2000000000 } } },
    });
    const bytes = file.written();
    try testing.expectEqual(@as(i32, 32767), deltaAt(bytes, &.{full}, 0, 0));
    try testing.expectEqual(@as(i32, -32767), deltaAt(bytes, &.{full}, 0, 1));
}

test "a store's delta: a store or a device table that is damaged adds nothing" {
    var file: File = .{};
    store(&file, 1, &.{&.{above}}, &.{
        .{ .regions = &.{ 0, 9 }, .wide = 2, .rows = &.{ &.{ 10, 50 }, &.{ 20, 50 } } },
    });
    const bytes = file.written();
    // A region the store does not have is left out; the others count.
    try testing.expectEqual(@as(i32, 10), deltaAt(bytes, &.{full}, 0, 0));
    try testing.expectEqual(@as(i32, 20), deltaAt(bytes, &.{full}, 0, 1));
    // A list and an item it does not have.
    try testing.expectEqual(@as(i32, 0), deltaAt(bytes, &.{full}, 1, 0));
    try testing.expectEqual(@as(i32, 0), deltaAt(bytes, &.{full}, 0, 2));
    // A store for another number of axes than the font's.
    try testing.expectEqual(@as(i32, 0), deltaAt(bytes, &.{ full, full }, 0, 0));
    // A row that does not lie within the table, and a table cut
    // anywhere.
    try testing.expectEqual(@as(i32, 10), deltaAt(bytes[0 .. bytes.len - 4], &.{full}, 0, 0));
    try testing.expectEqual(@as(i32, 0), deltaAt(bytes[0 .. bytes.len - 4], &.{full}, 0, 1));
    for (0..bytes.len - 4) |length| try testing.expectEqual(@as(i32, 0), deltaAt(bytes[0..length], &.{full}, 0, 0));

    // A store of a form not known.
    var other: File = .{};
    store(&other, 1, &.{&.{above}}, &.{.{ .regions = &.{0}, .wide = 1, .rows = &.{&.{10}} }});
    try testing.expectEqual(@as(i32, 10), deltaAt(other.written(), &.{full}, 0, 0));
    other.setWord(0, 2);
    try testing.expectEqual(@as(i32, 0), deltaAt(other.written(), &.{full}, 0, 0));
    other.setWord(0, 1);
    // More wide deltas than the rows have deltas at all. The list
    // starts behind the store's eight bytes, its one place and the four
    // of the regions with the six of the one region.
    const list = 8 + 4 + 4 + 6;
    other.setWord(list + 2, 2);
    try testing.expectEqual(@as(i32, 0), deltaAt(other.written(), &.{full}, 0, 0));
    other.setWord(list + 2, 1);

    // A device table for one size in pixels, and one cut short.
    var at_full: []const i16 = &.{full};
    const place = placeAt(&at_full, other.written());
    var work: u32 = 1000;
    var sized: File = .{};
    sized.word(0);
    sized.word(0);
    sized.word(0);
    for ([_]u16{ 1, 2, 3, 0, 0x8001 }) |format| {
        sized.setWord(4, format);
        try testing.expectEqual(@as(i32, 0), place.delta(.{ .bytes = sized.written() }, &work));
    }
    sized.setWord(4, 0x8000);
    try testing.expectEqual(@as(i32, 10), place.delta(.{ .bytes = sized.written() }, &work));
    try testing.expectEqual(@as(i32, 0), place.delta(.{ .bytes = sized.written()[0..5] }, &work));
    try testing.expectEqual(@as(i32, 0), place.delta(.{ .bytes = &.{} }, &work));
}

test "a store's delta: a region of a row is a piece of the table's work" {
    var file: File = .{};
    store(&file, 1, &.{&.{above}}, &.{.{ .regions = &.{ 0, 0, 0 }, .wide = 0, .rows = &.{&.{ 1, 2, 3 }} }});
    var named: File = .{};
    subtables.device(&named, 0, 0);
    var at_full: []const i16 = &.{full};
    const place = placeAt(&at_full, file.written());
    var work: u32 = 5;
    try testing.expectEqual(@as(i32, 6), place.delta(.{ .bytes = named.written() }, &work));
    try testing.expectEqual(@as(u32, 2), work);
    // With less left than the row has regions, nothing - and none left.
    try testing.expectEqual(@as(i32, 0), place.delta(.{ .bytes = named.written() }, &work));
    try testing.expectEqual(@as(u32, 0), work);
    // A font at its default spends none.
    work = 5;
    var nowhere: []const i16 = &.{};
    const default = placeAt(&nowhere, file.written());
    try testing.expectEqual(@as(i32, 0), default.delta(.{ .bytes = named.written() }, &work));
    try testing.expectEqual(@as(u32, 5), work);
}

/// The store the positionings here are varied by: one axis, a list of
/// four items. Halfway up the axis they add 50, 4 (3.5), -1 (-1.5) and
/// 25; at its lower end the first adds -40 and the others nothing.
fn weights(file: *File) []const u8 {
    store(file, 1, &.{ &.{above}, &.{below} }, &.{
        .{ .regions = &.{ 0, 1 }, .wide = 2, .rows = &.{ &.{ 100, -40 }, &.{ 7, 0 }, &.{ -3, 0 }, &.{ 50, 0 } } },
    });
    return file.written();
}

/// A `GDEF` with the store, and the kinds of `gpos.zig`'s glyphs: 5 and
/// 6 are base glyphs, 50 and 51 are marks.
fn gdefOf(file: *File, stored: *File) []const u8 {
    layout.gdef(file, .{
        .kinds = &.{
            .{ .glyph = 5, .class = 1 },
            .{ .glyph = 6, .class = 1 },
            .{ .glyph = 50, .class = 3 },
            .{ .glyph = 51, .class = 3 },
        },
        .store = weights(stored),
    });
    return file.written();
}

/// A `GPOS` of one feature with one lookup of one subtable.
fn gposOf(file: *File, kind: u16, subtable: []const u8) []const u8 {
    layout.tableOfOne(file, &.{.{ .kind = kind, .subtables = &.{subtable} }});
    return file.written();
}

fn wordAt(file: *const File, at: u32) u32 {
    return (@as(u32, file.bytes[at]) << 8) | file.bytes[at + 1];
}

test "single positioning: each number of a record is varied by its device" {
    var subtable: File = .{};
    const format = X_PLACEMENT | Y_PLACEMENT | X_ADVANCE | Y_ADVANCE |
        X_PLACEMENT_DEVICE | Y_PLACEMENT_DEVICE | X_ADVANCE_DEVICE | Y_ADVANCE_DEVICE;
    subtables.positionAll(&subtable, &.{5}, format, &.{ 10, 20, -30, 99, 0, 0, 0, 0 });
    // The record starts at 6: four numbers, then four places.
    subtables.deviceAt(&subtable, 14, 0, 0);
    subtables.deviceAt(&subtable, 16, 0, 1);
    subtables.deviceAt(&subtable, 18, 0, 2);
    subtables.deviceAt(&subtable, 20, 0, 3);
    var stored: File = .{};
    var gdef: File = .{};
    var file: File = .{};
    const tables: harness.Tables = .{ .gdef = gdefOf(&gdef, &stored), .gpos = gposOf(&file, 1, subtable.written()) };

    const default = shape(tables, &.{5}, .{});
    try default.expectAdvances(&.{970});
    try default.expectOffsets(&.{.{ 10, 20 }});
    // Each delta is rounded by itself and added. The advance down the
    // page and its device are not read.
    const bolder = shape(tables, &.{5}, .{ .coords = &.{half} });
    try bolder.expectAdvances(&.{969});
    try bolder.expectOffsets(&.{.{ 60, 24 }});
    const lightest = shape(tables, &.{5}, .{ .coords = &.{-full} });
    try lightest.expectAdvances(&.{970});
    try lightest.expectOffsets(&.{.{ -30, 20 }});
    // A font without the store is placed as at its default.
    const bare = shape(.{ .gpos = tables.gpos }, &.{5}, .{ .coords = &.{half} });
    try bare.expectAdvances(&.{970});
    try bare.expectOffsets(&.{.{ 10, 20 }});
}

test "single positioning: a device is found whatever else its record has" {
    var stored: File = .{};
    var gdef: File = .{};
    const gdef_bytes = gdefOf(&gdef, &stored);
    // A device alone.
    {
        var subtable: File = .{};
        subtables.positionAll(&subtable, &.{5}, X_ADVANCE_DEVICE, &.{0});
        subtables.deviceAt(&subtable, 6, 0, 3);
        var file: File = .{};
        const tables: harness.Tables = .{ .gdef = gdef_bytes, .gpos = gposOf(&file, 1, subtable.written()) };
        try shape(tables, &.{5}, .{}).expectAdvances(&.{1000});
        try shape(tables, &.{5}, .{ .coords = &.{half} }).expectAdvances(&.{1025});
    }
    // Behind an advance down the page, and before that one's device.
    {
        var subtable: File = .{};
        subtables.positionAll(&subtable, &.{5}, Y_ADVANCE | Y_PLACEMENT_DEVICE | Y_ADVANCE_DEVICE, &.{ 99, 0, 0 });
        subtables.deviceAt(&subtable, 8, 0, 3);
        subtables.deviceAt(&subtable, 10, 0, 0);
        var file: File = .{};
        const tables: harness.Tables = .{ .gdef = gdef_bytes, .gpos = gposOf(&file, 1, subtable.written()) };
        const run = shape(tables, &.{5}, .{ .coords = &.{half} });
        try run.expectAdvances(&.{1000});
        try run.expectOffsets(&.{.{ 0, 25 }});
    }
    // Each glyph's own record, format 2: the second glyph's.
    {
        var subtable: File = .{};
        subtables.positionEach(&subtable, &.{ 5, 6 }, X_PLACEMENT | X_PLACEMENT_DEVICE, &.{ &.{ 1, 0 }, &.{ 2, 0 } });
        // The records start at 8, four bytes each.
        subtables.deviceAt(&subtable, 14, 0, 0);
        var file: File = .{};
        const tables: harness.Tables = .{ .gdef = gdef_bytes, .gpos = gposOf(&file, 1, subtable.written()) };
        try shape(tables, &.{ 5, 6 }, .{ .coords = &.{half} }).expectOffsets(&.{ .{ 1, 0 }, .{ 52, 0 } });
    }
    // A place of 0 names no device.
    {
        var subtable: File = .{};
        subtables.positionAll(&subtable, &.{5}, X_ADVANCE | X_ADVANCE_DEVICE, &.{ -30, 0 });
        var file: File = .{};
        const tables: harness.Tables = .{ .gdef = gdef_bytes, .gpos = gposOf(&file, 1, subtable.written()) };
        try shape(tables, &.{5}, .{ .coords = &.{half} }).expectAdvances(&.{970});
    }
}

test "pair positioning, format 1: a record's devices are found from its glyph's set of pairs" {
    var subtable: File = .{};
    subtables.pairs(&subtable, &.{5}, X_ADVANCE | X_ADVANCE_DEVICE, X_PLACEMENT | X_PLACEMENT_DEVICE, &.{
        &.{.{ .second = 6, .values = &.{ -50, 0, 15, 0 } }},
    });
    // The set's count, the second glyph, then the two records.
    const set = wordAt(&subtable, 10);
    subtables.deviceAt(&subtable, set + 6, set, 3);
    subtables.deviceAt(&subtable, set + 10, set, 1);
    var stored: File = .{};
    var gdef: File = .{};
    var file: File = .{};
    const tables: harness.Tables = .{ .gdef = gdefOf(&gdef, &stored), .gpos = gposOf(&file, 2, subtable.written()) };
    const default = shape(tables, &.{ 5, 6 }, .{});
    try default.expectAdvances(&.{ 950, 1000 });
    try default.expectOffsets(&.{ .{ 0, 0 }, .{ 15, 0 } });
    const bolder = shape(tables, &.{ 5, 6 }, .{ .coords = &.{half} });
    try bolder.expectAdvances(&.{ 975, 1000 });
    try bolder.expectOffsets(&.{ .{ 0, 0 }, .{ 19, 0 } });
}

test "pair positioning, format 2: a record's devices are found from the subtable" {
    var subtable: File = .{};
    subtables.pairClasses(
        &subtable,
        &.{5},
        X_ADVANCE | X_ADVANCE_DEVICE,
        0,
        &.{.{ .glyph = 5, .class = 1 }},
        &.{.{ .glyph = 6, .class = 1 }},
        2,
        &.{ &.{ 0, 0, 0, 0 }, &.{ 0, 0, -50, 0 } },
    );
    // The records start at 16, four bytes each: the fourth is the pair's.
    subtables.deviceAt(&subtable, 16 + 3 * 4 + 2, 0, 3);
    var stored: File = .{};
    var gdef: File = .{};
    var file: File = .{};
    const tables: harness.Tables = .{ .gdef = gdefOf(&gdef, &stored), .gpos = gposOf(&file, 2, subtable.written()) };
    try shape(tables, &.{ 5, 6 }, .{}).expectAdvances(&.{ 950, 1000 });
    try shape(tables, &.{ 5, 6 }, .{ .coords = &.{half} }).expectAdvances(&.{ 975, 1000 });
    try shape(tables, &.{ 5, 6 }, .{ .coords = &.{-full} }).expectAdvances(&.{ 950, 1000 });
}

test "mark-to-base attachment: an anchor is where its devices move it to" {
    var subtable: File = .{};
    subtables.markToBase(
        &subtable,
        &.{ 50, 51 },
        &.{
            .{ .class = 0, .anchor = .{ .x = 100, .y = 0, .vary_x = 2 } },
            .{ .class = 0, .anchor = .{ .x = 100, .y = 0, .vary_y = 3 } },
        },
        &.{5},
        1,
        &.{&.{.{ .x = 300, .y = 700, .vary_x = 0, .vary_y = 1 }}},
    );
    var stored: File = .{};
    var gdef: File = .{};
    var file: File = .{};
    const tables: harness.Tables = .{ .gdef = gdefOf(&gdef, &stored), .gpos = gposOf(&file, 4, subtable.written()) };
    // A mark's offsets reach back over the advance before it.
    try shape(tables, &.{ 5, 50 }, .{}).expectOffsets(&.{ .{ 0, 0 }, .{ -800, 700 } });
    // The base's anchor at 350, 704; the mark's at 99, 0.
    try shape(tables, &.{ 5, 50 }, .{ .coords = &.{half} }).expectOffsets(&.{ .{ 0, 0 }, .{ -749, 704 } });
    // The other mark's at 100, 25.
    try shape(tables, &.{ 5, 51 }, .{ .coords = &.{half} }).expectOffsets(&.{ .{ 0, 0 }, .{ -750, 679 } });
    try shape(tables, &.{ 5, 50 }, .{ .coords = &.{-full} }).expectOffsets(&.{ .{ 0, 0 }, .{ -840, 700 } });
}

test "cursive attachment: the joints are where their devices move them to" {
    var subtable: File = .{};
    subtables.cursive(&subtable, &.{ 5, 6 }, &.{
        .{ .exit = .{ .x = 600, .y = 0, .vary_x = 0 } },
        .{ .entry = .{ .x = 50, .y = 200, .vary_y = 1 } },
    });
    var stored: File = .{};
    var gdef: File = .{};
    var file: File = .{};
    const tables: harness.Tables = .{ .gdef = gdefOf(&gdef, &stored), .gpos = gposOf(&file, 3, subtable.written()) };
    const default = shape(tables, &.{ 5, 6 }, .{});
    try default.expectAdvances(&.{ 600, 950 });
    try default.expectOffsets(&.{ .{ 0, 0 }, .{ -50, -200 } });
    const bolder = shape(tables, &.{ 5, 6 }, .{ .coords = &.{half} });
    try bolder.expectAdvances(&.{ 650, 950 });
    try bolder.expectOffsets(&.{ .{ 0, 0 }, .{ -50, -204 } });
}

test "a font made to add to one glyph without end: each sum stays at the largest number it holds" {
    // Three contexts, each applying the next a hundred times at the one
    // glyph, and the last of them a record that adds 32767 to the place
    // and takes 32768 off the advance.
    const again = [_]subtables.Record{.{ .at = 0, .lookup = 1 }} ** 100;
    const deeper = [_]subtables.Record{.{ .at = 0, .lookup = 2 }} ** 100;
    const deepest = [_]subtables.Record{.{ .at = 0, .lookup = 3 }} ** 100;
    var first: File = .{};
    subtables.context1(&first, &.{5}, &.{&.{.{ .records = &again }}});
    var second: File = .{};
    subtables.context1(&second, &.{5}, &.{&.{.{ .records = &deeper }}});
    var third: File = .{};
    subtables.context1(&third, &.{5}, &.{&.{.{ .records = &deepest }}});
    var moved: File = .{};
    subtables.positionAll(&moved, &.{5}, X_PLACEMENT | Y_PLACEMENT | X_ADVANCE, &.{ 32767, 32767, -32768 });
    var file: File = .{};
    layout.table(&file, &.{.{ .tag = "test", .lookups = &.{0} }}, &.{
        .{ .kind = 7, .subtables = &.{first.written()} },
        .{ .kind = 7, .subtables = &.{second.written()} },
        .{ .kind = 7, .subtables = &.{third.written()} },
        .{ .kind = 1, .subtables = &.{moved.written()} },
    });
    const run = shape(.{ .gpos = file.written() }, &.{5}, .{});
    try testing.expectEqual(@as(i32, 0), run.result);
    try run.expectAdvances(&.{std.math.minInt(i32)});
    try run.expectOffsets(&.{.{ std.math.maxInt(i32), std.math.maxInt(i32) }});
}

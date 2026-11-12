// SPDX-License-Identifier: MIT
//! Host tests of truetype.library's variable fonts, on tables built
//! here: the axes (`fvar`), the bend of an axis (`avar`), the glyphs'
//! deltas (`gvar`), the advances' (`HVAR`) and the measures' (`MVAR`),
//! put into a built font of squares.
//!
//! The font has two axes: `wght` from 100 over 400 to 900, and `wdth`,
//! hidden, from 50 over 100 to 200. Its glyphs are the builder's squares,
//! 500 wide and 700 tall with an advance of 600, and the last one the
//! first square twice, the second 600 to the right. What each glyph's
//! deltas do stands at `standard`.
//!
//! - The four calls: the axes, the named instances, the coordinates, the
//!   advance; and what each says of a font that is not a variable one.
//! - `TTA_Axes`: a value cut to its axis' range, what is not a number,
//!   a tag the font lacks, a tag given twice, the tag without its count.
//! - Coordinates: both sides of the default, rounded, and bent by `avar`
//!   between its pairs and outside them.
//! - A glyph's deltas: for every point, for points named by the group
//!   and by the glyph for all its groups, bytes, words, long words and
//!   runs of zeroes; a peak shared and a group's own; a group that
//!   starts away from the default; two axes at once; the points a group
//!   does not name following the named ones; a group that names none.
//! - A glyph put together: its parts' own deltas and their offsets'.
//! - The advance: by the two side points, by `HVAR` with and without a
//!   map and with a map of either form; never less than 0.
//! - The box and the bearing of a varied glyph, and its rendering.
//! - The measures `MVAR` moves, and the ones it does not.
//! - What is read at the default: a font of more than 32 axes, deltas
//!   for another number of axes; and deltas that end early.
//!
//! `standardFont` and `sidesFont` are also the variable fonts the tests
//! of changed bytes (`fuzz.zig`) and of fonts closed to writes
//! (`readonly.zig`) start from.

const std = @import("std");
const sdk = @import("sdk");
const truetype = sdk.truetype;
const utility = sdk.utility;
const vector = sdk.vector;
const builder = @import("builder.zig");
const built = @import("truetype.zig");

const testing = std.testing;
const File = builder.File;
const Rig = built.Rig;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;

// --- the tables -----------------------------------------------------------

/// One axis of a built font.
pub const Axis = struct {
    tag: *const [4]u8,
    least: f32,
    middle: f32,
    most: f32,
    hidden: bool = false,
    name: u16,
};

/// One named instance: its name's number and its value on each axis.
pub const Instance = struct {
    name: u16,
    values: []const f32,
};

/// A value as `fvar` keeps it: 16 bits of fraction.
fn fixedOf(value: f32) u32 {
    return @bitCast(@as(i32, @intFromFloat(@round(value * 65536.0))));
}

/// An `fvar` table of `axes` and `instances`.
pub fn fvar(file: *File, axes: []const Axis, instances: []const Instance) void {
    file.word(1);
    file.word(0);
    file.word(16);
    file.word(2);
    file.word(@intCast(axes.len));
    file.word(20);
    file.word(@intCast(instances.len));
    file.word(@intCast(4 + axes.len * 4));
    for (axes) |axis| {
        file.text(axis.tag);
        file.long(fixedOf(axis.least));
        file.long(fixedOf(axis.middle));
        file.long(fixedOf(axis.most));
        file.word(if (axis.hidden) 1 else 0);
        file.word(axis.name);
    }
    for (instances) |instance| {
        file.word(instance.name);
        file.word(0);
        for (instance.values) |value| file.long(fixedOf(value));
    }
}

/// An `avar` table: a map an axis, each pair where a coordinate goes,
/// in 16384ths.
fn avar(file: *File, maps: []const []const [2]i16) void {
    file.word(1);
    file.word(0);
    file.word(0);
    file.word(@intCast(maps.len));
    for (maps) |pairs| {
        file.word(@intCast(pairs.len));
        for (pairs) |pair| {
            file.signed(pair[0]);
            file.signed(pair[1]);
        }
    }
}

/// Which points a group of deltas is for.
const Named = union(enum) {
    /// The ones the glyph names for all its groups.
    shared,
    /// Every point, and the four after them.
    all,
    /// These.
    some: []const u16,
};

/// One group of a glyph's deltas.
const Group = struct {
    /// Where on the axes it counts whole: its own coordinates, or the
    /// number of one of the table's.
    peak: union(enum) { own: []const i16, shared: u16 },
    /// Where it starts and where it ends, of a group that does not start
    /// at the default.
    bounds: ?[2][]const i16 = null,
    named: Named = .all,
    /// A delta each point named, x and y.
    dx: []const i32,
    dy: []const i32,
};

/// One glyph's deltas.
const Varied = struct {
    /// The points its groups share.
    shared: ?[]const u16 = null,
    groups: []const Group = &.{},
};

/// Point numbers as a group has them: how many, then runs of steps,
/// bytes while a step fits one.
fn pointNumbers(file: *File, numbers: []const u16) void {
    if (numbers.len < 128) file.byte(@intCast(numbers.len)) else file.word(@intCast(0x8000 | numbers.len));
    var before: u16 = 0;
    var index: usize = 0;
    while (index < numbers.len) {
        const words = numbers[index] - before > 255;
        var run: usize = 0;
        var from = before;
        while (index + run < numbers.len and run < 128 and (numbers[index + run] - from > 255) == words) : (run += 1) from = numbers[index + run];
        file.byte(@intCast((run - 1) | (if (words) @as(usize, 0x80) else 0)));
        for (numbers[index..][0..run]) |number| {
            if (words) file.word(number - before) else file.byte(@intCast(number - before));
            before = number;
        }
        index += run;
    }
}

/// How a delta is kept: not at all, in a byte, a word or a long word.
fn kindOf(delta: i32) u8 {
    if (delta == 0) return 0x80;
    if (delta >= -128 and delta <= 127) return 0x00;
    if (delta >= -32768 and delta <= 32767) return 0x40;
    return 0xC0;
}

/// Deltas as a group has them: runs of one kind.
fn packedDeltas(file: *File, deltas: []const i32) void {
    var index: usize = 0;
    while (index < deltas.len) {
        const kind = kindOf(deltas[index]);
        var run: usize = 1;
        while (index + run < deltas.len and run < 64 and kindOf(deltas[index + run]) == kind) run += 1;
        file.byte(@intCast(kind | (run - 1)));
        for (deltas[index..][0..run]) |delta| switch (kind) {
            0x80 => {},
            0x00 => file.byte(@bitCast(@as(i8, @intCast(delta)))),
            0x40 => file.signed(@intCast(delta)),
            else => file.long(@bitCast(delta)),
        };
        index += run;
    }
}

/// A `gvar` table for `axes` axes: the coordinates groups share, and a
/// glyph's deltas each; the glyphs' places as long words or as words.
fn gvar(file: *File, axes: u16, peaks: []const []const i16, glyphs: []const Varied, long: bool) void {
    const header = file.len;
    file.word(1);
    file.word(0);
    file.word(axes);
    file.word(@intCast(peaks.len));
    file.long(0);
    file.word(@intCast(glyphs.len));
    file.word(if (long) 1 else 0);
    file.long(0);
    const places = file.len;
    file.skip(@intCast((glyphs.len + 1) * (if (long) @as(usize, 4) else 2)));
    file.setLong(header + 8, file.len - header);
    for (peaks) |peak| {
        for (peak) |coordinate| file.signed(coordinate);
    }
    const array = file.len;
    file.setLong(header + 16, array - header);
    for (glyphs, 0..) |glyph, index| {
        placeOf(file, places, index, file.len - array, long);
        if (glyph.groups.len == 0) continue;
        const start = file.len;
        file.word(@intCast(glyph.groups.len | (if (glyph.shared != null) @as(usize, 0x8000) else 0)));
        file.word(0);
        var sizes: [8]u32 = undefined;
        for (glyph.groups, 0..) |group, number| {
            sizes[number] = file.len;
            file.word(0);
            var which: u16 = switch (group.peak) {
                .own => 0x8000,
                .shared => |shared| shared,
            };
            if (group.bounds != null) which |= 0x4000;
            if (group.named != .shared) which |= 0x2000;
            file.word(which);
            switch (group.peak) {
                .own => |own| for (own) |coordinate| file.signed(coordinate),
                .shared => {},
            }
            if (group.bounds) |bounds| {
                for (bounds[0]) |coordinate| file.signed(coordinate);
                for (bounds[1]) |coordinate| file.signed(coordinate);
            }
        }
        file.setWord(start + 2, @intCast(file.len - start));
        if (glyph.shared) |numbers| pointNumbers(file, numbers);
        for (glyph.groups, 0..) |group, number| {
            const from = file.len;
            switch (group.named) {
                .shared => {},
                .all => file.byte(0),
                .some => |numbers| pointNumbers(file, numbers),
            }
            packedDeltas(file, group.dx);
            packedDeltas(file, group.dy);
            file.setWord(sizes[number], @intCast(file.len - from));
        }
        if ((file.len - array) % 2 != 0) file.byte(0);
    }
    placeOf(file, places, glyphs.len, file.len - array, long);
}

/// Glyph `index`'s deltas start `at` bytes into the array of them.
fn placeOf(file: *File, places: u32, index: usize, at: u32, long: bool) void {
    const glyph: u32 = @intCast(index);
    if (long) file.setLong(places + glyph * 4, at) else file.setWord(places + glyph * 2, @intCast(at / 2));
}

/// One set of rows of a store of deltas: the regions its columns are
/// for, how many of the columns are wide, and whether wide is a long
/// word and narrow a word, or a word and a byte.
pub const Rows = struct {
    regions: []const u16,
    wide: u16,
    long: bool = false,
    rows: []const []const i32,
};

/// A store of deltas for `axes` axes: its regions - where each starts,
/// counts whole and ends on each axis - and its sets of rows.
pub fn store(file: *File, axes: u16, regions: []const []const [3]i16, sets: []const Rows) void {
    const start = file.len;
    file.word(1);
    file.long(0);
    file.word(@intCast(sets.len));
    const places = file.len;
    file.skip(@intCast(sets.len * 4));
    file.setLong(start + 2, file.len - start);
    file.word(axes);
    file.word(@intCast(regions.len));
    for (regions) |region| {
        for (region) |axis| {
            for (axis) |coordinate| file.signed(coordinate);
        }
    }
    for (sets, 0..) |set, index| {
        file.setLong(places + @as(u32, @intCast(index)) * 4, file.len - start);
        file.word(@intCast(set.rows.len));
        file.word(set.wide | (if (set.long) @as(u16, 0x8000) else 0));
        file.word(@intCast(set.regions.len));
        for (set.regions) |region| file.word(region);
        for (set.rows) |row| {
            for (row, 0..) |delta, column| {
                const wide = column < set.wide;
                if (set.long and wide) {
                    file.long(@bitCast(delta));
                } else if (set.long or wide) {
                    file.signed(@intCast(delta));
                } else {
                    file.byte(@bitCast(@as(i8, @intCast(delta))));
                }
            }
        }
    }
}

/// A map from glyphs to a store's items: a set and a row each, kept in
/// `size` bytes with the row in the low `row_bits` bits; the count a
/// word, or with `long` a long word.
pub const Map = struct {
    long: bool = false,
    size: u8 = 1,
    row_bits: u8 = 4,
    entries: []const [2]u16,
};

/// An `HVAR` table of a store and, if given, a map for the advances.
pub fn hvar(file: *File, items: []const u8, map: ?Map) void {
    file.word(1);
    file.word(0);
    file.long(20);
    file.long(if (map != null) 20 + @as(u32, @intCast(items.len)) else 0);
    file.long(0);
    file.long(0);
    file.text(items);
    const m = map orelse return;
    file.byte(if (m.long) 1 else 0);
    file.byte((m.size - 1) << 4 | (m.row_bits - 1));
    if (m.long) file.long(@intCast(m.entries.len)) else file.word(@intCast(m.entries.len));
    for (m.entries) |entry| {
        const value = @as(u32, entry[0]) << @intCast(m.row_bits) | entry[1];
        var byte: u8 = m.size;
        while (byte > 0) : (byte -= 1) file.byte(@truncate(value >> @intCast((byte - 1) * 8)));
    }
}

/// One measure `MVAR` moves: its tag, and its item in the store.
const Measure = struct {
    tag: *const [4]u8,
    set: u16,
    row: u16,
};

/// An `MVAR` table of `measures` and the store their deltas are in.
fn mvar(file: *File, measures: []const Measure, items: []const u8) void {
    file.word(1);
    file.word(0);
    file.word(0);
    file.word(8);
    file.word(@intCast(measures.len));
    file.word(@intCast(12 + measures.len * 8));
    for (measures) |measure| {
        file.text(measure.tag);
        file.word(measure.set);
        file.word(measure.row);
    }
    file.text(items);
}

// --- the font --------------------------------------------------------------

const standard_axes = [_]Axis{
    .{ .tag = "wght", .least = 100, .middle = 400, .most = 900, .name = 256 },
    .{ .tag = "wdth", .least = 50, .middle = 100, .most = 200, .hidden = true, .name = 257 },
};

const standard_instances = [_]Instance{
    .{ .name = 258, .values = &.{ 400, 100 } },
    .{ .name = 259, .values = &.{ 700, 100 } },
    .{ .name = 260, .values = &.{ 900, 200 } },
};

/// The coordinates the font's groups share: the most weight, the most
/// width.
const standard_peaks = [_][]const i16{ &.{ 16384, 0 }, &.{ 0, 16384 } };

/// The font's deltas, a glyph each. A square's points are 0 at the
/// origin, 1 above it, 2 the top right, 3 the bottom right; 4 is its
/// left side, 5 its right.
const standard = [_]Varied{
    // 0: the empty glyph has none.
    .{},
    // 1: with weight the right edge goes 100 out, the top 40 up, and
    //    the advance grows by 50.
    .{ .groups = &.{.{
        .peak = .{ .shared = 0 },
        .dx = &.{ 0, 0, 100, 100, 0, 50, 0, 0 },
        .dy = &.{ 0, 40, 40, 0, 0, 0, 0, 0 },
    }} },
    // 2: past half of both axes every point goes up to 10 right; with
    //    width the top right corner goes out and up, the origin stays,
    //    and the two corners not named follow them.
    .{ .groups = &.{
        .{
            .peak = .{ .own = &.{ 16384, 16384 } },
            .bounds = .{ &.{ 8192, 8192 }, &.{ 16384, 16384 } },
            .dx = &.{ 10, 10, 10, 10, 0, 0, 0, 0 },
            .dy = &.{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
        .{
            .peak = .{ .shared = 1 },
            .named = .{ .some = &.{ 0, 2 } },
            .dx = &.{ 0, 100 },
            .dy = &.{ 0, 70 },
        },
    } },
    // 3: both groups are for the points the glyph names, the corner
    //    above the origin and the right side: with weight the corner,
    //    and the contour with it, goes 20 left and the advance grows by
    //    30; with width it goes 10 up and the advance grows by 100.
    .{ .shared = &.{ 1, 5 }, .groups = &.{
        .{ .peak = .{ .shared = 0 }, .named = .shared, .dx = &.{ -20, 30 }, .dy = &.{ 0, 0 } },
        .{ .peak = .{ .shared = 1 }, .named = .shared, .dx = &.{ 0, 100 }, .dy = &.{ 10, 0 } },
    } },
    // 4: with less weight the right edge comes 300 in and the advance
    //    shrinks by 200; with less width the advance grows by 40000.
    .{ .groups = &.{
        .{
            .peak = .{ .own = &.{ -16384, 0 } },
            .dx = &.{ 0, 0, -300, -300, 0, -200, 0, 0 },
            .dy = &.{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
        .{
            .peak = .{ .own = &.{ 0, -16384 } },
            .dx = &.{ 0, 0, 0, 0, 0, 40000, 0, 0 },
            .dy = &.{ 0, 0, 0, 0, 0, 0, 0, 0 },
        },
    } },
    // 5: glyph 1 twice. With weight the second goes 200 further right
    //    and the advance grows by 300. Its points are its two parts,
    //    then the sides.
    .{ .groups = &.{.{
        .peak = .{ .shared = 0 },
        .dx = &.{ 0, 200, 0, 300, 0, 0 },
        .dy = &.{ 0, 0, 0, 0, 0, 0 },
    }} },
};

/// The regions of the advances' store: more weight, more width, less
/// weight, and past half of both.
const advance_regions = [_][]const [3]i16{
    &.{ .{ 0, 16384, 16384 }, .{ 0, 0, 0 } },
    &.{ .{ 0, 0, 0 }, .{ 0, 16384, 16384 } },
    &.{ .{ -16384, -16384, 0 }, .{ 0, 0, 0 } },
    &.{ .{ 8192, 16384, 16384 }, .{ 8192, 16384, 16384 } },
};

/// Its rows: a glyph each for more weight, more width and less weight;
/// and two for more weight and past half of both, kept wider.
const advance_sets = [_]Rows{
    .{ .regions = &.{ 0, 1, 2 }, .wide = 1, .rows = &.{
        &.{ 0, 0, 0 },
        &.{ 51, 20, -30 },
        &.{ 300, -100, 5 },
        &.{ -700, 0, 0 },
        &.{ 0, 0, 0 },
        &.{ 1000, 100, -100 },
    } },
    .{ .regions = &.{ 0, 3 }, .wide = 1, .long = true, .rows = &.{
        &.{ 100000, 7 },
        &.{ -2, 0 },
    } },
};

/// Which row each glyph's advance has: the last two glyphs have the
/// last entry's.
const advance_entries = [_][2]u16{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 2 }, .{ 1, 1 } };

/// How a built font's advances vary.
const Advances = enum {
    /// By the glyphs' side points: no `HVAR`.
    sides,
    /// By `HVAR`, a row a glyph.
    rows,
    /// By `HVAR` and its map, the count a word and an entry a byte.
    map,
    /// The same, the count a long word and an entry two bytes.
    long_map,
    /// By a map that names rows the store does not have.
    lost,
};

/// What a built variable font is made of beside its axes and deltas.
const Make = struct {
    advances: Advances = .sides,
    /// Whether `avar` bends the axes: weight's upper half so that half
    /// way is a quarter, and width's so that half way is three quarters,
    /// with nothing said past that.
    bend: bool = false,
    /// Whether it has the measures of `OS/2` and `post`, and `MVAR`.
    measures: bool = false,
    /// How many axes `gvar` says it is for.
    delta_axes: u16 = 2,
    /// The character of glyph 1; the four after it are glyphs 2 to 5.
    first: u16 = 'A',
    /// Whether `gvar` places its glyphs by long words.
    long: bool = true,
    axes: []const Axis = &standard_axes,
    instances: []const Instance = &standard_instances,
    peaks: []const []const i16 = &standard_peaks,
    deltas: []const Varied = &standard,
};

/// A variable font of six glyphs - 'A' to 'E' are glyphs 1 to 5 - with
/// the deltas of `standard`.
fn fontOf(file: *File, make: Make) void {
    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    cmap.segments(&.{
        .{ .first = make.first, .last = make.first + 4, .delta = @bitCast(@as(i16, 1) - @as(i16, @intCast(make.first))) },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });

    var more: [8]builder.Table = undefined;
    var count: usize = 0;

    var axes: File = .{};
    fvar(&axes, make.axes, make.instances);
    more[count] = .{ .tag = "fvar", .bytes = axes.written() };
    count += 1;

    var deltas: File = .{};
    gvar(&deltas, make.delta_axes, make.peaks, make.deltas, make.long);
    more[count] = .{ .tag = "gvar", .bytes = deltas.written() };
    count += 1;

    var bend: File = .{};
    if (make.bend) {
        avar(&bend, &.{
            &.{ .{ -16384, -16384 }, .{ 0, 0 }, .{ 8192, 4096 }, .{ 16384, 16384 } },
            &.{ .{ 0, 0 }, .{ 8192, 12288 } },
        });
        more[count] = .{ .tag = "avar", .bytes = bend.written() };
        count += 1;
    }

    var items: File = .{};
    var advances: File = .{};
    if (make.advances != .sides) {
        store(&items, 2, &advance_regions, &advance_sets);
        hvar(&advances, items.written(), switch (make.advances) {
            .sides, .rows => null,
            .map => .{ .entries = &advance_entries },
            .long_map => .{ .long = true, .size = 2, .row_bits = 8, .entries = &advance_entries },
            .lost => .{ .entries = &.{.{ 9, 9 }} },
        });
        more[count] = .{ .tag = "HVAR", .bytes = advances.written() };
        count += 1;
    }

    var moved: File = .{};
    var measures: File = .{};
    var os2: File = .{};
    var post: File = .{};
    if (make.measures) {
        os2.word(2);
        os2.skip(94);
        os2.setWord(26, 50);
        os2.setWord(28, 250);
        os2.setWord(86, 480);
        os2.setWord(88, 700);
        post.skip(32);
        post.setWord(8, @bitCast(@as(i16, -100)));
        post.setWord(10, 40);
        // With weight; `hasc` is a measure the library does not move.
        store(&moved, 2, &.{&.{ .{ 0, 16384, 16384 }, .{ 0, 0, 0 } }}, &.{.{ .regions = &.{0}, .wide = 1, .rows = &.{
            &.{20}, &.{-31}, &.{-9}, &.{5}, &.{11}, &.{3}, &.{500},
        } }});
        mvar(&measures, &.{
            .{ .tag = "xhgt", .set = 0, .row = 0 },
            .{ .tag = "cpht", .set = 0, .row = 1 },
            .{ .tag = "undo", .set = 0, .row = 2 },
            .{ .tag = "unds", .set = 0, .row = 3 },
            .{ .tag = "stro", .set = 0, .row = 4 },
            .{ .tag = "strs", .set = 0, .row = 5 },
            .{ .tag = "hasc", .set = 0, .row = 6 },
        }, moved.written());
        more[count] = .{ .tag = "MVAR", .bytes = measures.written() };
        more[count + 1] = .{ .tag = "OS/2", .bytes = os2.written() };
        more[count + 2] = .{ .tag = "post", .bytes = post.written() };
        count += 3;
    }

    _ = builder.font(file, .{ .cmap = cmap.written(), .glyphs = 6, .composite = true, .more = more[0..count] });
}

/// The font with everything a variable font may have: bent axes, a map
/// of advances, and measures that move.
pub fn standardFont(file: *File) void {
    fontOf(file, .{ .advances = .map, .bend = true, .measures = true });
}

/// The font whose advances are its glyphs' sides', the glyphs' deltas
/// placed by words.
pub fn sidesFont(file: *File) void {
    fontOf(file, .{ .long = false });
}

/// The plain variable font with `first` and the four characters after
/// it as its glyphs 1 to 5, and no measures.
pub fn letteredFont(file: *File, first: u16) void {
    fontOf(file, .{ .first = first });
}

/// Where the table `tag` of a built font starts in its file.
pub fn tableAt(file: *const File, tag: *const [4]u8) u32 {
    const tables = std.mem.readInt(u16, file.bytes[4..6], .big);
    for (0..tables) |index| {
        const record = 12 + index * 16;
        if (std.mem.eql(u8, file.bytes[record..][0..4], tag)) return std.mem.readInt(u32, file.bytes[record + 8 ..][0..4], .big);
    }
    unreachable;
}

// --- what is asked ---------------------------------------------------------

const wght = truetype.tableTag("wght");
const wdth = truetype.tableTag("wdth");

/// A place on the font's two axes.
fn place(weight: f32, width: f32) [2]truetype.AxisValue {
    return .{ .{ .tag = wght, .value = weight }, .{ .tag = wdth, .value = width } };
}

/// The font of `file` opened at `values`.
pub fn openAt(tb: *TrueTypeBase, file: *const File, values: []const truetype.AxisValue) !*truetype.Outline {
    const tags = [_]utility.TagItem{
        .{ .tag = truetype.TTA_Axes, .data = @intFromPtr(values.ptr) },
        .{ .tag = truetype.TTA_AxisCount, .data = values.len },
        .{ .tag = utility.TAG_DONE, .data = 0 },
    };
    return tb.OpenOutline(&file.bytes, file.len, &tags) orelse error.NoOutline;
}

/// The outline's coordinates on its two axes.
fn coordinatesOf(tb: *TrueTypeBase, outline: *truetype.Outline) ![2]i16 {
    var coords = [2]i16{ 77, 77 };
    try testing.expectEqual(@as(u32, 2), tb.FontCoordinates(outline, &coords, 2));
    return coords;
}

/// The glyph's outline is one closed contour of these four corners, in
/// the square's order.
fn expectCorners(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, corners: [4][2]f32) !void {
    var verbs: [16]u8 = undefined;
    var points: [16]vector.Point = undefined;
    var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 16, .point_room = 16 };
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, glyph, &segments));
    try testing.expectEqualSlices(u8, &.{ vector.SEG_MOVE, vector.SEG_LINE, vector.SEG_LINE, vector.SEG_LINE, vector.SEG_CLOSE }, verbs[0..segments.verb_count]);
    for (corners, points[0..4]) |corner, point| {
        try testing.expectEqual(corner[0], point.x);
        try testing.expectEqual(corner[1], point.y);
    }
}

/// The square from the origin to (`right`, `top`).
fn squareTo(right: f32, top: f32) [4][2]f32 {
    return .{ .{ 0, 0 }, .{ 0, top }, .{ right, top }, .{ right, 0 } };
}

/// The glyph's measures.
fn metricsOf(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32) !truetype.GlyphMetrics {
    var metrics: truetype.GlyphMetrics = .{};
    try testing.expect(tb.GlyphMetrics(outline, glyph, &metrics));
    return metrics;
}

// --- the calls -------------------------------------------------------------

test "variable: a font's axes and named instances, and none of a font without" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var file: File = .{};
    fontOf(&file, .{});
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;

    const untouched = truetype.Axis{ .tag = 1, .minimum = 2, .default = 3, .maximum = 4, .value = 5, .name = 6, .hidden = true };
    var axes: [3]truetype.Axis = @splat(untouched);
    try testing.expectEqual(@as(u32, 2), tb.FontAxes(outline, null, 0));
    try testing.expectEqual(@as(u32, 2), tb.FontAxes(outline, &axes, 3));
    try testing.expectEqual(truetype.Axis{ .tag = wght, .minimum = 100, .default = 400, .maximum = 900, .value = 400, .name = 256, .hidden = false }, axes[0]);
    try testing.expectEqual(truetype.Axis{ .tag = wdth, .minimum = 50, .default = 100, .maximum = 200, .value = 100, .name = 257, .hidden = true }, axes[1]);
    try testing.expectEqual(untouched, axes[2]);
    // With room for one, one is written, and both are counted.
    axes = @splat(untouched);
    try testing.expectEqual(@as(u32, 2), tb.FontAxes(outline, &axes, 1));
    try testing.expectEqual(wght, axes[0].tag);
    try testing.expectEqual(untouched, axes[1]);

    // The instances, in the table's order, in the form TTA_Axes takes.
    const none = truetype.AxisValue{ .tag = 9, .value = 9 };
    var values: [3]truetype.AxisValue = @splat(none);
    try testing.expectEqual(@as(u32, 258), tb.FontInstance(outline, 0, &values, 3));
    try testing.expectEqual(place(400, 100), values[0..2].*);
    try testing.expectEqual(none, values[2]);
    try testing.expectEqual(@as(u32, 259), tb.FontInstance(outline, 1, &values, 3));
    try testing.expectEqual(place(700, 100), values[0..2].*);
    values = @splat(none);
    try testing.expectEqual(@as(u32, 260), tb.FontInstance(outline, 2, &values, 1));
    try testing.expectEqual(truetype.AxisValue{ .tag = wght, .value = 900 }, values[0]);
    try testing.expectEqual(none, values[1]);
    try testing.expectEqual(@as(u32, 260), tb.FontInstance(outline, 2, null, 0));
    // No fourth: nothing is written.
    values = @splat(none);
    try testing.expectEqual(@as(u32, 0), tb.FontInstance(outline, 3, &values, 3));
    try testing.expectEqual(none, values[0]);
    try testing.expectEqual(@as(u32, 0), tb.FontInstance(outline, 0xFFFF_FFFF, &values, 3));

    // At the default every coordinate is 0.
    try testing.expectEqual([2]i16{ 0, 0 }, try coordinatesOf(tb, outline));
    var one = [2]i16{ 77, 77 };
    try testing.expectEqual(@as(u32, 2), tb.FontCoordinates(outline, &one, 1));
    try testing.expectEqual([2]i16{ 0, 77 }, one);
    try testing.expectEqual(@as(u32, 2), tb.FontCoordinates(outline, null, 0));
    tb.CloseOutline(outline);

    // An opened instance is one every outline of the font lists alike.
    const heavy = try openAt(tb, &file, &place(700, 100));
    try testing.expectEqual(@as(u32, 259), tb.FontInstance(heavy, 1, &values, 3));
    try testing.expectEqual(place(700, 100), values[0..2].*);
    try testing.expectEqual(@as(u32, 2), tb.FontAxes(heavy, &axes, 3));
    try testing.expectEqual(@as(f32, 700), axes[0].value);
    try testing.expectEqual(@as(f32, 400), axes[0].default);
    try testing.expectEqual(@as(f32, 100), axes[1].value);
    tb.CloseOutline(heavy);

    // A font that is not a variable one has none of it, and its glyphs'
    // advances as ever.
    var plain: File = .{};
    builder.whole(&plain);
    const fixed = try openAt(tb, &plain, &place(900, 200));
    try testing.expectEqual(@as(u32, 0), tb.FontAxes(fixed, &axes, 3));
    try testing.expectEqual(@as(u32, 0), tb.FontInstance(fixed, 0, &values, 3));
    try testing.expectEqual(@as(u32, 0), tb.FontCoordinates(fixed, &one, 2));
    try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(fixed, 1));
    try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(fixed, 11));
    try testing.expectEqual(@as(i32, 0), tb.GlyphAdvance(fixed, 12));
    try testing.expectEqual(@as(i32, 0), tb.GlyphAdvance(fixed, 0xFFFF_FFFF));
    try expectCorners(tb, fixed, 1, squareTo(500, 700));
    tb.CloseOutline(fixed);

    try rig.down();
}

test "variable: a value is cut to its axis, and the first of a tag counts" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var file: File = .{};
    fontOf(&file, .{});
    const Case = struct { values: []const truetype.AxisValue, weight: f32, width: f32, coords: [2]i16 };
    const slnt = truetype.tableTag("slnt");
    const cases = [_]Case{
        // Both ends, and past them.
        .{ .values = &place(900, 200), .weight = 900, .width = 200, .coords = .{ 16384, 16384 } },
        .{ .values = &place(100, 50), .weight = 100, .width = 50, .coords = .{ -16384, -16384 } },
        .{ .values = &place(2000, 1e30), .weight = 900, .width = 200, .coords = .{ 16384, 16384 } },
        .{ .values = &place(-5, -1e30), .weight = 100, .width = 50, .coords = .{ -16384, -16384 } },
        .{ .values = &place(std.math.inf(f32), -std.math.inf(f32)), .weight = 900, .width = 50, .coords = .{ 16384, -16384 } },
        // What is not a number reads as the axis' least.
        .{ .values = &place(std.math.nan(f32), 100), .weight = 100, .width = 100, .coords = .{ -16384, 0 } },
        // Each side of the default is counted by its own length.
        .{ .values = &place(650, 150), .weight = 650, .width = 150, .coords = .{ 8192, 8192 } },
        .{ .values = &place(250, 75), .weight = 250, .width = 75, .coords = .{ -8192, -8192 } },
        // Rounded to the nearest 16384th: 0.1 is 1638.4, 0.7 is 11468.8.
        .{ .values = &place(450, 170), .weight = 450, .width = 170, .coords = .{ 1638, 11469 } },
        .{ .values = &place(370, 65), .weight = 370, .width = 65, .coords = .{ -1638, -11469 } },
        // An axis not named stays at its default, in any order.
        .{ .values = &.{.{ .tag = wdth, .value = 200 }}, .weight = 400, .width = 200, .coords = .{ 0, 16384 } },
        .{ .values = &.{ .{ .tag = wdth, .value = 150 }, .{ .tag = wght, .value = 900 } }, .weight = 900, .width = 150, .coords = .{ 16384, 8192 } },
        // A tag the font lacks is passed over; of two the first counts.
        .{ .values = &.{ .{ .tag = slnt, .value = 5 }, .{ .tag = wght, .value = 900 } }, .weight = 900, .width = 100, .coords = .{ 16384, 0 } },
        .{ .values = &.{ .{ .tag = wght, .value = 900 }, .{ .tag = wght, .value = 100 } }, .weight = 900, .width = 100, .coords = .{ 16384, 0 } },
        .{ .values = &.{}, .weight = 400, .width = 100, .coords = .{ 0, 0 } },
    };
    for (cases) |case| {
        const outline = try openAt(tb, &file, case.values);
        var axes: [2]truetype.Axis = undefined;
        try testing.expectEqual(@as(u32, 2), tb.FontAxes(outline, &axes, 2));
        try testing.expectEqual(case.weight, axes[0].value);
        try testing.expectEqual(case.width, axes[1].value);
        try testing.expectEqual(case.coords, try coordinatesOf(tb, outline));
        tb.CloseOutline(outline);
    }

    // The values without their count, and the count without the values,
    // are no values.
    const heavy = place(900, 200);
    const only_values = [_]utility.TagItem{ .{ .tag = truetype.TTA_Axes, .data = @intFromPtr(&heavy) }, .{} };
    const only_count = [_]utility.TagItem{ .{ .tag = truetype.TTA_AxisCount, .data = 2 }, .{} };
    for ([_][*]const utility.TagItem{ &only_values, &only_count }) |tags| {
        const outline = tb.OpenOutline(&file.bytes, file.len, tags) orelse return error.NoOutline;
        try testing.expectEqual([2]i16{ 0, 0 }, try coordinatesOf(tb, outline));
        try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, 1));
        tb.CloseOutline(outline);
    }

    try rig.down();
}

test "variable: avar bends an axis between its pairs and keeps the distance outside them" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var file: File = .{};
    fontOf(&file, .{ .bend = true });
    const Case = struct { weight: f32, width: f32, coords: [2]i16 };
    const cases = [_]Case{
        .{ .weight = 400, .width = 100, .coords = .{ 0, 0 } },
        // Weight: a pair's own value, and between two pairs.
        .{ .weight = 650, .width = 100, .coords = .{ 4096, 0 } },
        .{ .weight = 525, .width = 100, .coords = .{ 2048, 0 } },
        .{ .weight = 775, .width = 100, .coords = .{ 10240, 0 } },
        .{ .weight = 900, .width = 100, .coords = .{ 16384, 0 } },
        .{ .weight = 250, .width = 100, .coords = .{ -8192, 0 } },
        .{ .weight = 100, .width = 100, .coords = .{ -16384, 0 } },
        // Width: half way goes to three quarters; past the last pair a
        // value stays a quarter further, and is cut at the end.
        .{ .weight = 400, .width = 125, .coords = .{ 0, 6144 } },
        .{ .weight = 400, .width = 150, .coords = .{ 0, 12288 } },
        .{ .weight = 400, .width = 160, .coords = .{ 0, 13926 } },
        .{ .weight = 400, .width = 175, .coords = .{ 0, 16384 } },
        .{ .weight = 400, .width = 200, .coords = .{ 0, 16384 } },
        // Before the first pair it keeps its distance from that one.
        .{ .weight = 400, .width = 75, .coords = .{ 0, -8192 } },
    };
    for (cases) |case| {
        const outline = try openAt(tb, &file, &place(case.weight, case.width));
        try testing.expectEqual(case.coords, try coordinatesOf(tb, outline));
        tb.CloseOutline(outline);
    }
    // The glyphs are at the bent place: half the weight's way is a
    // quarter of its deltas.
    const outline = try openAt(tb, &file, &place(650, 100));
    try expectCorners(tb, outline, 1, squareTo(525, 710));
    try testing.expectEqual(@as(i32, 613), tb.GlyphAdvance(outline, 1));
    tb.CloseOutline(outline);

    try rig.down();
}

// --- the glyphs ------------------------------------------------------------

/// The square moved by (`dx`, `dy`).
fn squareAt(dx: f32, dy: f32) [4][2]f32 {
    return .{ .{ dx, dy }, .{ dx, 700 + dy }, .{ 500 + dx, 700 + dy }, .{ 500 + dx, dy } };
}

test "variable: a glyph's points and advance are moved by its deltas, as far as the place is along the axis" {
    var rig = try Rig.up();
    const tb = rig.tb;

    // The glyphs' places in the table as long words, and as words.
    for ([_]bool{ true, false }) |long| {
        var file: File = .{};
        fontOf(&file, .{ .long = long });

        // The most weight: glyph 1's deltas whole. Glyph 3's one named
        // corner takes its contour along. Glyphs 2 and 4 vary with
        // width and with less weight, not with this.
        var outline = try openAt(tb, &file, &place(900, 100));
        try expectCorners(tb, outline, 1, squareTo(600, 740));
        try testing.expectEqual(@as(i32, 650), tb.GlyphAdvance(outline, 1));
        try expectCorners(tb, outline, 2, squareTo(500, 700));
        try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, 2));
        try expectCorners(tb, outline, 3, squareAt(-20, 0));
        try testing.expectEqual(@as(i32, 630), tb.GlyphAdvance(outline, 3));
        try expectCorners(tb, outline, 4, squareTo(500, 700));
        try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, 4));
        // The glyph without an outline has none here either.
        var verbs: [4]u8 = undefined;
        var points: [4]vector.Point = undefined;
        var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 4, .point_room = 4 };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 0, &segments));
        try testing.expectEqual(@as(u32, 0), segments.verb_count);
        try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, 0));
        try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.GlyphSegments(outline, 6, &segments));
        try testing.expectEqual(@as(i32, 0), tb.GlyphAdvance(outline, 6));
        tb.CloseOutline(outline);

        // Half way: half of them.
        outline = try openAt(tb, &file, &place(650, 100));
        try expectCorners(tb, outline, 1, squareTo(550, 720));
        try testing.expectEqual(@as(i32, 625), tb.GlyphAdvance(outline, 1));
        try expectCorners(tb, outline, 3, squareAt(-10, 0));
        try testing.expectEqual(@as(i32, 615), tb.GlyphAdvance(outline, 3));
        tb.CloseOutline(outline);

        // A tenth of the way is 1638 of 16384: a point keeps the part
        // of a unit that gives, an advance is rounded.
        outline = try openAt(tb, &file, &place(450, 100));
        const part: f64 = 1638.0 / 16384.0;
        try expectCorners(tb, outline, 1, squareTo(@floatCast(500.0 + 100.0 * part), @floatCast(700.0 + 40.0 * part)));
        try testing.expectEqual(@as(i32, 605), tb.GlyphAdvance(outline, 1));
        tb.CloseOutline(outline);

        // Less weight: glyph 4's, kept as words. Glyph 1 has none there.
        outline = try openAt(tb, &file, &place(100, 100));
        try expectCorners(tb, outline, 4, squareTo(200, 700));
        try testing.expectEqual(@as(i32, 400), tb.GlyphAdvance(outline, 4));
        try expectCorners(tb, outline, 1, squareTo(500, 700));
        try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, 1));
        tb.CloseOutline(outline);
        outline = try openAt(tb, &file, &place(250, 100));
        try expectCorners(tb, outline, 4, squareTo(350, 700));
        try testing.expectEqual(@as(i32, 500), tb.GlyphAdvance(outline, 4));
        tb.CloseOutline(outline);

        // Less width: glyph 4's advance, kept as a long word.
        outline = try openAt(tb, &file, &place(400, 50));
        try expectCorners(tb, outline, 4, squareTo(500, 700));
        try testing.expectEqual(@as(i32, 40600), tb.GlyphAdvance(outline, 4));
        tb.CloseOutline(outline);

        // More width. Glyph 2 names its origin, which stays, and its
        // top right corner, which goes out and up: the corner above the
        // origin follows the one in y and the other in x, the bottom
        // right the other way round.
        outline = try openAt(tb, &file, &place(400, 200));
        try expectCorners(tb, outline, 2, squareTo(600, 770));
        try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, 2));
        try expectCorners(tb, outline, 3, squareAt(0, 10));
        try testing.expectEqual(@as(i32, 700), tb.GlyphAdvance(outline, 3));
        tb.CloseOutline(outline);
        outline = try openAt(tb, &file, &place(400, 150));
        try expectCorners(tb, outline, 2, squareTo(550, 735));
        try expectCorners(tb, outline, 3, squareAt(0, 5));
        try testing.expectEqual(@as(i32, 650), tb.GlyphAdvance(outline, 3));
        tb.CloseOutline(outline);
    }

    try rig.down();
}

test "variable: groups count by both axes, and one that starts away from the default counts from there" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var file: File = .{};
    fontOf(&file, .{});

    // Three quarters along both. Glyph 2's first group starts half way
    // on each axis: it is half way along on each, a quarter in all. Its
    // second counts three quarters. Glyph 3's two groups are added.
    var outline = try openAt(tb, &file, &place(775, 175));
    try testing.expectEqual([2]i16{ 12288, 12288 }, try coordinatesOf(tb, outline));
    try expectCorners(tb, outline, 2, .{ .{ 2.5, 0 }, .{ 2.5, 752.5 }, .{ 577.5, 752.5 }, .{ 577.5, 0 } });
    try expectCorners(tb, outline, 3, squareAt(-15, 7.5));
    try testing.expectEqual(@as(i32, 698), tb.GlyphAdvance(outline, 3));
    try expectCorners(tb, outline, 1, squareTo(575, 730));
    try testing.expectEqual(@as(i32, 638), tb.GlyphAdvance(outline, 1));
    tb.CloseOutline(outline);

    // The most of both: every group whole.
    outline = try openAt(tb, &file, &place(900, 200));
    try expectCorners(tb, outline, 2, .{ .{ 10, 0 }, .{ 10, 770 }, .{ 610, 770 }, .{ 610, 0 } });
    try expectCorners(tb, outline, 3, squareAt(-20, 10));
    try testing.expectEqual(@as(i32, 730), tb.GlyphAdvance(outline, 3));
    tb.CloseOutline(outline);

    // Where the first group starts on one axis it counts nothing,
    // however far the other is.
    outline = try openAt(tb, &file, &place(650, 200));
    try expectCorners(tb, outline, 2, squareTo(600, 770));
    tb.CloseOutline(outline);
    outline = try openAt(tb, &file, &place(900, 100));
    try expectCorners(tb, outline, 2, squareTo(500, 700));
    tb.CloseOutline(outline);

    try rig.down();
}

test "variable: a glyph put together has its parts' deltas and its own for where they stand" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var file: File = .{};
    fontOf(&file, .{});
    const Case = struct { weight: f32, right: f32, top: f32, second: f32, advance: i32 };
    const cases = [_]Case{
        .{ .weight = 400, .right = 500, .top = 700, .second = 600, .advance = 600 },
        .{ .weight = 650, .right = 550, .top = 720, .second = 700, .advance = 750 },
        .{ .weight = 900, .right = 600, .top = 740, .second = 800, .advance = 900 },
        // Its parts' glyph does not vary with less weight, nor does it.
        .{ .weight = 100, .right = 500, .top = 700, .second = 600, .advance = 600 },
    };
    for (cases) |case| {
        const outline = try openAt(tb, &file, &place(case.weight, 100));
        var verbs: [16]u8 = undefined;
        var points: [16]vector.Point = undefined;
        var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 16, .point_room = 16 };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, 5, &segments));
        try testing.expectEqual(@as(u32, 10), segments.verb_count);
        try testing.expectEqual(@as(u32, 8), segments.point_count);
        const first = squareTo(case.right, case.top);
        for (first, points[0..4], points[4..8]) |corner, one, other| {
            try testing.expectEqual(vector.Point{ .x = corner[0], .y = corner[1] }, one);
            try testing.expectEqual(vector.Point{ .x = corner[0] + case.second, .y = corner[1] }, other);
        }
        try testing.expectEqual(case.advance, tb.GlyphAdvance(outline, 5));
        // Its box holds both, and it starts at its origin.
        try testing.expectEqual(truetype.GlyphMetrics{
            .advance = case.advance,
            .x_max = @intFromFloat(case.second + case.right),
            .y_max = @intFromFloat(case.top),
        }, try metricsOf(tb, outline, 5));
        tb.CloseOutline(outline);
    }

    try rig.down();
}

test "variable: points named in bytes and in words, and a group that names none" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var file: File = .{};
    fontOf(&file, .{
        .deltas = &.{
            .{},
            // Not its own points, and the glyph shares none: it moves nothing.
            .{ .groups = &.{.{ .peak = .{ .shared = 0 }, .named = .shared, .dx = &.{ 50, 50, 50, 50, 0, 50, 0, 0 }, .dy = &.{ 0, 0, 0, 0, 0, 0, 0, 0 } }} },
            // A step too long for a byte, to a point the glyph does not
            // have: that one is passed over, its delta with it.
            .{ .groups = &.{.{ .peak = .{ .shared = 0 }, .named = .{ .some = &.{ 1, 300 } }, .dx = &.{ 30, 99 }, .dy = &.{ 0, 99 } }} },
            // Every point named, one by one: the same as naming none.
            .{ .groups = &.{.{ .peak = .{ .shared = 0 }, .named = .{ .some = &.{ 0, 1, 2, 3, 4, 5, 6, 7 } }, .dx = &.{ 0, 0, 100, 100, 0, 50, 0, 0 }, .dy = &.{ 0, 40, 40, 0, 0, 0, 0, 0 } }} },
            // A contour without a named point stays: only the side is.
            .{ .groups = &.{.{ .peak = .{ .shared = 0 }, .named = .{ .some = &.{5} }, .dx = &.{-70}, .dy = &.{0} }} },
            .{},
        },
    });
    const outline = try openAt(tb, &file, &place(900, 100));
    try expectCorners(tb, outline, 1, squareTo(500, 700));
    try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, 1));
    try expectCorners(tb, outline, 2, squareAt(30, 0));
    try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, 2));
    try expectCorners(tb, outline, 3, squareTo(600, 740));
    try testing.expectEqual(@as(i32, 650), tb.GlyphAdvance(outline, 3));
    try expectCorners(tb, outline, 4, squareTo(500, 700));
    try testing.expectEqual(@as(i32, 530), tb.GlyphAdvance(outline, 4));
    // The glyph put together has no deltas of its own: its parts' only.
    try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, 5));
    tb.CloseOutline(outline);

    try rig.down();
}

// --- the measures ----------------------------------------------------------

test "variable: a glyph's box and bearing are its moved points', to whole units outward" {
    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;
    // A library nobody has open goes when memory runs out, and its
    // memory would count as given back.
    rig.withoutPacker();

    var file: File = .{};
    fontOf(&file, .{});

    var outline = try openAt(tb, &file, &place(900, 100));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 650, .x_max = 600, .y_max = 740 }, try metricsOf(tb, outline, 1));
    // The contour went left and the origin stayed: the glyph reaches
    // back over it.
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 630, .left_bearing = -20, .x_min = -20, .x_max = 480, .y_max = 700 }, try metricsOf(tb, outline, 3));
    // No outline: an advance and no box.
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600 }, try metricsOf(tb, outline, 0));
    var metrics = truetype.GlyphMetrics{ .advance = 1, .left_bearing = 2, .x_min = 3, .y_min = 4, .x_max = 5, .y_max = 6 };
    try testing.expect(!tb.GlyphMetrics(outline, 6, &metrics));
    try testing.expectEqual(truetype.GlyphMetrics{}, metrics);

    // The box is read with memory. Without it nothing is said of the
    // glyph; its advance is still there to ask for.
    var taken: [64]struct { block: *anyopaque, size: usize } = undefined;
    var taken_count: usize = 0;
    while (taken_count < taken.len) {
        const largest = sys.AvailMem(sdk.exec.MEMF_ANY | sdk.exec.MEMF_LARGEST);
        if (largest == 0) break;
        const block = sys.AllocMem(largest, sdk.exec.MEMF_ANY) orelse break;
        taken[taken_count] = .{ .block = block, .size = largest };
        taken_count += 1;
    }
    try testing.expectEqual(@as(usize, 0), sys.AvailMem(sdk.exec.MEMF_ANY | sdk.exec.MEMF_LARGEST));
    metrics = .{ .advance = 1, .left_bearing = 2, .x_min = 3, .y_min = 4, .x_max = 5, .y_max = 6 };
    try testing.expect(!tb.GlyphMetrics(outline, 1, &metrics));
    try testing.expectEqual(truetype.GlyphMetrics{}, metrics);
    try testing.expectEqual(@as(i32, 650), tb.GlyphAdvance(outline, 1));
    var verbs: [8]u8 = undefined;
    var points: [8]vector.Point = undefined;
    var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 8, .point_room = 8 };
    try testing.expectEqual(truetype.TRUETYPEERR_NOMEM, tb.GlyphSegments(outline, 1, &segments));
    while (taken_count != 0) {
        taken_count -= 1;
        sys.FreeMem(taken[taken_count].block, taken[taken_count].size);
    }
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 650, .x_max = 600, .y_max = 740 }, try metricsOf(tb, outline, 1));
    tb.CloseOutline(outline);

    // Points that come to lie between whole units: the box holds them.
    outline = try openAt(tb, &file, &place(450, 100));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 605, .x_max = 510, .y_max = 704 }, try metricsOf(tb, outline, 1));
    tb.CloseOutline(outline);
    outline = try openAt(tb, &file, &place(775, 175));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .left_bearing = 2, .x_min = 2, .x_max = 578, .y_max = 753 }, try metricsOf(tb, outline, 2));
    tb.CloseOutline(outline);

    // A left side that moves is where the glyph starts: its bearing is
    // counted from there, and so is its advance.
    var sided: File = .{};
    fontOf(&sided, .{ .deltas = &.{
        .{},
        .{ .groups = &.{.{ .peak = .{ .shared = 0 }, .named = .{ .some = &.{4} }, .dx = &.{-40}, .dy = &.{0} }} },
        .{},
        .{},
        .{},
        .{},
    } });
    outline = try openAt(tb, &sided, &place(900, 100));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 640, .left_bearing = 40, .x_max = 500, .y_max = 700 }, try metricsOf(tb, outline, 1));
    tb.CloseOutline(outline);

    try rig.down();
}

test "variable: with HVAR an advance is the table's, a row a glyph or the row its map names" {
    var rig = try Rig.up();
    const tb = rig.tb;

    const Case = struct { weight: f32, width: f32 = 100, glyph: u32, advance: i32 };

    // A row a glyph.
    var file: File = .{};
    fontOf(&file, .{ .advances = .rows });
    for ([_]Case{
        .{ .weight = 400, .glyph = 1, .advance = 600 },
        .{ .weight = 650, .glyph = 1, .advance = 626 },
        .{ .weight = 650, .glyph = 3, .advance = 250 },
        // Not the 650 its side points give: the table counts.
        .{ .weight = 900, .glyph = 1, .advance = 651 },
        // Never less than nothing.
        .{ .weight = 900, .glyph = 3, .advance = 0 },
        .{ .weight = 900, .glyph = 5, .advance = 1600 },
        .{ .weight = 900, .glyph = 0, .advance = 600 },
        .{ .weight = 250, .glyph = 1, .advance = 585 },
        .{ .weight = 250, .glyph = 2, .advance = 603 },
        .{ .weight = 100, .glyph = 1, .advance = 570 },
        .{ .weight = 900, .width = 150, .glyph = 1, .advance = 661 },
        .{ .weight = 400, .width = 200, .glyph = 2, .advance = 500 },
    }) |case| {
        const outline = try openAt(tb, &file, &place(case.weight, case.width));
        try testing.expectEqual(case.advance, tb.GlyphAdvance(outline, case.glyph));
        try testing.expectEqual(case.advance, (try metricsOf(tb, outline, case.glyph)).advance);
        tb.CloseOutline(outline);
    }
    // The outline is gvar's all the same.
    {
        const outline = try openAt(tb, &file, &place(900, 100));
        try expectCorners(tb, outline, 1, squareTo(600, 740));
        tb.CloseOutline(outline);
    }

    // By a map, in both its forms: a glyph past its end has its last
    // entry's row.
    for ([_]Advances{ .map, .long_map }) |form| {
        var mapped: File = .{};
        fontOf(&mapped, .{ .advances = form });
        for ([_]Case{
            .{ .weight = 900, .glyph = 0, .advance = 600 },
            .{ .weight = 900, .glyph = 1, .advance = 100600 },
            .{ .weight = 900, .glyph = 2, .advance = 900 },
            .{ .weight = 900, .glyph = 3, .advance = 598 },
            .{ .weight = 900, .glyph = 4, .advance = 598 },
            .{ .weight = 900, .glyph = 5, .advance = 598 },
            .{ .weight = 900, .width = 200, .glyph = 1, .advance = 100607 },
            // Three quarters of 100000 and a quarter of a quarter of 7.
            .{ .weight = 775, .width = 175, .glyph = 1, .advance = 75602 },
            .{ .weight = 400, .glyph = 1, .advance = 600 },
        }) |case| {
            const outline = try openAt(tb, &mapped, &place(case.weight, case.width));
            try testing.expectEqual(case.advance, tb.GlyphAdvance(outline, case.glyph));
            tb.CloseOutline(outline);
        }
    }

    // A map that names rows the table does not have: nothing is added.
    var lost: File = .{};
    fontOf(&lost, .{ .advances = .lost });
    const outline = try openAt(tb, &lost, &place(900, 200));
    for (0..6) |glyph| try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, @intCast(glyph)));
    tb.CloseOutline(outline);

    try rig.down();
}

test "variable: MVAR moves the font's measures it is read for, and no other" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var file: File = .{};
    fontOf(&file, .{ .measures = true });
    const Case = struct { weight: f32, x_height: i32, cap_height: i32, under: i32, under_thick: i32, strike: i32, strike_thick: i32 };
    for ([_]Case{
        .{ .weight = 400, .x_height = 480, .cap_height = 700, .under = -100, .under_thick = 40, .strike = 250, .strike_thick = 50 },
        // Halves go up.
        .{ .weight = 650, .x_height = 490, .cap_height = 685, .under = -104, .under_thick = 43, .strike = 256, .strike_thick = 52 },
        .{ .weight = 900, .x_height = 500, .cap_height = 669, .under = -109, .under_thick = 45, .strike = 261, .strike_thick = 53 },
        // The table says nothing of less weight.
        .{ .weight = 100, .x_height = 480, .cap_height = 700, .under = -100, .under_thick = 40, .strike = 250, .strike_thick = 50 },
    }) |case| {
        const outline = try openAt(tb, &file, &place(case.weight, 100));
        var metrics: truetype.FontMetrics = .{};
        tb.FontMetrics(outline, &metrics);
        try testing.expectEqual(case.x_height, metrics.x_height);
        try testing.expectEqual(case.cap_height, metrics.cap_height);
        try testing.expectEqual(case.under, metrics.underline_position);
        try testing.expectEqual(case.under_thick, metrics.underline_thickness);
        try testing.expectEqual(case.strike, metrics.strikeout_position);
        try testing.expectEqual(case.strike_thick, metrics.strikeout_thickness);
        // The line's own measures stay, whatever the table says of them.
        try testing.expectEqual(@as(i32, builder.ascender), metrics.ascender);
        try testing.expectEqual(@as(i32, builder.descender), metrics.descender);
        try testing.expectEqual(@as(i32, builder.line_gap), metrics.line_gap);
        try testing.expectEqual(@as(u32, 6), metrics.glyph_count);
        tb.CloseOutline(outline);
    }

    try rig.down();
}

// --- what is read at the default, and what is not read ---------------------

/// One axis more than a font is read with.
const many_axes = made: {
    var axes: [33]Axis = undefined;
    for (&axes, 0..) |*axis, index| {
        const tag = [4]u8{ 'a', 'x', '0' + index / 10, '0' + index % 10 };
        axis.* = .{ .tag = &tag, .least = 100, .middle = 400, .most = 900, .name = 256 + index };
    }
    break :made axes;
};

test "variable: a font of more axes than are read is at its default, and so is one whose deltas count other axes" {
    var rig = try Rig.up();
    const tb = rig.tb;

    // Deltas for the first of 33 axes, which the font's place is the
    // most of.
    const peak = [_]i16{16384} ++ [_]i16{0} ** 32;
    var file: File = .{};
    fontOf(&file, .{
        .axes = &many_axes,
        .instances = &.{},
        .delta_axes = 33,
        .peaks = &.{},
        .deltas = &.{
            .{},
            .{ .groups = &.{.{ .peak = .{ .own = &peak }, .dx = &.{ 0, 0, 100, 100, 0, 50, 0, 0 }, .dy = &.{ 0, 40, 40, 0, 0, 0, 0, 0 } }} },
            .{},
            .{},
            .{},
            .{},
        },
    });
    var values: [33]truetype.AxisValue = undefined;
    for (&values, many_axes) |*value, axis| value.* = .{ .tag = truetype.tableTag(axis.tag), .value = 900 };
    var outline = try openAt(tb, &file, &values);
    var axes: [34]truetype.Axis = undefined;
    try testing.expectEqual(@as(u32, 33), tb.FontAxes(outline, &axes, 34));
    for (axes[0..33], many_axes, 0..) |axis, made, index| {
        try testing.expectEqual(truetype.Axis{
            .tag = truetype.tableTag(made.tag),
            .minimum = 100,
            .default = 400,
            .maximum = 900,
            .value = 400,
            .name = @intCast(256 + index),
            .hidden = false,
        }, axis);
    }
    var coords: [34]i16 = @splat(77);
    try testing.expectEqual(@as(u32, 33), tb.FontCoordinates(outline, &coords, 34));
    for (coords[0..33]) |coord| try testing.expectEqual(@as(i16, 0), coord);
    try testing.expectEqual(@as(i16, 77), coords[33]);
    try testing.expectEqual(@as(u32, 0), tb.FontInstance(outline, 0, null, 0));
    try expectCorners(tb, outline, 1, squareTo(500, 700));
    try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, 1));
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .x_max = 500, .y_max = 700 }, try metricsOf(tb, outline, 1));
    tb.CloseOutline(outline);

    // The same deltas in a font of the 32 axes that are read do move.
    var read: File = .{};
    fontOf(&read, .{
        .axes = many_axes[0..32],
        .instances = &.{},
        .delta_axes = 32,
        .peaks = &.{},
        .deltas = &.{
            .{},
            .{ .groups = &.{.{ .peak = .{ .own = peak[0..32] }, .dx = &.{ 0, 0, 100, 100, 0, 50, 0, 0 }, .dy = &.{ 0, 40, 40, 0, 0, 0, 0, 0 } }} },
            .{},
            .{},
            .{},
            .{},
        },
    });
    outline = try openAt(tb, &read, values[0..32]);
    try testing.expectEqual(@as(u32, 32), tb.FontCoordinates(outline, &coords, 34));
    for (coords[0..32]) |coord| try testing.expectEqual(@as(i16, 16384), coord);
    try expectCorners(tb, outline, 1, squareTo(600, 740));
    try testing.expectEqual(@as(i32, 650), tb.GlyphAdvance(outline, 1));
    tb.CloseOutline(outline);

    // Deltas that say they are for three axes, in a font of two: the
    // place is the one asked for, and the glyphs do not move.
    var other: File = .{};
    fontOf(&other, .{ .delta_axes = 3 });
    outline = try openAt(tb, &other, &place(900, 200));
    try testing.expectEqual([2]i16{ 16384, 16384 }, try coordinatesOf(tb, outline));
    for (1..5) |glyph| {
        try expectCorners(tb, outline, @intCast(glyph), squareTo(500, 700));
        try testing.expectEqual(@as(i32, 600), tb.GlyphAdvance(outline, @intCast(glyph)));
    }
    try testing.expectEqual(truetype.GlyphMetrics{ .advance = 600, .x_max = 500, .y_max = 700 }, try metricsOf(tb, outline, 1));
    tb.CloseOutline(outline);

    try rig.down();
}

test "variable: deltas that end early leave their glyph unread and its advance the plain one" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var verbs: [16]u8 = undefined;
    var points: [16]vector.Point = undefined;
    var segments = truetype.Segments{ .verbs = &verbs, .points = &points, .verb_room = 16, .point_room = 16 };

    // Glyph 1's deltas end six bytes before they are through.
    for ([_]Advances{ .sides, .rows }) |advances| {
        var file: File = .{};
        fontOf(&file, .{ .advances = advances });
        const end = tableAt(&file, "gvar") + 20 + 2 * 4;
        file.setLong(end, std.mem.readInt(u32, file.bytes[end..][0..4], .big) - 6);

        const outline = try openAt(tb, &file, &place(900, 100));
        try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.GlyphSegments(outline, 1, &segments));
        // With the font's table of advances the glyph still has the
        // instance's; by its sides it has the plain one.
        const advance: i32 = if (advances == .rows) 651 else 600;
        try testing.expectEqual(advance, tb.GlyphAdvance(outline, 1));
        try testing.expectEqual(truetype.GlyphMetrics{ .advance = advance }, try metricsOf(tb, outline, 1));
        // The glyph put together of it is not read either.
        try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.GlyphSegments(outline, 5, &segments));
        // A glyph whose deltas are whole is.
        try expectCorners(tb, outline, 3, squareAt(-20, 0));
        if (advances == .sides) try testing.expectEqual(@as(i32, 630), tb.GlyphAdvance(outline, 3));
        // Rendered it is a glyph without ink, as any the file is
        // damaged in.
        const shown = try show(tb, outline, 1);
        try testing.expectEqual(sdk.graphics.fontimage.Glyph{ .advance = if (advances == .rows) 65 else 60 }, shown.glyph);
        tb.CloseOutline(outline);

        // At the default the deltas are not read: the glyph is whole.
        const plain = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
        try expectCorners(tb, plain, 1, squareTo(500, 700));
        tb.CloseOutline(plain);
    }

    try rig.down();
}

// --- rendered --------------------------------------------------------------

/// A glyph rendered, four bits a pixel.
const Shown = struct {
    bytes: [8192]u8 = undefined,
    glyph: sdk.graphics.fontimage.Glyph = .{},

    /// How much of the pixel at (`x`, `y`) of the box is covered, of 15.
    fn inked(shown: *const Shown, x: u32, y: u32) u8 {
        const pair = shown.bytes[y * shown.glyph.pitch + x / 2];
        return if (x % 2 == 0) pair >> 4 else pair & 0x0F;
    }
};

/// Glyph `glyph` on a line of 100 rows: a unit of the built fonts is a
/// tenth of a pixel there.
fn show(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32) !Shown {
    var shown: Shown = .{};
    var image = truetype.GlyphImage{ .pixels = &shown.bytes, .room = shown.bytes.len };
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, glyph, 100, &image));
    try testing.expectEqual(sdk.graphics.fontimage.Kind.alpha4, image.kind);
    shown.glyph = image.glyph;
    return shown;
}

test "variable: a glyph is rendered as its instance draws it" {
    var rig = try Rig.up();
    const tb = rig.tb;
    const Glyph = sdk.graphics.fontimage.Glyph;

    var file: File = .{};
    fontOf(&file, .{});

    var outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NoOutline;
    var shown = try show(tb, outline, 1);
    try testing.expectEqual(Glyph{ .width = 50, .rows = 70, .top = 10, .left = 0, .advance = 60, .pitch = 25 }, shown.glyph);
    tb.CloseOutline(outline);

    outline = try openAt(tb, &file, &place(900, 100));
    shown = try show(tb, outline, 1);
    try testing.expectEqual(Glyph{ .width = 60, .rows = 74, .top = 6, .left = 0, .advance = 65, .pitch = 30 }, shown.glyph);
    for (0..74) |y| {
        for (0..60) |x| try testing.expectEqual(@as(u8, 15), shown.inked(@intCast(x), @intCast(y)));
    }
    // A contour that went left starts before the point.
    shown = try show(tb, outline, 3);
    try testing.expectEqual(Glyph{ .width = 50, .rows = 70, .top = 10, .left = -2, .advance = 63, .pitch = 25 }, shown.glyph);
    // The glyph put together: its parts wider, the second further out.
    shown = try show(tb, outline, 5);
    try testing.expectEqual(Glyph{ .width = 140, .rows = 74, .top = 6, .left = 0, .advance = 90, .pitch = 70 }, shown.glyph);
    for ([_]u32{ 0, 37, 73 }) |y| {
        for (0..140) |x| try testing.expectEqual(@as(u8, if (x < 60 or x >= 80) 15 else 0), shown.inked(@intCast(x), y));
    }
    tb.CloseOutline(outline);

    try rig.down();
}

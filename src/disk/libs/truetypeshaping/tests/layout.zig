// SPDX-License-Identifier: MIT
//! Layout tables built by the tests: `GDEF`, and a `GSUB` or `GPOS` of
//! the scripts, features and lookups a test names, around subtables the
//! test writes with the helpers of subtables.zig.
//!
//! A test says what one lookup holds and gets a table that is sound in
//! everything else, so what it then sees of the shaping is about that
//! lookup. The bytes are written with the font builder's `File`,
//! big-endian.

const std = @import("std");
const builder = @import("../../truetype/tests/builder.zig");

pub const File = builder.File;

/// A coverage table of single glyphs, which rise.
pub fn coverage(file: *File, glyphs: []const u16) void {
    file.word(1);
    file.word(@intCast(glyphs.len));
    for (glyphs) |glyph| file.word(glyph);
}

/// A coverage table of ranges, each a first and a last glyph.
pub fn coverageRanges(file: *File, ranges: []const [2]u16) void {
    file.word(2);
    file.word(@intCast(ranges.len));
    var index: u16 = 0;
    for (ranges) |range| {
        file.word(range[0]);
        file.word(range[1]);
        file.word(index);
        index += range[1] - range[0] + 1;
    }
}

/// A glyph and the class it is in.
pub const InClass = struct { glyph: u16, class: u16 };

/// A class definition of ranges of one glyph each; the glyphs rise.
pub fn classes(file: *File, list: []const InClass) void {
    file.word(2);
    file.word(@intCast(list.len));
    for (list) |entry| {
        file.word(entry.glyph);
        file.word(entry.glyph);
        file.word(entry.class);
    }
}

/// A class definition that lists the classes of the glyphs from `first`
/// on.
pub fn classList(file: *File, first: u16, list: []const u16) void {
    file.word(1);
    file.word(first);
    file.word(@intCast(list.len));
    for (list) |class| file.word(class);
}

/// A word left open for the distance from `base` to a table written
/// later.
pub fn open(file: *File) u32 {
    file.word(0);
    return file.len - 2;
}

/// The table an open word is for starts here.
pub fn here(file: *File, where: u32, base: u32) void {
    file.setWord(where, @intCast(file.len - base));
}

/// What a `GDEF` says: each glyph's kind (1 base, 2 ligature, 3 mark),
/// the marks' classes, sets of marks, and the store of deltas a variable
/// font's layout tables vary their numbers by, written whole elsewhere.
pub const Kinds = struct {
    kinds: []const InClass = &.{},
    mark_classes: []const InClass = &.{},
    mark_sets: []const []const u16 = &.{},
    store: []const u8 = &.{},
};

pub fn gdef(file: *File, parts: Kinds) void {
    const base = file.len;
    const stored = parts.store.len != 0;
    file.word(1);
    file.word(if (stored) 3 else if (parts.mark_sets.len != 0) 2 else 0);
    const kinds_at = open(file);
    file.word(0);
    file.word(0);
    const mark_classes_at = open(file);
    var sets_at: u32 = 0;
    if (parts.mark_sets.len != 0 or stored) sets_at = open(file);
    const store_at = file.len;
    if (stored) file.long(0);
    here(file, kinds_at, base);
    classes(file, parts.kinds);
    if (parts.mark_classes.len != 0) {
        here(file, mark_classes_at, base);
        classes(file, parts.mark_classes);
    }
    if (parts.mark_sets.len != 0) {
        here(file, sets_at, base);
        const sets = file.len;
        file.word(1);
        file.word(@intCast(parts.mark_sets.len));
        const offsets = file.len;
        file.skip(@intCast(parts.mark_sets.len * 4));
        for (parts.mark_sets, 0..) |set, index| {
            file.setLong(offsets + @as(u32, @intCast(index)) * 4, file.len - sets);
            coverage(file, set);
        }
    }
    if (stored) {
        file.setLong(store_at, file.len - base);
        for (parts.store) |byte| file.byte(byte);
    }
}

/// A region: for each axis where it starts to count, its peak, and
/// where it has stopped counting.
pub const Region = []const [3]i16;

/// A list of a store: the regions its rows have a delta for, how many
/// of a row's deltas are wide - with `long_words`, 32 bits wide and the
/// others 16, else 16 and 8 - and the rows.
pub const StoreList = struct {
    regions: []const u16,
    wide: u16,
    long_words: bool = false,
    rows: []const []const i32,
};

/// A store of deltas on `axes` axes, as `Kinds.store` takes it.
pub fn store(file: *File, axes: u16, regions: []const Region, lists: []const StoreList) void {
    const base = file.len;
    file.word(1);
    const regions_at = file.len;
    file.long(0);
    file.word(@intCast(lists.len));
    const offsets = file.len;
    file.skip(@intCast(lists.len * 4));
    file.setLong(regions_at, file.len - base);
    file.word(axes);
    file.word(@intCast(regions.len));
    for (regions) |region| {
        for (region) |axis| {
            for (axis) |number| file.signed(number);
        }
    }
    for (lists, 0..) |list, index| {
        file.setLong(offsets + @as(u32, @intCast(index)) * 4, file.len - base);
        file.word(@intCast(list.rows.len));
        file.word(list.wide | (if (list.long_words) @as(u16, 0x8000) else 0));
        file.word(@intCast(list.regions.len));
        for (list.regions) |region| file.word(region);
        for (list.rows) |row| {
            for (row, 0..) |value, place| {
                if (place < list.wide) {
                    if (list.long_words) file.long(@bitCast(value)) else file.signed(@intCast(value));
                } else {
                    if (list.long_words) file.signed(@intCast(value)) else file.byte(@bitCast(@as(i8, @intCast(value))));
                }
            }
        }
    }
}

/// A lookup: its kind, its flags, the set of marks its flags name, and
/// its subtables, each written whole elsewhere.
pub const Lookup = struct {
    kind: u16,
    flags: u16 = 0,
    mark_set: u16 = 0,
    subtables: []const []const u8,
};

/// A feature: its tag and the numbers of its lookups.
pub const Feature = struct {
    tag: *const [4]u8,
    lookups: []const u16,
};

/// A language of a script: its tag - null for the script's default - the
/// feature it requires, and the numbers of its features.
pub const Language = struct {
    tag: ?*const [4]u8 = null,
    required: u16 = 0xFFFF,
    features: []const u16,
};

pub const Script = struct {
    tag: *const [4]u8,
    languages: []const Language,
};

/// A condition on one of a variable font's axes: its value, in 16384ths,
/// within `low` and `high`.
pub const Condition = struct {
    format: u16 = 1,
    axis: u16 = 0,
    low: i16,
    high: i16,
};

/// A feature replaced: its number, and the lookups it then has.
pub const Replaced = struct {
    feature: u16,
    lookups: []const u16,
};

/// Features replaced where every one of the conditions holds.
pub const Variation = struct {
    conditions: []const Condition,
    replaced: []const Replaced,
};

/// A `GSUB` or `GPOS` of these scripts, features and lookups.
pub fn tableOf(file: *File, scripts: []const Script, features: []const Feature, lookups: []const Lookup) void {
    tableVaried(file, scripts, features, lookups, &.{});
}

/// The same with features replaced under conditions, which makes it a
/// table of version 1.1.
pub fn tableVaried(file: *File, scripts: []const Script, features: []const Feature, lookups: []const Lookup, variations: []const Variation) void {
    const base = file.len;
    file.long(if (variations.len != 0) 0x0001_0001 else 0x0001_0000);
    const scripts_at = open(file);
    const features_at = open(file);
    const lookups_at = open(file);
    const variations_at = file.len;
    if (variations.len != 0) file.long(0);

    here(file, scripts_at, base);
    const script_list = file.len;
    file.word(@intCast(scripts.len));
    const script_records = file.len;
    file.skip(@intCast(scripts.len * 6));
    for (scripts, 0..) |script, index| {
        const record = script_records + @as(u32, @intCast(index)) * 6;
        @memcpy(file.bytes[record..][0..4], script.tag);
        file.setWord(record + 4, @intCast(file.len - script_list));
        const script_table = file.len;
        const default_at = open(file);
        var tagged: u16 = 0;
        for (script.languages) |language| {
            if (language.tag != null) tagged += 1;
        }
        file.word(tagged);
        const language_records = file.len;
        file.skip(@as(u32, tagged) * 6);
        var next: u32 = 0;
        for (script.languages) |language| {
            if (language.tag) |tag| {
                const language_record = language_records + next * 6;
                next += 1;
                @memcpy(file.bytes[language_record..][0..4], tag);
                file.setWord(language_record + 4, @intCast(file.len - script_table));
            } else {
                here(file, default_at, script_table);
            }
            file.word(0);
            file.word(language.required);
            file.word(@intCast(language.features.len));
            for (language.features) |feature| file.word(feature);
        }
    }

    here(file, features_at, base);
    const feature_list = file.len;
    file.word(@intCast(features.len));
    const feature_records = file.len;
    file.skip(@intCast(features.len * 6));
    for (features, 0..) |feature, index| {
        const record = feature_records + @as(u32, @intCast(index)) * 6;
        @memcpy(file.bytes[record..][0..4], feature.tag);
        file.setWord(record + 4, @intCast(file.len - feature_list));
        file.word(0);
        file.word(@intCast(feature.lookups.len));
        for (feature.lookups) |lookup| file.word(lookup);
    }

    here(file, lookups_at, base);
    const lookup_list = file.len;
    file.word(@intCast(lookups.len));
    const lookup_records = file.len;
    file.skip(@intCast(lookups.len * 2));
    for (lookups, 0..) |lookup, index| {
        file.setWord(lookup_records + @as(u32, @intCast(index)) * 2, @intCast(file.len - lookup_list));
        const lookup_table = file.len;
        file.word(lookup.kind);
        file.word(lookup.flags);
        file.word(@intCast(lookup.subtables.len));
        const offsets = file.len;
        file.skip(@intCast(lookup.subtables.len * 2));
        if (lookup.flags & 0x0010 != 0) file.word(lookup.mark_set);
        for (lookup.subtables, 0..) |subtable, place| {
            file.setWord(offsets + @as(u32, @intCast(place)) * 2, @intCast(file.len - lookup_table));
            file.text(subtable);
        }
    }

    if (variations.len == 0) return;
    file.setLong(variations_at, file.len - base);
    const list = file.len;
    file.word(1);
    file.word(0);
    file.long(@intCast(variations.len));
    const records = file.len;
    file.skip(@intCast(variations.len * 8));
    for (variations, 0..) |variation, index| {
        const record = records + @as(u32, @intCast(index)) * 8;
        file.setLong(record, file.len - list);
        const set = file.len;
        file.word(@intCast(variation.conditions.len));
        const conditions = file.len;
        file.skip(@intCast(variation.conditions.len * 4));
        for (variation.conditions, 0..) |condition, place| {
            file.setLong(conditions + @as(u32, @intCast(place)) * 4, file.len - set);
            file.word(condition.format);
            file.word(condition.axis);
            file.signed(condition.low);
            file.signed(condition.high);
        }
        file.setLong(record + 4, file.len - list);
        const substitution = file.len;
        file.word(1);
        file.word(0);
        file.word(@intCast(variation.replaced.len));
        const replacements = file.len;
        file.skip(@intCast(variation.replaced.len * 6));
        for (variation.replaced, 0..) |replaced, place| {
            const replacement = replacements + @as(u32, @intCast(place)) * 6;
            file.setWord(replacement, replaced.feature);
            file.setLong(replacement + 2, file.len - substitution);
            file.word(0);
            file.word(@intCast(replaced.lookups.len));
            for (replaced.lookups) |lookup| file.word(lookup);
        }
    }
}

/// A table of the script `DFLT` whose default language has every one of
/// `features`.
pub fn table(file: *File, features: []const Feature, lookups: []const Lookup) void {
    var numbers: [32]u16 = undefined;
    for (features, 0..) |_, index| numbers[index] = @intCast(index);
    tableOf(file, &.{.{ .tag = "DFLT", .languages = &.{.{ .features = numbers[0..features.len] }} }}, features, lookups);
}

/// A table of one feature, `test`, whose lookups are all of `lookups`.
pub fn tableOfOne(file: *File, lookups: []const Lookup) void {
    var numbers: [32]u16 = undefined;
    for (lookups, 0..) |_, index| numbers[index] = @intCast(index);
    table(file, &.{.{ .tag = "test", .lookups = numbers[0..lookups.len] }}, lookups);
}

test "a built table has its lists where its header says" {
    var file: File = .{};
    tableOfOne(&file, &.{.{ .kind = 1, .subtables = &.{&.{ 0, 1, 0, 6, 0, 1, 0, 1, 0, 1, 0, 5 }} }});
    const bytes = file.written();
    const scripts = std.mem.readInt(u16, bytes[4..6], .big);
    try std.testing.expectEqualSlices(u8, "DFLT", bytes[scripts + 2 ..][0..4]);
    const features = std.mem.readInt(u16, bytes[6..8], .big);
    try std.testing.expectEqualSlices(u8, "test", bytes[features + 2 ..][0..4]);
    const lookups = std.mem.readInt(u16, bytes[8..10], .big);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[lookups..][0..2], .big));
}

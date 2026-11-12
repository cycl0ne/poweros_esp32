// SPDX-License-Identifier: MIT
//! The subtables of the lookups a test builds, one helper for each form:
//! the substitutions of `GSUB`, the context and chained context forms the
//! two tables share, the extension, and `GPOS`'s positionings.
//!
//! Each helper writes one subtable whole at the end of a file, with the
//! coverage and class tables it refers to behind it.

const layout = @import("layout.zig");
const File = layout.File;
const InClass = layout.InClass;
const open = layout.open;
const here = layout.here;

// --- GSUB --------------------------------------------------------------------

/// Single substitution, format 1: each of `glyphs` plus `delta`.
pub fn singleDelta(file: *File, glyphs: []const u16, delta: i16) void {
    const base = file.len;
    file.word(1);
    const coverage_at = open(file);
    file.signed(delta);
    here(file, coverage_at, base);
    layout.coverage(file, glyphs);
}

/// Single substitution, format 2: each of `glyphs` to its substitute.
pub fn singleList(file: *File, glyphs: []const u16, substitutes: []const u16) void {
    const base = file.len;
    file.word(2);
    const coverage_at = open(file);
    file.word(@intCast(substitutes.len));
    for (substitutes) |glyph| file.word(glyph);
    here(file, coverage_at, base);
    layout.coverage(file, glyphs);
}

/// Multiple substitution: each of `glyphs` to its sequence. An alternate
/// substitution has the same form: each of `glyphs` and its alternates.
pub fn multiple(file: *File, glyphs: []const u16, sequences: []const []const u16) void {
    const base = file.len;
    file.word(1);
    const coverage_at = open(file);
    file.word(@intCast(sequences.len));
    const offsets = file.len;
    file.skip(@intCast(sequences.len * 2));
    for (sequences, 0..) |sequence, index| {
        file.setWord(offsets + @as(u32, @intCast(index)) * 2, @intCast(file.len - base));
        file.word(@intCast(sequence.len));
        for (sequence) |glyph| file.word(glyph);
    }
    here(file, coverage_at, base);
    layout.coverage(file, glyphs);
}

/// A ligature: the glyph it is, and its glyphs after the first.
pub const Ligature = struct { glyph: u16, rest: []const u16 };

/// Ligature substitution: for each of `firsts` its ligatures, in the
/// order they are tried.
pub fn ligature(file: *File, firsts: []const u16, sets: []const []const Ligature) void {
    const base = file.len;
    file.word(1);
    const coverage_at = open(file);
    file.word(@intCast(sets.len));
    const offsets = file.len;
    file.skip(@intCast(sets.len * 2));
    for (sets, 0..) |set, index| {
        file.setWord(offsets + @as(u32, @intCast(index)) * 2, @intCast(file.len - base));
        const set_base = file.len;
        file.word(@intCast(set.len));
        const ligatures = file.len;
        file.skip(@intCast(set.len * 2));
        for (set, 0..) |entry, place| {
            file.setWord(ligatures + @as(u32, @intCast(place)) * 2, @intCast(file.len - set_base));
            file.word(entry.glyph);
            file.word(@intCast(entry.rest.len + 1));
            for (entry.rest) |glyph| file.word(glyph);
        }
    }
    here(file, coverage_at, base);
    layout.coverage(file, firsts);
}

/// Reverse chained substitution: each of `glyphs` to its substitute,
/// between glyphs of the coverages `before` (the nearest first) and
/// `after`.
pub fn reverse(file: *File, glyphs: []const u16, before: []const []const u16, after: []const []const u16, substitutes: []const u16) void {
    const base = file.len;
    file.word(1);
    const coverage_at = open(file);
    file.word(@intCast(before.len));
    const before_at = file.len;
    file.skip(@intCast(before.len * 2));
    file.word(@intCast(after.len));
    const after_at = file.len;
    file.skip(@intCast(after.len * 2));
    file.word(@intCast(substitutes.len));
    for (substitutes) |glyph| file.word(glyph);
    here(file, coverage_at, base);
    layout.coverage(file, glyphs);
    coverages(file, base, before_at, before);
    coverages(file, base, after_at, after);
}

/// The coverages `list`, their distances from `base` written at `at`.
fn coverages(file: *File, base: u32, at: u32, list: []const []const u16) void {
    for (list, 0..) |glyphs, index| {
        file.setWord(at + @as(u32, @intCast(index)) * 2, @intCast(file.len - base));
        layout.coverage(file, glyphs);
    }
}

/// An extension: the subtable `inner`, of the kind `kind`, behind an
/// offset of 32 bits.
pub fn extension(file: *File, kind: u16, inner: []const u8) void {
    file.word(1);
    file.word(kind);
    file.long(8);
    file.text(inner);
}

// --- context and chained context --------------------------------------------

/// A lookup applied at a place of a matched sequence.
pub const Record = struct { at: u16, lookup: u16 };

/// A rule: what stands before the sequence (the nearest first), the
/// sequence after its first glyph, what stands after it - glyphs or
/// classes, as the form has it - and the lookups applied.
pub const Rule = struct {
    before: []const u16 = &.{},
    rest: []const u16 = &.{},
    after: []const u16 = &.{},
    records: []const Record,
};

fn records(file: *File, list: []const Record) void {
    for (list) |record| {
        file.word(record.at);
        file.word(record.lookup);
    }
}

/// The sets of rules, their distances from `base` at `offsets`; a set
/// of no rules is left out. `chained` says which form the rules have.
fn ruleSets(file: *File, base: u32, offsets: u32, sets: []const []const Rule, chained: bool) void {
    for (sets, 0..) |set, index| {
        if (set.len == 0) continue;
        file.setWord(offsets + @as(u32, @intCast(index)) * 2, @intCast(file.len - base));
        const set_base = file.len;
        file.word(@intCast(set.len));
        const rules = file.len;
        file.skip(@intCast(set.len * 2));
        for (set, 0..) |rule, place| {
            file.setWord(rules + @as(u32, @intCast(place)) * 2, @intCast(file.len - set_base));
            if (chained) {
                file.word(@intCast(rule.before.len));
                for (rule.before) |value| file.word(value);
                file.word(@intCast(rule.rest.len + 1));
                for (rule.rest) |value| file.word(value);
                file.word(@intCast(rule.after.len));
                for (rule.after) |value| file.word(value);
                file.word(@intCast(rule.records.len));
            } else {
                file.word(@intCast(rule.rest.len + 1));
                file.word(@intCast(rule.records.len));
                for (rule.rest) |value| file.word(value);
            }
            records(file, rule.records);
        }
    }
}

/// Context, format 1: for each of `firsts` its rules, by glyph.
pub fn context1(file: *File, firsts: []const u16, sets: []const []const Rule) void {
    const base = file.len;
    file.word(1);
    const coverage_at = open(file);
    file.word(@intCast(sets.len));
    const offsets = file.len;
    file.skip(@intCast(sets.len * 2));
    ruleSets(file, base, offsets, sets, false);
    here(file, coverage_at, base);
    layout.coverage(file, firsts);
}

/// Context, format 2: for each class of `class_list` its rules, by
/// class; `firsts` are the glyphs a sequence may start with.
pub fn context2(file: *File, firsts: []const u16, class_list: []const InClass, sets: []const []const Rule) void {
    const base = file.len;
    file.word(2);
    const coverage_at = open(file);
    const classes_at = open(file);
    file.word(@intCast(sets.len));
    const offsets = file.len;
    file.skip(@intCast(sets.len * 2));
    ruleSets(file, base, offsets, sets, false);
    here(file, coverage_at, base);
    layout.coverage(file, firsts);
    here(file, classes_at, base);
    layout.classes(file, class_list);
}

/// Context, format 3: a sequence of the coverages `input`.
pub fn context3(file: *File, input: []const []const u16, list: []const Record) void {
    const base = file.len;
    file.word(3);
    file.word(@intCast(input.len));
    file.word(@intCast(list.len));
    const input_at = file.len;
    file.skip(@intCast(input.len * 2));
    records(file, list);
    coverages(file, base, input_at, input);
}

/// Chained context, format 1: for each of `firsts` its rules, by glyph.
pub fn chain1(file: *File, firsts: []const u16, sets: []const []const Rule) void {
    const base = file.len;
    file.word(1);
    const coverage_at = open(file);
    file.word(@intCast(sets.len));
    const offsets = file.len;
    file.skip(@intCast(sets.len * 2));
    ruleSets(file, base, offsets, sets, true);
    here(file, coverage_at, base);
    layout.coverage(file, firsts);
}

/// Chained context, format 2: rules by class, with a class definition
/// for what stands before, for the sequence and for what stands after.
pub fn chain2(
    file: *File,
    firsts: []const u16,
    before_classes: []const InClass,
    input_classes: []const InClass,
    after_classes: []const InClass,
    sets: []const []const Rule,
) void {
    const base = file.len;
    file.word(2);
    const coverage_at = open(file);
    const before_at = open(file);
    const input_at = open(file);
    const after_at = open(file);
    file.word(@intCast(sets.len));
    const offsets = file.len;
    file.skip(@intCast(sets.len * 2));
    ruleSets(file, base, offsets, sets, true);
    here(file, coverage_at, base);
    layout.coverage(file, firsts);
    here(file, before_at, base);
    layout.classes(file, before_classes);
    here(file, input_at, base);
    layout.classes(file, input_classes);
    here(file, after_at, base);
    layout.classes(file, after_classes);
}

/// Chained context, format 3: coverages for what stands before (the
/// nearest first), for the sequence and for what stands after.
pub fn chain3(file: *File, before: []const []const u16, input: []const []const u16, after: []const []const u16, list: []const Record) void {
    const base = file.len;
    file.word(3);
    file.word(@intCast(before.len));
    const before_at = file.len;
    file.skip(@intCast(before.len * 2));
    file.word(@intCast(input.len));
    const input_at = file.len;
    file.skip(@intCast(input.len * 2));
    file.word(@intCast(after.len));
    const after_at = file.len;
    file.skip(@intCast(after.len * 2));
    file.word(@intCast(list.len));
    records(file, list);
    coverages(file, base, before_at, before);
    coverages(file, base, input_at, input);
    coverages(file, base, after_at, after);
}

// --- GPOS --------------------------------------------------------------------

/// The parts of a value record, a bit of its format each; a record's
/// values stand in this order.
pub const X_PLACEMENT: u16 = 0x0001;
pub const Y_PLACEMENT: u16 = 0x0002;
pub const X_ADVANCE: u16 = 0x0004;
pub const Y_ADVANCE: u16 = 0x0008;

fn values(file: *File, list: []const i16) void {
    for (list) |value| file.signed(value);
}

/// Single positioning, format 1: each of `glyphs` by the one record.
pub fn positionAll(file: *File, glyphs: []const u16, format: u16, record: []const i16) void {
    const base = file.len;
    file.word(1);
    const coverage_at = open(file);
    file.word(format);
    values(file, record);
    here(file, coverage_at, base);
    layout.coverage(file, glyphs);
}

/// Single positioning, format 2: each of `glyphs` by its own record.
pub fn positionEach(file: *File, glyphs: []const u16, format: u16, list: []const []const i16) void {
    const base = file.len;
    file.word(2);
    const coverage_at = open(file);
    file.word(format);
    file.word(@intCast(list.len));
    for (list) |record| values(file, record);
    here(file, coverage_at, base);
    layout.coverage(file, glyphs);
}

/// A pair's second glyph and the values of the two records, the first
/// glyph's before the second's.
pub const Pair = struct { second: u16, values: []const i16 };

/// Pair positioning, format 1: for each of `firsts` its pairs, whose
/// second glyphs rise.
pub fn pairs(file: *File, firsts: []const u16, first_format: u16, second_format: u16, sets: []const []const Pair) void {
    const base = file.len;
    file.word(1);
    const coverage_at = open(file);
    file.word(first_format);
    file.word(second_format);
    file.word(@intCast(sets.len));
    const offsets = file.len;
    file.skip(@intCast(sets.len * 2));
    for (sets, 0..) |set, index| {
        file.setWord(offsets + @as(u32, @intCast(index)) * 2, @intCast(file.len - base));
        file.word(@intCast(set.len));
        for (set) |entry| {
            file.word(entry.second);
            values(file, entry.values);
        }
    }
    here(file, coverage_at, base);
    layout.coverage(file, firsts);
}

/// Pair positioning, format 2: the values of each class of first glyph
/// with each class of second glyph, a row for each of the first's.
pub fn pairClasses(
    file: *File,
    firsts: []const u16,
    first_format: u16,
    second_format: u16,
    first_classes: []const InClass,
    second_classes: []const InClass,
    second_count: u16,
    rows: []const []const i16,
) void {
    const base = file.len;
    file.word(2);
    const coverage_at = open(file);
    file.word(first_format);
    file.word(second_format);
    const first_at = open(file);
    const second_at = open(file);
    file.word(@intCast(rows.len));
    file.word(second_count);
    for (rows) |row| values(file, row);
    here(file, coverage_at, base);
    layout.coverage(file, firsts);
    here(file, first_at, base);
    layout.classes(file, first_classes);
    here(file, second_at, base);
    layout.classes(file, second_classes);
}

/// An anchor: a point of a glyph. With `vary_x` or `vary_y` it is one
/// whose number is varied by that item of the first list of the font's
/// store of deltas.
pub const Point = struct { x: i16, y: i16, vary_x: ?u16 = null, vary_y: ?u16 = null };

/// A device table that names the item `item` of the list `list` of the
/// font's store of deltas.
pub fn device(file: *File, list: u16, item: u16) void {
    file.word(list);
    file.word(item);
    file.word(0x8000);
}

/// Writes a device table for the item `item` of the store's first list
/// at the end of `file`, and its distance from `base` at `where`.
pub fn deviceAt(file: *File, where: u32, base: u32, item: u16) void {
    file.setWord(where, @intCast(file.len - base));
    device(file, 0, item);
}

fn anchor(file: *File, point: Point) void {
    if (point.vary_x == null and point.vary_y == null) {
        file.word(1);
        file.signed(point.x);
        file.signed(point.y);
        return;
    }
    file.word(3);
    file.signed(point.x);
    file.signed(point.y);
    file.word(if (point.vary_x != null) 10 else 0);
    file.word(if (point.vary_y == null) 0 else if (point.vary_x != null) 16 else 10);
    if (point.vary_x) |item| device(file, 0, item);
    if (point.vary_y) |item| device(file, 0, item);
}

/// Where a glyph is joined to the one before it and to the one after;
/// null where it is not.
pub const Joint = struct { entry: ?Point = null, exit: ?Point = null };

/// Cursive attachment: each of `glyphs` and its joint.
pub fn cursive(file: *File, glyphs: []const u16, joints: []const Joint) void {
    const base = file.len;
    file.word(1);
    const coverage_at = open(file);
    file.word(@intCast(joints.len));
    const records_at = file.len;
    file.skip(@intCast(joints.len * 4));
    for (joints, 0..) |joint, index| {
        const record = records_at + @as(u32, @intCast(index)) * 4;
        if (joint.entry) |point| {
            file.setWord(record, @intCast(file.len - base));
            anchor(file, point);
        }
        if (joint.exit) |point| {
            file.setWord(record + 2, @intCast(file.len - base));
            anchor(file, point);
        }
    }
    here(file, coverage_at, base);
    layout.coverage(file, glyphs);
}

/// A mark: its class and its anchor.
pub const Mark = struct { class: u16, anchor: Point };

fn markArray(file: *File, list: []const Mark) void {
    const base = file.len;
    file.word(@intCast(list.len));
    const records_at = file.len;
    file.skip(@intCast(list.len * 4));
    for (list, 0..) |mark, index| {
        const record = records_at + @as(u32, @intCast(index)) * 4;
        file.setWord(record, mark.class);
        file.setWord(record + 2, @intCast(file.len - base));
        anchor(file, mark.anchor);
    }
}

/// Rows of anchors, one for each class of mark in a row; null where a
/// row has none for a class. The rows' count comes first.
fn anchorRows(file: *File, rows: []const []const ?Point) void {
    const base = file.len;
    file.word(@intCast(rows.len));
    const offsets = file.len;
    var cells: u32 = 0;
    for (rows) |row| cells += @intCast(row.len);
    file.skip(cells * 2);
    var cell: u32 = 0;
    for (rows) |row| {
        for (row) |point| {
            if (point) |given| {
                file.setWord(offsets + cell * 2, @intCast(file.len - base));
                anchor(file, given);
            }
            cell += 1;
        }
    }
}

/// Mark-to-base attachment: the marks `marks` with their classes and
/// anchors, and for each of `bases` its anchor for each of `classes`
/// classes. Mark-to-mark attachment has the same form: `bases` are the
/// marks sat on.
pub fn markToBase(file: *File, marks: []const u16, mark_list: []const Mark, bases: []const u16, classes: u16, rows: []const []const ?Point) void {
    const base = file.len;
    file.word(1);
    const marks_at = open(file);
    const bases_at = open(file);
    file.word(classes);
    const mark_array_at = open(file);
    const rows_at = open(file);
    here(file, marks_at, base);
    layout.coverage(file, marks);
    here(file, bases_at, base);
    layout.coverage(file, bases);
    here(file, mark_array_at, base);
    markArray(file, mark_list);
    here(file, rows_at, base);
    anchorRows(file, rows);
}

/// Mark-to-ligature attachment: for each of `ligatures` a row of anchors
/// for each of its parts.
pub fn markToLigature(
    file: *File,
    marks: []const u16,
    mark_list: []const Mark,
    ligatures: []const u16,
    classes: u16,
    parts: []const []const []const ?Point,
) void {
    const base = file.len;
    file.word(1);
    const marks_at = open(file);
    const ligatures_at = open(file);
    file.word(classes);
    const mark_array_at = open(file);
    const list_at = open(file);
    here(file, marks_at, base);
    layout.coverage(file, marks);
    here(file, ligatures_at, base);
    layout.coverage(file, ligatures);
    here(file, mark_array_at, base);
    markArray(file, mark_list);
    here(file, list_at, base);
    const list = file.len;
    file.word(@intCast(parts.len));
    const offsets = file.len;
    file.skip(@intCast(parts.len * 2));
    for (parts, 0..) |rows, index| {
        file.setWord(offsets + @as(u32, @intCast(index)) * 2, @intCast(file.len - list));
        anchorRows(file, rows);
    }
}

// SPDX-License-Identifier: MIT
//! The lookups that apply other lookups: a sequence of glyphs, and what
//! is to be done at which of its places.
//!
//! A context lookup names a sequence - by its glyphs, by their classes,
//! or by a coverage for each place - and a list of records, each a place
//! in the sequence and the lookup to apply there. A chained one also
//! names what must stand before the sequence and after it. `context` and
//! `chained` read the three formats of each into one form (`Rule`) and
//! apply the first rule that matches.
//!
//! A lookup applied at a place may change how long the run is; the
//! places behind it move with it (`applyRecords`), so the next record
//! still finds its glyph.

const _tables = @import("_tables.zig");
const Table = _tables.Table;
const _match = @import("_match.zig");
const Apply = _match.Apply;
const Matcher = _match.Matcher;
const Sequence = _match.Sequence;
const context_limit = _match.context_limit;
const _lookup = @import("_lookup.zig");

/// A sequence, what stands around it, and what to do at its places.
const Rule = struct {
    before: Sequence = .{},
    /// The sequence's glyphs after its first.
    input: Sequence,
    after: Sequence = .{},
    /// The records: a place in the sequence and a lookup, 16 bits each.
    records: Table,
    records_at: u32,
    record_count: u32,
};

/// How the three parts of a rule are compared: what stands before, the
/// sequence, what stands after.
const Matchers = [3]Matcher;

/// Applies `rule` at `at` when it matches; answers the place after the
/// sequence then.
fn applyRule(apply: *Apply, at: u32, rule: Rule, matchers: Matchers) ?u32 {
    const places = apply.placesHere();
    const matched = _match.matchInput(apply, at, rule.input, matchers[1], places) orelse return null;
    if (!_match.matchAfter(apply, matched.end, rule.after, matchers[2])) return null;
    if (!_match.matchBefore(apply, at, rule.before, matchers[0])) return null;
    return applyRecords(apply, places, rule.input.count + 1, rule, matched.end);
}

/// Applies a matched rule's lookups at its places, and answers where the
/// sequence ends afterwards.
fn applyRecords(apply: *Apply, places: *[context_limit]u32, matched: u32, rule: Rule, matched_end: u32) u32 {
    var count: i64 = matched;
    var end: i64 = matched_end;
    for (0..rule.record_count) |record| {
        if (!apply.spend()) break;
        const record_at = rule.records_at + @as(u32, @intCast(record)) * 4;
        const place = rule.records.word(record_at);
        if (place >= count) continue;
        const length = apply.buffer.len;
        // A lookup applied before may have taken the glyph away.
        if (places[place] >= length) continue;
        if (!_lookup.nested(apply, rule.records.word(record_at + 2), places[place])) continue;

        var delta: i64 = @as(i64, apply.buffer.len) - length;
        if (delta == 0) continue;
        // The run's length changed: the places behind this one move.
        end += delta;
        if (end < places[place]) {
            // Never back before the place itself.
            delta += places[place] - end;
            end = places[place];
        }
        var next: i64 = place + 1;
        if (delta > 0) {
            if (delta + count > context_limit) break;
            var index = count;
            while (index > next) {
                index -= 1;
                places[@intCast(index + delta)] = places[@intCast(index)];
            }
        } else {
            if (delta < next - count) delta = next - count;
            next -= delta;
            var index = next;
            while (index < count) : (index += 1) {
                places[@intCast(index + delta)] = places[@intCast(index)];
            }
        }
        next += delta;
        count += delta;
        // The glyphs a place became follow it one by one.
        var filled: i64 = place + 1;
        while (filled < next) : (filled += 1) {
            places[@intCast(filled)] = places[@intCast(filled - 1)] + 1;
        }
        while (next < count) : (next += 1) {
            const moved = @as(i64, places[@intCast(next)]) + delta;
            places[@intCast(next)] = if (moved < 0) 0 else @intCast(moved);
        }
    }
    return if (end < 0) 0 else @intCast(end);
}

/// A rule of a context lookup's formats 1 and 2: the sequence's length,
/// the records' count, the sequence, the records.
fn plainRule(table: Table) ?Rule {
    const glyphs = table.word(0);
    if (glyphs == 0) return null;
    const input = Sequence.init(table, 4, glyphs - 1);
    if (input.count > context_limit) return null;
    return .{
        .input = input,
        .records = table,
        .records_at = input.end(),
        .record_count = table.count(2, input.end(), 4),
    };
}

/// A rule of a chained context lookup's formats, from `at` on: what
/// stands before, the sequence, what stands after, the records - each a
/// count and its list. `whole` says the sequence's list has its first
/// glyph in it, as format 3's has.
fn chainedRule(table: Table, at: u32, whole: bool) ?Rule {
    const before = Sequence.init(table, at + 2, table.word(at));
    if (before.count > context_limit) return null;
    const glyphs = table.word(before.end());
    if (glyphs == 0) return null;
    const first = before.end() + 2;
    const input = Sequence.init(table, if (whole) first + 2 else first, glyphs - 1);
    if (input.count > context_limit) return null;
    const after = Sequence.init(table, input.end() + 2, table.word(input.end()));
    if (after.count > context_limit) return null;
    return .{
        .before = before,
        .input = input,
        .after = after,
        .records = table,
        .records_at = after.end() + 2,
        .record_count = table.count(after.end(), after.end() + 2, 4),
    };
}

/// Applies the first rule of the set `set` that matches at `at`.
fn applySet(apply: *Apply, at: u32, set: Table, is_chained: bool, matchers: Matchers) ?u32 {
    for (0..set.count(0, 2, 2)) |index| {
        if (!apply.spend()) return null;
        const table = set.partAt(2 + @as(u32, @intCast(index)) * 2);
        if (table.empty()) continue;
        const rule = (if (is_chained) chainedRule(table, 0, false) else plainRule(table)) orelse continue;
        if (applyRule(apply, at, rule, matchers)) |end| return end;
    }
    return null;
}

/// A context lookup's subtable applied at `at`. Answers the place to go
/// on from, or null when it does not apply there.
pub fn context(apply: *Apply, table: Table, at: u32) ?u32 {
    const glyph = apply.buffer.items[at].glyph;
    switch (table.word(0)) {
        1 => {
            const index = _tables.coverage(table.partAt(2), glyph) orelse return null;
            if (index >= table.count(4, 6, 2)) return null;
            const by_glyph: Matcher = .{ .by = .glyph };
            return applySet(apply, at, table.partAt(6 + index * 2), false, .{ by_glyph, by_glyph, by_glyph });
        },
        2 => {
            if (_tables.coverage(table.partAt(2), glyph) == null) return null;
            const classes = table.partAt(4);
            const class = _tables.classOf(classes, glyph);
            if (class >= table.count(6, 8, 2)) return null;
            const by_class: Matcher = .{ .by = .class, .table = classes };
            return applySet(apply, at, table.partAt(8 + class * 2), false, .{ by_class, by_class, by_class });
        },
        3 => {
            const glyphs = table.word(2);
            if (glyphs == 0) return null;
            if (_tables.coverage(table.partAt(6), glyph) == null) return null;
            const input = Sequence.init(table, 8, glyphs - 1);
            if (input.count > context_limit) return null;
            const by_coverage: Matcher = .{ .by = .coverage, .table = table };
            return applyRule(apply, at, .{
                .input = input,
                .records = table,
                .records_at = input.end(),
                .record_count = table.count(4, input.end(), 4),
            }, .{ by_coverage, by_coverage, by_coverage });
        },
        else => return null,
    }
}

/// A chained context lookup's subtable applied at `at`. Answers the
/// place to go on from, or null when it does not apply there.
pub fn chained(apply: *Apply, table: Table, at: u32) ?u32 {
    const glyph = apply.buffer.items[at].glyph;
    switch (table.word(0)) {
        1 => {
            const index = _tables.coverage(table.partAt(2), glyph) orelse return null;
            if (index >= table.count(4, 6, 2)) return null;
            const by_glyph: Matcher = .{ .by = .glyph };
            return applySet(apply, at, table.partAt(6 + index * 2), true, .{ by_glyph, by_glyph, by_glyph });
        },
        2 => {
            if (_tables.coverage(table.partAt(2), glyph) == null) return null;
            const classes = table.partAt(6);
            const class = _tables.classOf(classes, glyph);
            if (class >= table.count(10, 12, 2)) return null;
            return applySet(apply, at, table.partAt(12 + class * 2), true, .{
                .{ .by = .class, .table = table.partAt(4) },
                .{ .by = .class, .table = classes },
                .{ .by = .class, .table = table.partAt(8) },
            });
        },
        3 => {
            const rule = chainedRule(table, 2, true) orelse return null;
            // The sequence's first coverage stands before the list read.
            if (_tables.coverage(table.partAt(rule.input.at - 2), glyph) == null) return null;
            const by_coverage: Matcher = .{ .by = .coverage, .table = table };
            return applyRule(apply, at, rule, .{ by_coverage, by_coverage, by_coverage });
        },
        else => return null,
    }
}

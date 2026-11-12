// SPDX-License-Identifier: MIT
//! Whether a lookup of `GSUB` would make something of a few glyphs that
//! stand by themselves.
//!
//! A script's model asks a font what it has: whether a consonant has a
//! form below the base, whether a ra with the halant behind it becomes a
//! reph. The answer is read off the lookups of the feature without a
//! run to apply them to: a lookup would replace the glyphs when one of
//! its subtables has a rule for exactly them - one glyph it covers, a
//! ligature of just these parts, a rule of a context whose sequence is
//! these glyphs and no more. What a rule then does is not looked at,
//! and neither are the lookup's flags.
//!
//! A rule that asks for glyphs before or behind the sequence counts
//! only where the caller lets it (`alone` not set): standing alone, the
//! glyphs have nothing around them.

const _tables = @import("_tables.zig");
const Table = _tables.Table;
const _match = @import("_match.zig");
const Matcher = _match.Matcher;
const Sequence = _match.Sequence;

const SINGLE = 1;
const MULTIPLE = 2;
const ALTERNATE = 3;
const LIGATURE = 4;
const CONTEXT = 5;
const CHAINED = 6;
const EXTENSION = 7;
const REVERSE = 8;

/// Whether the lookup `index` of the list `lookups` has a rule for
/// exactly `glyphs`. With `alone`, a rule that asks for glyphs around
/// them is none.
pub fn wouldReplace(lookups: Table, index: u32, glyphs: []const u32, alone: bool) bool {
    if (glyphs.len == 0 or index >= lookups.count(0, 2, 2)) return false;
    const lookup = lookups.partAt(2 + index * 2);
    if (lookup.empty()) return false;
    const kind = lookup.word(0);
    for (0..lookup.count(4, 6, 2)) |entry| {
        var table = lookup.partAt(6 + @as(u32, @intCast(entry)) * 2);
        var table_kind = kind;
        if (kind == EXTENSION) {
            if (table.word(0) != 1 or table.word(2) == EXTENSION) continue;
            table_kind = table.word(2);
            table = table.partAtLong(4);
        }
        if (table.empty()) continue;
        if (subtableWould(table_kind, table, glyphs, alone)) return true;
    }
    return false;
}

fn subtableWould(kind: u32, table: Table, glyphs: []const u32, alone: bool) bool {
    const format = table.word(0);
    switch (kind) {
        SINGLE, MULTIPLE, ALTERNATE, REVERSE => {
            if (format != 1 and !(kind == SINGLE and format == 2)) return false;
            return glyphs.len == 1 and _tables.coverage(table.partAt(2), glyphs[0]) != null;
        },
        LIGATURE => {
            if (format != 1) return false;
            const index = _tables.coverage(table.partAt(2), glyphs[0]) orelse return false;
            if (index >= table.count(4, 6, 2)) return false;
            const set = table.partAt(6 + index * 2);
            for (0..set.count(0, 2, 2)) |entry| {
                const made = set.partAt(2 + @as(u32, @intCast(entry)) * 2);
                if (made.empty() or made.word(2) != glyphs.len) continue;
                const rest = Sequence.init(made, 4, made.word(2) - 1);
                if (sequenceIs(rest, glyphs, .{ .by = .glyph })) return true;
            }
            return false;
        },
        CONTEXT, CHAINED => {
            const is_chained = kind == CHAINED;
            switch (format) {
                1 => {
                    const index = _tables.coverage(table.partAt(2), glyphs[0]) orelse return false;
                    if (index >= table.count(4, 6, 2)) return false;
                    return setWould(table.partAt(6 + index * 2), is_chained, glyphs, .{ .by = .glyph }, alone);
                },
                2 => {
                    if (_tables.coverage(table.partAt(2), glyphs[0]) == null) return false;
                    const classes = table.partAt(if (is_chained) 6 else 4);
                    const class = _tables.classOf(classes, glyphs[0]);
                    const sets: u32 = if (is_chained) 10 else 6;
                    if (class >= table.count(sets, sets + 2, 2)) return false;
                    const set = table.partAt(sets + 2 + class * 2);
                    return setWould(set, is_chained, glyphs, .{ .by = .class, .table = classes }, alone);
                },
                3 => {
                    // The sequence's coverages, the first glyph's among
                    // them.
                    var at: u32 = 2;
                    if (is_chained) {
                        const before = Sequence.init(table, 4, table.word(2));
                        if (alone and before.count != 0) return false;
                        at = before.end();
                    }
                    const said = table.word(at);
                    if (said != glyphs.len) return false;
                    const input = Sequence.init(table, if (is_chained) at + 2 else 6, said);
                    if (input.count != said) return false;
                    for (glyphs, 0..) |glyph, place| {
                        if (_tables.coverage(table.partAt(input.at + @as(u32, @intCast(place)) * 2), glyph) == null) return false;
                    }
                    return !(is_chained and alone and table.word(input.end()) != 0);
                },
                else => return false,
            }
        },
        else => return false,
    }
}

/// Whether a rule of `set` is for exactly `glyphs`.
fn setWould(set: Table, is_chained: bool, glyphs: []const u32, matcher: Matcher, alone: bool) bool {
    for (0..set.count(0, 2, 2)) |entry| {
        const rule = set.partAt(2 + @as(u32, @intCast(entry)) * 2);
        if (rule.empty()) continue;
        var at: u32 = 0;
        if (is_chained) {
            const before = Sequence.init(rule, 2, rule.word(0));
            if (alone and before.count != 0) continue;
            at = before.end();
        }
        const said = rule.word(at);
        if (said != glyphs.len) continue;
        const rest = Sequence.init(rule, if (is_chained) at + 2 else 4, said - 1);
        if (!sequenceIs(rest, glyphs, matcher)) continue;
        if (is_chained and alone and rule.word(rest.end()) != 0) continue;
        return true;
    }
    return false;
}

/// Whether `rest` is what a rule says of the glyphs behind the first of
/// `glyphs`.
fn sequenceIs(rest: Sequence, glyphs: []const u32, matcher: Matcher) bool {
    if (rest.count + 1 != glyphs.len) return false;
    for (glyphs[1..], 0..) |glyph, place| {
        if (!matcher.matches(glyph, rest.get(@intCast(place)))) return false;
    }
    return true;
}

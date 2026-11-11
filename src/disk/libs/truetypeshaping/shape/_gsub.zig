// SPDX-License-Identifier: MIT
//! `GSUB`'s lookups: a glyph replaced by another, by several, by one of
//! a choice; several replaced by one.
//!
//! Each function here is one kind of subtable applied at one place of
//! the run. It answers the place to go on from, or null when the
//! subtable does not hold for the glyph there. The kinds that name other
//! lookups are in `_context.zig`.
//!
//! A ligature keeps track of what it was made of: it gets a number, the
//! count of its parts, and the lowest cluster of them; a mark that stood
//! between its parts stays behind it and is told which part it sits on.
//! That is what lets a later lookup place the mark on that part.

const _tables = @import("_tables.zig");
const Table = _tables.Table;
const _buffer = @import("_buffer.zig");
const _match = @import("_match.zig");
const Apply = _match.Apply;
const Sequence = _match.Sequence;

const SINGLE = 1;
const MULTIPLE = 2;
const ALTERNATE = 3;
const LIGATURE = 4;
const REVERSE = 8;

/// The subtable `table` of kind `kind` applied at `at`.
pub fn substitute(apply: *Apply, kind: u32, table: Table, at: u32) ?u32 {
    return switch (kind) {
        SINGLE => single(apply, table, at),
        MULTIPLE => multiple(apply, table, at),
        ALTERNATE => alternate(apply, table, at),
        LIGATURE => ligature(apply, table, at),
        REVERSE => reverse(apply, table, at),
        else => null,
    };
}

/// Puts `glyph` in the place of the glyph at `at`.
fn put(apply: *Apply, at: u32, glyph: u32) void {
    const item = &apply.buffer.items[at];
    item.glyph = glyph;
    item.flags |= _buffer.ITEM_SUBSTITUTED;
    apply.gdef.classify(item, _buffer.CLASS_NONE);
}

/// One glyph for another: the glyph's number moved by a fixed amount, or
/// looked up in a list.
fn single(apply: *Apply, table: Table, at: u32) ?u32 {
    const glyph = apply.buffer.items[at].glyph;
    const index = _tables.coverage(table.partAt(2), glyph) orelse return null;
    switch (table.word(0)) {
        1 => put(apply, at, (glyph +% table.word(4)) & 0xFFFF),
        2 => {
            if (index >= table.count(4, 6, 2)) return null;
            put(apply, at, table.word(6 + index * 2));
        },
        else => return null,
    }
    return at + 1;
}

/// Several glyphs for one.
fn multiple(apply: *Apply, table: Table, at: u32) ?u32 {
    if (table.word(0) != 1) return null;
    const buffer = apply.buffer;
    const index = _tables.coverage(table.partAt(2), buffer.items[at].glyph) orelse return null;
    if (index >= table.count(4, 6, 2)) return null;
    const sequence = table.partAt(6 + index * 2);
    if (sequence.empty()) return null;
    const count = sequence.count(0, 2, 2);
    if (count == 1) {
        put(apply, at, sequence.word(2));
        return at + 1;
    }
    if (count == 0) {
        // None for one: the glyph goes, and its cluster to a neighbour.
        buffer.giveCluster(at);
        buffer.remove(&.{at});
        apply.spendStretch(buffer.len - at);
        return at;
    }
    const was_ligature = buffer.items[at].class == _buffer.CLASS_LIGATURE;
    const on_ligature = buffer.items[at].ligature != 0;
    if (!buffer.replace(at, 1, count)) return null;
    apply.spendStretch(buffer.len - at);
    for (buffer.items[at..][0..count], 0..) |*item, place| {
        // A glyph that sits on a ligature goes on sitting there.
        if (!on_ligature) {
            item.part = if (place > 0xFF) 0xFF else @intCast(place);
            item.parts = 0;
        }
        item.glyph = sequence.word(2 + @as(u32, @intCast(place)) * 2);
        item.flags |= _buffer.ITEM_SUBSTITUTED | _buffer.ITEM_MULTIPLIED;
        apply.gdef.classify(item, if (was_ligature) _buffer.CLASS_BASE else _buffer.CLASS_NONE);
    }
    return at + count;
}

/// One of a choice of glyphs for one: the feature's value says which.
fn alternate(apply: *Apply, table: Table, at: u32) ?u32 {
    if (table.word(0) != 1) return null;
    const index = _tables.coverage(table.partAt(2), apply.buffer.items[at].glyph) orelse return null;
    if (index >= table.count(4, 6, 2)) return null;
    const choice = table.partAt(6 + index * 2);
    if (apply.value == 0 or apply.value > choice.count(0, 2, 2)) return null;
    put(apply, at, choice.word(2 + (apply.value - 1) * 2));
    return at + 1;
}

/// One glyph for several: the first ligature of the glyph's set whose
/// other parts follow.
fn ligature(apply: *Apply, table: Table, at: u32) ?u32 {
    if (table.word(0) != 1) return null;
    const index = _tables.coverage(table.partAt(2), apply.buffer.items[at].glyph) orelse return null;
    if (index >= table.count(4, 6, 2)) return null;
    const set = table.partAt(6 + index * 2);
    const places = apply.placesHere();
    for (0..set.count(0, 2, 2)) |entry| {
        if (!apply.spend()) return null;
        const made = set.partAt(2 + @as(u32, @intCast(entry)) * 2);
        const parts = made.word(2);
        if (made.empty() or parts == 0) continue;
        if (parts == 1) {
            put(apply, at, made.word(0));
            return at + 1;
        }
        const rest = Sequence.init(made, 4, parts - 1);
        const matched = _match.matchInput(apply, at, rest, .{ .by = .glyph }, places) orelse continue;
        ligate(apply, places[0..parts], made.word(0), matched);
        return matched.end - (parts - 1);
    }
    return null;
}

/// Makes the glyphs at `places` the one glyph `glyph`.
fn ligate(apply: *Apply, places: []const u32, glyph: u32, matched: _match.Matched) void {
    const buffer = apply.buffer;
    const items = buffer.items;
    const first = &items[places[0]];
    // The glyphs behind move up, and clusters are gone over.
    apply.spendStretch(buffer.len - places[0]);

    // A base glyph with its marks, or marks alone, stay what they are; a
    // ligature is what is made of anything else.
    var on_base = first.class == _buffer.CLASS_BASE;
    var of_marks = first.class == _buffer.CLASS_MARK;
    for (places[1..]) |place| {
        if (items[place].class != _buffer.CLASS_MARK) {
            on_base = false;
            of_marks = false;
            break;
        }
    }
    const is_ligature = !on_base and !of_marks;
    const number: u16 = if (is_ligature) buffer.nextLigature() else 0;
    var last_ligature = first.ligature;
    var last_parts = first.partCount();
    var parts_so_far = last_parts;

    buffer.mergeClusters(places[0], matched.end);
    if (is_ligature) {
        first.ligature = number;
        first.part = 0;
        first.parts = if (matched.parts > 0xFF) 0xFF else @intCast(matched.parts);
    }
    first.glyph = glyph;
    first.flags = (first.flags | _buffer.ITEM_SUBSTITUTED | _buffer.ITEM_LIGATED) & ~_buffer.ITEM_MULTIPLIED;
    apply.gdef.classify(first, if (is_ligature) _buffer.CLASS_LIGATURE else _buffer.CLASS_NONE);

    // What stood between the parts stays, and sits on the part before it.
    for (places[1..], 0..) |place, before| {
        if (is_ligature) {
            for (items[places[before] + 1 .. place]) |*between| {
                between.ligature = number;
                between.part = partNumber(between.partOn(), parts_so_far, last_parts);
                between.parts = 0;
            }
        }
        last_ligature = items[place].ligature;
        last_parts = items[place].partCount();
        parts_so_far += last_parts;
    }
    // And what sat on the last part goes on sitting on it.
    if (!of_marks and last_ligature != 0) {
        for (items[matched.end..buffer.len]) |*behind| {
            if (behind.ligature != last_ligature or behind.partOn() == 0) break;
            behind.part = partNumber(behind.partOn(), parts_so_far, last_parts);
            behind.ligature = number;
            behind.parts = 0;
        }
    }
    buffer.remove(places[1..]);
}

/// The part of the new ligature a mark sits on, that sat on the part
/// `on` (0: the last) of a glyph of `last_parts` parts, the ligature
/// having `parts_so_far` parts up to and with that glyph.
fn partNumber(on: u32, parts_so_far: u32, last_parts: u32) u8 {
    const within = if (on == 0 or on > last_parts) last_parts else on;
    const number = parts_so_far - last_parts + within;
    return if (number > 0xFF) 0xFF else @intCast(number);
}

/// One glyph for another where what stands around it is as asked; for a
/// lookup that goes through the run from its end.
fn reverse(apply: *Apply, table: Table, at: u32) ?u32 {
    if (table.word(0) != 1 or !apply.reversing or apply.depth != 0) return null;
    const index = _tables.coverage(table.partAt(2), apply.buffer.items[at].glyph) orelse return null;
    const before = Sequence.init(table, 6, table.word(4));
    if (before.count > _match.context_limit) return null;
    const after = Sequence.init(table, before.end() + 2, table.word(before.end()));
    if (after.count > _match.context_limit) return null;
    if (index >= table.count(after.end(), after.end() + 2, 2)) return null;
    const by_coverage: _match.Matcher = .{ .by = .coverage, .table = table };
    if (!_match.matchBefore(apply, at, before, by_coverage)) return null;
    if (!_match.matchAfter(apply, at + 1, after, by_coverage)) return null;
    put(apply, at, table.word(after.end() + 2 + index * 2));
    return at + 1;
}

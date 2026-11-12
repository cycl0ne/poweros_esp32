// SPDX-License-Identifier: MIT
//! A lookup applied: to the whole run, or at one place of it.
//!
//! A lookup is a kind of work, flags, and a list of subtables; at each
//! glyph the first subtable that applies there is the one that does. `run`
//! takes a lookup through the run from its first glyph to its last, at
//! every glyph that carries the lookup's feature and that the lookup's
//! flags do not leave out - a lookup of the reverse kind from the last
//! glyph to the first. `nested` applies one at a single place, for a
//! context lookup; how deep that goes is bounded (`nesting_limit`), so
//! lookups that name each other end. And a table's work on a run is
//! counted (`Apply.spend`): each glyph a lookup comes by, each subtable
//! looked at there, each lookup applied from within one, and what the
//! subtables count of their own. When what the run has is spent, the
//! table does no more to it - so a table whose lists reach over each
//! other takes no more time than the run's length allows any table.
//!
//! An extension subtable only says where the real one is, with an offset
//! of 32 bits; it is followed here, once.

const _tables = @import("_tables.zig");
const Table = _tables.Table;
const _match = @import("_match.zig");
const Apply = _match.Apply;
const _context = @import("_context.zig");
const _gsub = @import("_gsub.zig");
const _gpos = @import("_gpos.zig");

const GSUB_CONTEXT = 5;
const GSUB_CHAINED = 6;
const GSUB_EXTENSION = 7;
const GSUB_REVERSE = 8;
const GPOS_CONTEXT = 7;
const GPOS_CHAINED = 8;
const GPOS_EXTENSION = 9;

const Lookup = struct {
    table: Table,
    kind: u32,
    flags: u32,
    mark_set: u32,
    subtables: u32,
};

/// The lookup of number `index` in the table's list.
fn find(apply: *const Apply, index: u32) ?Lookup {
    const list = apply.lookups;
    if (index >= list.count(0, 2, 2)) return null;
    const table = list.partAt(2 + index * 2);
    if (table.empty()) return null;
    const flags = table.word(2);
    return .{
        .table = table,
        .kind = table.word(0),
        .flags = flags,
        // The set's number stands after the subtables' offsets.
        .mark_set = if (flags & _match.LOOKUP_USE_MARK_SET != 0) table.word(6 + table.word(4) * 2) else 0,
        .subtables = table.count(4, 6, 2),
    };
}

/// A subtable and its kind, an extension followed.
const Subtable = struct { table: Table, kind: u32 };

fn subtable(apply: *const Apply, lookup: Lookup, index: u32) Subtable {
    const table = lookup.table.partAt(6 + index * 2);
    const extension: u32 = if (apply.kind == .substitute) GSUB_EXTENSION else GPOS_EXTENSION;
    if (lookup.kind != extension) return .{ .table = table, .kind = lookup.kind };
    if (table.word(0) != 1 or table.word(2) == extension) return .{ .table = Table.none, .kind = 0 };
    return .{ .table = table.partAtLong(4), .kind = table.word(2) };
}

/// Applies the first of `lookup`'s subtables that applies at `at`.
/// Answers the place to go on from, or null when none does.
fn applyAt(apply: *Apply, lookup: Lookup, at: u32) ?u32 {
    for (0..lookup.subtables) |index| {
        if (!apply.spend()) return null;
        const sub = subtable(apply, lookup, @intCast(index));
        if (sub.table.empty()) continue;
        const next = switch (apply.kind) {
            .substitute => switch (sub.kind) {
                GSUB_CONTEXT => _context.context(apply, sub.table, at),
                GSUB_CHAINED => _context.chained(apply, sub.table, at),
                else => _gsub.substitute(apply, sub.kind, sub.table, at),
            },
            .position => switch (sub.kind) {
                GPOS_CONTEXT => _context.context(apply, sub.table, at),
                GPOS_CHAINED => _context.chained(apply, sub.table, at),
                else => _gpos.position(apply, sub.kind, sub.table, at),
            },
        };
        if (next) |place| return place;
        if (apply.buffer.failed) return null;
    }
    return null;
}

/// Applies the lookup of number `index` at `at`, from within a lookup.
/// Whether it applied.
pub fn nested(apply: *Apply, index: u32, at: u32) bool {
    if (apply.depth + 1 >= _match.nesting_limit) return false;
    if (!apply.spend()) return false;
    const lookup = find(apply, index) orelse return false;
    const flags = apply.flags;
    const mark_set = apply.mark_set;
    apply.flags = lookup.flags;
    apply.mark_set = lookup.mark_set;
    apply.depth += 1;
    const applied = applyAt(apply, lookup, at) != null;
    apply.depth -= 1;
    apply.flags = flags;
    apply.mark_set = mark_set;
    return applied;
}

/// Whether `lookup` goes through the run from its end.
fn reverses(apply: *const Apply, lookup: Lookup) bool {
    if (apply.kind != .substitute or lookup.subtables == 0) return false;
    return subtable(apply, lookup, 0).kind == GSUB_REVERSE;
}

/// Applies the lookup of number `index` to the whole run: at every glyph
/// that has one of the bits `mask` and that the lookup sees. `value` is
/// the feature's.
pub fn run(apply: *Apply, index: u32, mask: u32, value: u32) void {
    const lookup = find(apply, index) orelse return;
    const buffer = apply.buffer;
    apply.flags = lookup.flags;
    apply.mark_set = lookup.mark_set;
    apply.mask = mask;
    apply.value = value;
    apply.depth = 0;
    apply.reversing = reverses(apply, lookup);
    if (apply.reversing) {
        var at = buffer.len;
        while (at > 0) {
            at -= 1;
            if (!apply.spend()) return;
            const item = &buffer.items[at];
            if (item.mask & mask == 0 and item.forms & apply.forms == 0) continue;
            if (apply.skips(item)) continue;
            apply.startAt(item);
            _ = applyAt(apply, lookup, at);
        }
        return;
    }
    var at: u32 = 0;
    while (at < buffer.len and !buffer.failed) {
        if (!apply.spend()) return;
        const item = &buffer.items[at];
        if ((item.mask & mask != 0 or item.forms & apply.forms != 0) and !apply.skips(item)) {
            const length = buffer.len;
            apply.startAt(item);
            if (applyAt(apply, lookup, at)) |next| {
                // The place it names, as long as that gets the run on:
                // further along, or the same place in a shorter run.
                at = if (next > at or buffer.len < length) next else at + 1;
                continue;
            }
        }
        at += 1;
    }
}

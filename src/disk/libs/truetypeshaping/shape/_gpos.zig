// SPDX-License-Identifier: MIT
//! `GPOS`'s lookups: a glyph moved or given another advance, alone or
//! for the glyph that follows it; a glyph joined to the one before it; a
//! mark set on a base glyph, on a part of a ligature, on another mark.
//!
//! Each function here is one kind of subtable applied at one place of
//! the run. It answers the place to go on from, or null when the
//! subtable does not hold for the glyph there. The kinds that name other
//! lookups are in `_context.zig`.
//!
//! A value record changes a glyph's place and advance by fixed amounts.
//! An attachment is not finished when its lookup is applied: the mark is
//! given the distance between its anchor and the anchor of the glyph it
//! sits on, and a note of which glyph that is. Across the line, the
//! mark takes in at once how far its glyph stands off the line as the
//! lookup finds it (`crossOffset`): what moves the glyph up or down
//! afterwards does not move the mark. Once every lookup has run
//! (`finish`), the notes are followed: a mark's offset takes in its
//! glyph's own along the line, and the advances that lie between the
//! two, so that it is drawn from its own place on the line as every
//! glyph is.
//!
//! Measures are the font's units. A record's number and an anchor's may
//! each name a device table. One kind of it names an item of the font's
//! store of deltas: in a variable font away from its default, what the
//! item adds at the font's place is added to the number, each delta
//! rounded by itself (`_variation.zig`). The other kinds adjust a number
//! for one size in pixels, and are not read. A record's advance down the
//! page and its device are stepped over.
//!
//! A place and an advance are added to without end by a font that is
//! made to: each sum stays at the largest number it can hold.

const _tables = @import("_tables.zig");
const Table = _tables.Table;
const _buffer = @import("_buffer.zig");
const Buffer = _buffer.Buffer;
const Item = _buffer.Item;
const _match = @import("_match.zig");
const Apply = _match.Apply;

const SINGLE = 1;
const PAIR = 2;
const CURSIVE = 3;
const MARK_TO_BASE = 4;
const MARK_TO_LIGATURE = 5;
const MARK_TO_MARK = 6;

/// A value record's parts, a bit of its format each.
const VALUE_X_PLACEMENT: u32 = 0x0001;
const VALUE_Y_PLACEMENT: u32 = 0x0002;
const VALUE_X_ADVANCE: u32 = 0x0004;
const VALUE_Y_ADVANCE: u32 = 0x0008;
const VALUE_X_PLACEMENT_DEVICE: u32 = 0x0010;
const VALUE_Y_PLACEMENT_DEVICE: u32 = 0x0020;
const VALUE_X_ADVANCE_DEVICE: u32 = 0x0040;
const VALUE_DEVICES: u32 = 0x00F0;

/// The subtable `table` of kind `kind` applied at `at`.
pub fn position(apply: *Apply, kind: u32, table: Table, at: u32) ?u32 {
    return switch (kind) {
        SINGLE => single(apply, table, at),
        PAIR => pair(apply, table, at),
        CURSIVE => cursive(apply, table, at),
        MARK_TO_BASE => markToBase(apply, table, at),
        MARK_TO_LIGATURE => markToLigature(apply, table, at),
        MARK_TO_MARK => markToMark(apply, table, at),
        else => null,
    };
}

/// How many bytes a value record of the format `format` has.
fn valueSize(format: u32) u32 {
    return @as(u32, @popCount(format & 0xFF)) * 2;
}

/// Changes `item` by the value record at `at` of `table`, which is the
/// table its device tables are found from. The record has its numbers
/// first and then a device table's place for each. The advance down the
/// page is not for a line that runs across it.
fn applyValue(apply: *Apply, item: *Item, table: Table, at: u32, format: u32) void {
    var part = at;
    if (format & VALUE_X_PLACEMENT != 0) {
        item.x_offset +|= table.signed(part);
        part += 2;
    }
    if (format & VALUE_Y_PLACEMENT != 0) {
        item.y_offset +|= table.signed(part);
        part += 2;
    }
    if (format & VALUE_X_ADVANCE != 0) {
        item.advance +|= table.signed(part);
        part += 2;
    }
    if (format & VALUE_Y_ADVANCE != 0) part += 2;
    if (format & VALUE_DEVICES == 0 or !apply.place.varied) return;
    if (format & VALUE_X_PLACEMENT_DEVICE != 0) {
        item.x_offset +|= apply.deltaOf(table.partAt(part));
        part += 2;
    }
    if (format & VALUE_Y_PLACEMENT_DEVICE != 0) {
        item.y_offset +|= apply.deltaOf(table.partAt(part));
        part += 2;
    }
    if (format & VALUE_X_ADVANCE_DEVICE != 0) {
        item.advance +|= apply.deltaOf(table.partAt(part));
    }
}

/// The item before `at` that a lookup of the flags `flags` sees, when it
/// carries the lookup's feature.
fn seenBefore(apply: *Apply, at: u32, flags: u32) ?u32 {
    const items = apply.buffer.items;
    var index = at;
    while (index > 0) {
        if (!apply.spend()) return null;
        index -= 1;
        if (apply.skipsBy(&items[index], flags)) continue;
        return if (items[index].mask & apply.mask != 0) index else null;
    }
    return null;
}

/// One glyph moved: every glyph of the coverage by the same record, or
/// each by its own.
fn single(apply: *Apply, table: Table, at: u32) ?u32 {
    const item = &apply.buffer.items[at];
    const index = _tables.coverage(table.partAt(2), item.glyph) orelse return null;
    const format = table.word(4);
    switch (table.word(0)) {
        1 => applyValue(apply, item, table, 6, format),
        2 => {
            if (index >= table.word(6)) return null;
            applyValue(apply, item, table, 8 + index * valueSize(format), format);
        },
        else => return null,
    }
    return at + 1;
}

/// A glyph and the next one the lookup sees, moved for each other: the
/// pair looked up by the second glyph in the first's list, or by the
/// classes of the two.
fn pair(apply: *Apply, table: Table, at: u32) ?u32 {
    const items = apply.buffer.items;
    const first = &items[at];
    const index = _tables.coverage(table.partAt(2), first.glyph) orelse return null;
    const second_at = apply.next(at) orelse return null;
    const second = &items[second_at];
    if (second.mask & apply.mask == 0) return null;
    const first_format = table.word(4);
    const second_format = table.word(6);
    const first_size = valueSize(first_format);
    const record_size = first_size + valueSize(second_format);
    var values: Table = undefined;
    var values_at: u32 = undefined;
    switch (table.word(0)) {
        1 => {
            if (index >= table.count(8, 10, 2)) return null;
            const set = table.partAt(10 + index * 2);
            // The second glyphs of the set, in rising order.
            var low: u32 = 0;
            var high: u32 = set.count(0, 2, 2 + record_size);
            values = set;
            values_at = while (low < high) {
                const middle = low + (high - low) / 2;
                const record = 2 + middle * (2 + record_size);
                const listed = set.word(record);
                if (listed == second.glyph) break record + 2;
                if (listed < second.glyph) low = middle + 1 else high = middle;
            } else return null;
        },
        2 => {
            const first_class = _tables.classOf(table.partAt(8), first.glyph);
            const second_class = _tables.classOf(table.partAt(10), second.glyph);
            const second_classes = table.word(14);
            if (first_class >= table.word(12) or second_class >= second_classes) return null;
            const record = 16 + (@as(u64, first_class) * second_classes + second_class) * record_size;
            if (record >= table.bytes.len) return null;
            values = table;
            values_at = @intCast(record);
        },
        else => return null,
    }
    applyValue(apply, first, values, values_at, first_format);
    applyValue(apply, second, values, values_at + first_size, second_format);
    // A second glyph that was moved is done with; one that was not may be
    // the first of the next pair.
    return if (second_format != 0) second_at + 1 else second_at;
}

/// An anchor's place in its glyph. A table of no length is the origin.
const Anchor = struct { x: i32 = 0, y: i32 = 0 };

/// The anchor `table` holds. One of the third kind has a device table
/// for each of its two numbers.
fn anchor(apply: *Apply, table: Table) Anchor {
    var point: Anchor = switch (table.word(0)) {
        1, 2, 3 => .{ .x = table.signed(2), .y = table.signed(4) },
        else => return .{},
    };
    if (table.word(0) == 3 and apply.place.varied) {
        point.x += apply.deltaOf(table.partAt(6));
        point.y += apply.deltaOf(table.partAt(8));
    }
    return point;
}

/// Where the row `row` of a table of anchors starts, each row an offset
/// for each of `classes` classes of mark, the first row at `first`. Null
/// when the table ends before it.
fn rowAt(anchors: Table, first: u32, row: u32, classes: u32) ?u32 {
    const at = first + @as(u64, row) * classes * 2;
    return if (at < anchors.bytes.len) @intCast(at) else null;
}

/// Sets the mark at `at` on the glyph at `to`: the mark's anchor, from
/// the list `marks`, on the anchor of the mark's class in the row at
/// `row` of `anchors`. Null when the glyph has no anchor for that class,
/// so that a later subtable may have one.
fn attach(apply: *Apply, at: u32, to: u32, marks: Table, mark_index: u32, anchors: Table, row: u32, classes: u32) ?u32 {
    if (mark_index >= marks.count(0, 2, 4)) return null;
    const record = 2 + mark_index * 4;
    const class = marks.word(record);
    if (class >= classes) return null;
    const target = anchors.partAt(row + class * 2);
    if (target.empty()) return null;
    const on = anchor(apply, target);
    const own = anchor(apply, marks.partAt(record + 2));
    const items = apply.buffer.slice();
    const item = &items[at];
    item.x_offset = on.x - own.x;
    item.y_offset = (on.y - own.y) +| crossOffset(items, to);
    item.attach_type = _buffer.ATTACH_MARK;
    item.attach_chain = @as(i32, @intCast(to)) - @as(i32, @intCast(at));
    return at + 1;
}

/// How far the glyph at `at` stands off the line now: its own offset,
/// and those of the glyphs it hangs on by its exit and their entries.
fn crossOffset(items: []const Item, at: u32) i32 {
    var node = at;
    var offset = items[node].y_offset;
    var steps: usize = 1;
    while (steps < items.len and items[node].attach_type == _buffer.ATTACH_CURSIVE) : (steps += 1) {
        const step = items[node].attach_chain;
        if (step == 0) break;
        const target = @as(i64, node) + step;
        if (target < 0 or target >= items.len) break;
        node = @intCast(target);
        offset +|= items[node].y_offset;
    }
    return offset;
}

/// Whether the glyph at `at` may carry a mark: of the glyphs one glyph
/// became, only the first does - unless a mark stands among them.
fn carriesMarks(items: []const Item, at: u32) bool {
    const item = &items[at];
    if (item.flags & _buffer.ITEM_MULTIPLIED == 0 or item.partOn() == 0 or at == 0) return true;
    const before = &items[at - 1];
    return before.class == _buffer.CLASS_MARK or
        before.flags & _buffer.ITEM_MULTIPLIED == 0 or
        before.ligature != item.ligature or
        before.partOn() + 1 != item.partOn();
}

/// A mark on a base glyph: the nearest glyph before it that is no mark.
fn markToBase(apply: *Apply, table: Table, at: u32) ?u32 {
    if (table.word(0) != 1) return null;
    const items = apply.buffer.slice();
    const mark_index = _tables.coverage(table.partAt(2), items[at].glyph) orelse return null;
    const bases = table.partAt(4);
    var index = at;
    const base_at = while (index > 0) {
        if (!apply.spend()) return null;
        index -= 1;
        const item = &items[index];
        if (item.class == _buffer.CLASS_MARK or item.mask & apply.mask == 0) continue;
        if (!carriesMarks(items, index) and _tables.coverage(bases, item.glyph) == null) continue;
        break index;
    } else return null;
    const base_index = _tables.coverage(bases, items[base_at].glyph) orelse return null;
    const anchors = table.partAt(10);
    const classes = table.word(6);
    if (base_index >= anchors.word(0)) return null;
    const row = rowAt(anchors, 2, base_index, classes) orelse return null;
    return attach(apply, at, base_at, table.partAt(8), mark_index, anchors, row, classes);
}

/// A mark on a ligature: on the part it stood behind before the
/// ligature was made, or on the last.
fn markToLigature(apply: *Apply, table: Table, at: u32) ?u32 {
    if (table.word(0) != 1) return null;
    const items = apply.buffer.slice();
    const mark = &items[at];
    const mark_index = _tables.coverage(table.partAt(2), mark.glyph) orelse return null;
    var index = at;
    const ligature_at = while (index > 0) {
        if (!apply.spend()) return null;
        index -= 1;
        if (items[index].class == _buffer.CLASS_MARK or items[index].mask & apply.mask == 0) continue;
        break index;
    } else return null;
    const ligature = &items[ligature_at];
    const ligature_index = _tables.coverage(table.partAt(4), ligature.glyph) orelse return null;
    const list = table.partAt(10);
    if (ligature_index >= list.count(0, 2, 2)) return null;
    const anchors = list.partAt(2 + ligature_index * 2);
    const parts = anchors.word(0);
    if (parts == 0) return null;
    var part = parts - 1;
    if (ligature.ligature != 0 and ligature.ligature == mark.ligature and mark.partOn() > 0) {
        part = (if (mark.partOn() < parts) mark.partOn() else parts) - 1;
    }
    const classes = table.word(6);
    const row = rowAt(anchors, 2, part, classes) orelse return null;
    return attach(apply, at, ligature_at, table.partAt(8), mark_index, anchors, row, classes);
}

/// A mark on the mark before it, when both sit on the same glyph - or
/// on the same part of a ligature.
fn markToMark(apply: *Apply, table: Table, at: u32) ?u32 {
    if (table.word(0) != 1) return null;
    const items = apply.buffer.slice();
    const mark = &items[at];
    const mark_index = _tables.coverage(table.partAt(2), mark.glyph) orelse return null;
    const ignored = _match.LOOKUP_IGNORE_BASES | _match.LOOKUP_IGNORE_LIGATURES | _match.LOOKUP_IGNORE_MARKS;
    const under_at = seenBefore(apply, at, apply.flags & ~ignored) orelse return null;
    const under = &items[under_at];
    if (under.class != _buffer.CLASS_MARK) return null;
    if (mark.ligature == under.ligature) {
        if (mark.ligature != 0 and mark.partOn() != under.partOn()) return null;
    } else {
        // Unless one of the two is itself a ligature of marks.
        const mark_made = mark.ligature != 0 and mark.partOn() == 0;
        const under_made = under.ligature != 0 and under.partOn() == 0;
        if (!mark_made and !under_made) return null;
    }
    const under_index = _tables.coverage(table.partAt(4), under.glyph) orelse return null;
    const anchors = table.partAt(10);
    const classes = table.word(6);
    if (under_index >= anchors.word(0)) return null;
    const row = rowAt(anchors, 2, under_index, classes) orelse return null;
    return attach(apply, at, under_at, table.partAt(8), mark_index, anchors, row, classes);
}

/// A glyph joined to the one before it: the earlier one's exit anchor
/// and this one's entry anchor come to lie on each other. Along the line
/// that is done with the advances; across it, one of the two follows the
/// other - the earlier the later, or with the lookup's flag for it the
/// later the earlier.
fn cursive(apply: *Apply, table: Table, at: u32) ?u32 {
    if (table.word(0) != 1) return null;
    const items = apply.buffer.slice();
    const records = table.count(4, 6, 4);
    const index = _tables.coverage(table.partAt(2), items[at].glyph) orelse return null;
    if (index >= records) return null;
    const entry_table = table.partAt(6 + index * 4);
    if (entry_table.empty()) return null;
    const earlier_at = seenBefore(apply, at, apply.flags) orelse return null;
    const earlier_index = _tables.coverage(table.partAt(2), items[earlier_at].glyph) orelse return null;
    if (earlier_index >= records) return null;
    const exit_table = table.partAt(6 + earlier_index * 4 + 2);
    if (exit_table.empty()) return null;
    const entry = anchor(apply, entry_table);
    const exit = anchor(apply, exit_table);
    const earlier = &items[earlier_at];
    const current = &items[at];

    if (apply.backward) {
        const shift = exit.x +| earlier.x_offset;
        earlier.advance -|= shift;
        earlier.x_offset -|= shift;
        current.advance = entry.x +| current.x_offset;
    } else {
        earlier.advance = exit.x +| earlier.x_offset;
        const shift = entry.x +| current.x_offset;
        current.advance -|= shift;
        current.x_offset -|= shift;
    }

    var child = earlier_at;
    var parent = at;
    var y_offset = entry.y - exit.y;
    if (apply.flags & _match.LOOKUP_RIGHT_TO_LEFT == 0) {
        child = at;
        parent = earlier_at;
        y_offset = 0 -| y_offset;
    }
    // A child that followed another glyph already: that chain is turned
    // around, so all of it now follows the new parent.
    turnChain(apply.buffer, child, parent);
    items[child].attach_type = _buffer.ATTACH_CURSIVE;
    items[child].attach_chain = @as(i32, @intCast(parent)) - @as(i32, @intCast(child));
    items[child].y_offset = y_offset;
    // Two glyphs do not follow each other.
    if (items[parent].attach_chain == -items[child].attach_chain) {
        items[parent].attach_chain = 0;
        items[parent].y_offset = 0;
    }
    return at + 1;
}

/// Turns around the chain of joined glyphs that starts at `start`: each
/// glyph on it follows the one that followed it, up to `new_parent`.
fn turnChain(buffer: *Buffer, start: u32, new_parent: u32) void {
    const items = buffer.slice();
    var chain = items[start].attach_chain;
    var kind = items[start].attach_type;
    var y_offset = items[start].y_offset;
    if (chain == 0 or kind != _buffer.ATTACH_CURSIVE) return;
    items[start].attach_chain = 0;
    var node = start;
    for (0..items.len) |_| {
        const target = @as(i64, node) + chain;
        if (target < 0 or target >= items.len) return;
        const next: u32 = @intCast(target);
        if (next == new_parent) return;
        const next_chain = items[next].attach_chain;
        const next_kind = items[next].attach_type;
        const next_offset = items[next].y_offset;
        items[next].y_offset = 0 -| y_offset;
        items[next].attach_chain = -chain;
        items[next].attach_type = kind;
        if (next_chain == 0 or next_kind != _buffer.ATTACH_CURSIVE) return;
        node = next;
        chain = next_chain;
        kind = next_kind;
        y_offset = next_offset;
    }
}

/// How long a chain of attachments is followed.
const chain_limit = 64;

/// Once every lookup has run: a glyph attached by its exit takes in how
/// far the glyph it hangs on stands off the line, a mark its glyph's
/// offset along the line and the advances between the two. `backward`
/// says the run is read from right to left, where a mark is drawn
/// before its glyph.
pub fn finish(buffer: *Buffer, backward: bool) void {
    const items = buffer.slice();
    for (0..items.len) |start| {
        // The chain from this glyph to the one nothing is attached
        // beyond, then back along it, the far end first.
        var chain: [chain_limit]u32 = undefined;
        var length: usize = 0;
        var node: u32 = @intCast(start);
        while (length < chain_limit) {
            const step = items[node].attach_chain;
            if (step == 0) break;
            items[node].attach_chain = 0;
            const target = @as(i64, node) + step;
            if (target < 0 or target >= items.len) break;
            chain[length] = node;
            length += 1;
            node = @intCast(target);
        }
        var parent = node;
        while (length > 0) {
            length -= 1;
            const child = chain[length];
            settle(items, child, parent, backward);
            parent = child;
        }
    }
}

/// Adds to the glyph at `child` what the glyph at `parent` it is
/// attached to says of its place.
fn settle(items: []Item, child: u32, parent: u32, backward: bool) void {
    const item = &items[child];
    if (item.attach_type == _buffer.ATTACH_CURSIVE) {
        item.y_offset +|= items[parent].y_offset;
        return;
    }
    item.x_offset +|= items[parent].x_offset;
    if (parent >= child) return;
    if (backward) {
        for (items[parent + 1 .. child + 1]) |between| item.x_offset +|= between.advance;
    } else {
        for (items[parent..child]) |between| item.x_offset -|= between.advance;
    }
}

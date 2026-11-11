// SPDX-License-Identifier: MIT
//! What a lookup sees of the run, and how a sequence of glyphs is found
//! in it.
//!
//! `Apply` is one table's work on a buffer: the lookup being applied, its
//! flags and the features' bits it holds for, and how much work the
//! table has left (`spend`). A lookup does not see every glyph: its
//! flags leave out the base glyphs, the ligatures or the marks, or the
//! marks of all classes but one, or the marks outside a set (`skips`).
//! `next` and `prev` step over what it does not see.
//!
//! A sequence a lookup asks for is matched glyph by glyph against what
//! it does see (`matchInput`), by glyph number, by class or by coverage
//! (`Matcher`); what stands before it (`matchBefore`) and after it
//! (`matchAfter`) likewise. The glyphs of the sequence itself must carry
//! the lookup's feature; those around it need not.
//!
//! Parts of a ligature made earlier are matched with care: marks that sit
//! on different parts of one ligature do not form a sequence together,
//! and a mark that sits on a ligature forms none with a glyph that does
//! not - unless the lookup does not see the ligature at all.

const _tables = @import("_tables.zig");
const Table = _tables.Table;
const _buffer = @import("_buffer.zig");
const Buffer = _buffer.Buffer;
const Item = _buffer.Item;
const Gdef = @import("_gdef.zig").Gdef;

/// A lookup's flags.
pub const LOOKUP_RIGHT_TO_LEFT: u32 = 0x0001;
pub const LOOKUP_IGNORE_BASES: u32 = 0x0002;
pub const LOOKUP_IGNORE_LIGATURES: u32 = 0x0004;
pub const LOOKUP_IGNORE_MARKS: u32 = 0x0008;
pub const LOOKUP_USE_MARK_SET: u32 = 0x0010;
pub const LOOKUP_MARK_CLASS: u32 = 0xFF00;

/// The longest sequence a lookup may ask for, and how deep lookups may
/// call each other.
pub const context_limit = 64;
pub const nesting_limit = 8;

/// Every feature's bit: what a glyph around a sequence is asked for.
pub const any_feature: u32 = 0xFFFF_FFFF;

pub const Kind = enum { substitute, position };

/// One table's work on a buffer.
pub const Apply = struct {
    buffer: *Buffer,
    gdef: *const Gdef,
    kind: Kind,
    /// The table's list of lookups.
    lookups: Table,
    /// Whether the run is read from right to left.
    backward: bool,
    /// `nesting_limit` times `context_limit` places, for the sequences
    /// matched at each depth.
    places: [*]u32,
    /// How much more work the table may do on the run: see `spend`.
    work: u32,
    /// The lookup being applied: its flags, its set of marks, the
    /// features' bits it holds for, and the feature's value.
    flags: u32 = 0,
    mark_set: u32 = 0,
    mask: u32 = 0,
    value: u32 = 1,
    depth: u32 = 0,
    /// Whether the lookup goes through the run from its end.
    reversing: bool = false,

    /// Takes one piece of work off what the table has left for the run.
    /// A piece is a glyph a lookup comes by, a subtable looked at for
    /// one, a rule or a ligature of a set tried, a glyph compared with
    /// what a sequence says of it or stepped over on the way, a record
    /// of a rule that matched, a lookup applied from within one. False
    /// when none is left; the table's work on the run ends there.
    pub fn spend(apply: *Apply) bool {
        if (apply.work == 0) return false;
        apply.work -= 1;
        return true;
    }

    /// Takes off what a stretch of `glyphs` glyphs costs that is moved or
    /// gone over in one go: a piece for every 16 of them.
    pub fn spendStretch(apply: *Apply, glyphs: u32) void {
        apply.work -= @min(apply.work, glyphs / 16);
    }

    /// Whether the lookup does not see `item`.
    pub fn skips(apply: *const Apply, item: *const Item) bool {
        return skipsBy(apply, item, apply.flags);
    }

    /// The same for a lookup of the flags `flags`.
    pub fn skipsBy(apply: *const Apply, item: *const Item, flags: u32) bool {
        switch (item.class) {
            _buffer.CLASS_BASE => return flags & LOOKUP_IGNORE_BASES != 0,
            _buffer.CLASS_LIGATURE => return flags & LOOKUP_IGNORE_LIGATURES != 0,
            _buffer.CLASS_MARK => {
                if (flags & LOOKUP_IGNORE_MARKS != 0) return true;
                if (flags & LOOKUP_USE_MARK_SET != 0) return !apply.gdef.inMarkSet(apply.mark_set, item.glyph);
                if (flags & LOOKUP_MARK_CLASS != 0) return (flags >> 8) != item.mark_class;
                return false;
            },
            else => return false,
        }
    }

    /// The next item after `at` the lookup sees; null at the run's end,
    /// and when the table's work is spent on the way.
    pub fn next(apply: *Apply, at: u32) ?u32 {
        var index = at +% 1;
        while (index < apply.buffer.len) : (index += 1) {
            if (!apply.skips(&apply.buffer.items[index])) return index;
            if (!apply.spend()) return null;
        }
        return null;
    }

    /// The item before `at` the lookup sees; null at the run's start,
    /// and when the table's work is spent on the way.
    pub fn prev(apply: *Apply, at: u32) ?u32 {
        var index = at;
        while (index > 0) {
            index -= 1;
            if (!apply.skips(&apply.buffer.items[index])) return index;
            if (!apply.spend()) return null;
        }
        return null;
    }

    /// Where the places of a sequence matched at this depth are kept.
    pub fn placesHere(apply: *const Apply) *[context_limit]u32 {
        return (apply.places + apply.depth * context_limit)[0..context_limit];
    }
};

/// How a glyph is compared with what a sequence says of it.
pub const Matcher = struct {
    by: enum { glyph, class, coverage },
    /// The class definition, or the table the coverages' offsets are in.
    table: Table = Table.none,

    pub fn matches(matcher: Matcher, glyph: u32, said: u32) bool {
        return switch (matcher.by) {
            .glyph => glyph == said,
            .class => _tables.classOf(matcher.table, glyph) == said,
            .coverage => _tables.coverage(matcher.table.part(said), glyph) != null,
        };
    }
};

/// A list of 16-bit numbers in a table, its count cut to the table.
pub const Sequence = struct {
    table: Table = Table.none,
    at: u32 = 0,
    count: u32 = 0,

    /// The list of `said` numbers at `at`. Its place is kept whatever the
    /// table holds there, so that what follows the list is looked for
    /// behind it.
    pub fn init(table: Table, at: u32, said: u32) Sequence {
        const room: u32 = if (at >= table.bytes.len) 0 else @intCast((table.bytes.len - at) / 2);
        // A list cut short is one that does not match: its count is kept
        // out of reach rather than shortened.
        return .{ .table = table, .at = at, .count = if (said > room) context_limit + 1 else said };
    }

    pub fn get(sequence: Sequence, index: u32) u32 {
        return sequence.table.word(sequence.at + index * 2);
    }

    /// Where the list ends.
    pub fn end(sequence: Sequence) u32 {
        return sequence.at + sequence.count * 2;
    }
};

pub const Matched = struct {
    /// The place after the sequence's last glyph.
    end: u32,
    /// How many parts a ligature made of the sequence has.
    parts: u32,
};

/// Matches the glyph at `at` and, after it, the glyphs `rest` asks for.
/// The places of all of them go to `places`. Null when they are not
/// there.
pub fn matchInput(apply: *Apply, at: u32, rest: Sequence, matcher: Matcher, places: *[context_limit]u32) ?Matched {
    if (rest.count >= context_limit) return null;
    const items = apply.buffer.slice();
    const first = &items[at];
    const first_ligature = first.ligature;
    const first_part = first.partOn();
    var base_checked = false;
    var base_unseen = false;
    var parts: u32 = first.partCount();
    var index = at;
    places[0] = at;
    for (0..rest.count) |step| {
        if (!apply.spend()) return null;
        index = apply.next(index) orelse return null;
        const item = &items[index];
        if (item.mask & apply.mask == 0) return null;
        if (!matcher.matches(item.glyph, rest.get(@intCast(step)))) return null;
        places[step + 1] = index;
        if (first_ligature != 0 and first_part != 0) {
            // The first sits on a part of a ligature: the others must sit
            // on the same part, unless the lookup does not see the
            // ligature.
            if (item.ligature != first_ligature or item.partOn() != first_part) {
                if (!base_checked) {
                    base_checked = true;
                    var back = at;
                    while (back > 0 and items[back - 1].ligature == first_ligature) {
                        if (!apply.spend()) return null;
                        back -= 1;
                        if (items[back].partOn() == 0) {
                            base_unseen = apply.skips(&items[back]);
                            break;
                        }
                    }
                }
                if (!base_unseen) return null;
            }
        } else if (item.ligature != 0 and item.partOn() != 0 and item.ligature != first_ligature) {
            // The first sits on none: neither may the others, except on
            // the first itself.
            return null;
        }
        parts += item.partCount();
    }
    return .{ .end = index + 1, .parts = parts };
}

/// Whether the glyphs `before` asks for stand before `at`, the nearest
/// first.
pub fn matchBefore(apply: *Apply, at: u32, before: Sequence, matcher: Matcher) bool {
    if (before.count > context_limit) return false;
    var index = at;
    for (0..before.count) |step| {
        if (!apply.spend()) return false;
        index = apply.prev(index) orelse return false;
        if (!matcher.matches(apply.buffer.items[index].glyph, before.get(@intCast(step)))) return false;
    }
    return true;
}

/// Whether the glyphs `after` asks for stand from `end` on.
pub fn matchAfter(apply: *Apply, end: u32, after: Sequence, matcher: Matcher) bool {
    if (after.count > context_limit) return false;
    var index = end -% 1;
    for (0..after.count) |step| {
        if (!apply.spend()) return false;
        index = apply.next(index) orelse return false;
        if (!matcher.matches(apply.buffer.items[index].glyph, after.get(@intCast(step)))) return false;
    }
    return true;
}

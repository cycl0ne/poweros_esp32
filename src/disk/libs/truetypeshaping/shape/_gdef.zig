// SPDX-License-Identifier: MIT
//! `GDEF`: what kind of glyph each of a font's glyphs is.
//!
//! The table sorts the glyphs into base glyphs, ligatures, marks and
//! components; the marks into classes of their own, by where they attach;
//! and, from its version 1.2 on, lists sets of marks by number. A lookup's
//! flags leave glyphs out by these: every mark, every mark but one class,
//! every mark outside one set. From its version 1.3 on it holds the
//! store of deltas a variable font's layout tables vary their numbers
//! by (`_variation.zig`). A font without the table, or one of a version
//! this does not know, has glyphs of no kind, no sets and no store.

const _tables = @import("_tables.zig");
const Table = _tables.Table;
const _buffer = @import("_buffer.zig");
const Item = _buffer.Item;

pub const Gdef = struct {
    classes: Table = Table.none,
    mark_classes: Table = Table.none,
    mark_sets: Table = Table.none,
    /// The store of deltas for the layout tables' numbers.
    store: Table = Table.none,

    /// What `table` holds; nothing for a table of no length.
    pub fn init(table: Table) Gdef {
        if (table.word(0) != 1) return .{};
        var gdef: Gdef = .{
            .classes = table.partAt(4),
            .mark_classes = table.partAt(10),
        };
        if (table.word(2) >= 2) {
            const sets = table.partAt(12);
            if (sets.word(0) == 1) gdef.mark_sets = sets;
        }
        if (table.word(2) >= 3) gdef.store = table.partAtLong(14);
        return gdef;
    }

    /// Sets what kind of glyph `item` is from its glyph. Where the font
    /// does not sort its glyphs, it is of the kind `guess` - what the
    /// lookup that made it says it made - unless that is `CLASS_NONE`,
    /// which leaves it as it was.
    pub fn classify(gdef: *const Gdef, item: *Item, guess: u8) void {
        if (gdef.classes.empty()) {
            if (guess != _buffer.CLASS_NONE) item.class = guess;
            return;
        }
        const class = _tables.classOf(gdef.classes, item.glyph);
        item.class = if (class > _buffer.CLASS_COMPONENT) _buffer.CLASS_NONE else @intCast(class);
        item.mark_class = 0;
        if (item.class == _buffer.CLASS_MARK) {
            const mark_class = _tables.classOf(gdef.mark_classes, item.glyph);
            item.mark_class = if (mark_class > 0xFF) 0 else @intCast(mark_class);
        }
    }

    /// Whether `glyph` is in the set of marks of number `set`.
    pub fn inMarkSet(gdef: *const Gdef, set: u32, glyph: u32) bool {
        const sets = gdef.mark_sets;
        if (set >= sets.count(2, 4, 4)) return false;
        return _tables.coverage(sets.partAtLong(4 + set * 4), glyph) != null;
    }
};

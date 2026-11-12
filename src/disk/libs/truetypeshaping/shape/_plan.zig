// SPDX-License-Identifier: MIT
//! Which of a table's lookups a call applies, and in what order.
//!
//! `GSUB` and `GPOS` are laid out alike: a list of scripts, each with its
//! languages; for each language the features it has; for each feature
//! the lookups that do its work; and the lookups themselves. `Layout`
//! finds the language's list for a script and a language asked for: the
//! script itself, or else its other tag where it has two, or else
//! `DFLT`, `dflt`, `latn`; the language itself, or else the one tagged
//! `dflt`, or else the script's default.
//!
//! `collect` turns the features asked for into the lookups to apply. The
//! language's required feature comes first and holds for every glyph -
//! where the call asks for it: a table applied in two goes has it in
//! the first - and of the others, the language's first feature of each
//! tag asked for.
//! `arrange` puts them in the order the table lists its lookups in -
//! which is the order they are applied in, whatever the order of the
//! features - and makes one of a lookup named twice.
//!
//! A script's model (`_indic.zig`) says more of a feature, and its
//! lookups carry it: the go through `GSUB` they belong to
//! (`Wanted.go`), the forms whose items they hold for besides the
//! feature's bit, whether their sequences stay within a syllable, and
//! whether the joiners are the model's to deal with. `wouldReplace`
//! answers what the model asks of the font: whether a feature has a
//! rule for a few glyphs standing by themselves (`_would.zig`).
//!
//! A table of version 1.1 may replace features under conditions on a
//! variable font's axes. The conditions are judged at the font's place
//! on its axes, a coordinate an axis; an axis the place does not say is
//! at 0, where a font at its default has all of them. No more than
//! `condition_limit` of them are looked at: past that, no feature is
//! replaced.

const _tables = @import("_tables.zig");
const Table = _tables.Table;
const _would = @import("_would.zig");

fn tag(comptime letters: *const [4]u8) u32 {
    return (@as(u32, letters[0]) << 24) | (@as(u32, letters[1]) << 16) | (@as(u32, letters[2]) << 8) | letters[3];
}

/// The bit of a glyph's mask every glyph has: features that hold for the
/// whole run share it.
pub const whole_run: u32 = 1;

/// A feature asked for: its tag, the bit the glyphs it holds for carry,
/// and its value.
pub const Wanted = struct {
    tag: u32,
    mask: u32,
    value: u32,
    /// The forms of a script's model it holds for besides
    /// (`Item.forms`).
    forms: u8 = 0,
    /// Which of the model's goes through `GSUB` its lookups are
    /// applied in.
    go: u8 = 0,
    /// Its lookups' sequences stay within a syllable.
    per_syllable: bool = false,
    /// The joiners are the model's to deal with (`Apply.by_hand`).
    by_hand: bool = false,
};

/// A lookup to apply: its number in the table's list, the bits of the
/// glyphs it holds for, and its feature's value.
pub const Entry = struct {
    lookup: u32,
    mask: u32,
    value: u32,
    /// Its place among the lookups collected, which keeps the order of
    /// two entries for one lookup.
    order: u32,
    forms: u8 = 0,
    per_syllable: bool = false,
    by_hand: bool = false,
};

const no_feature = 0xFFFF;

/// The most lookups a call collects from one table.
const entry_limit = 0x0010_0000;

/// The most conditions looked at for one table. Records may share one
/// set of conditions, and each record goes through it again.
const condition_limit = 0x0001_0000;

pub const Layout = struct {
    features: Table = Table.none,
    lookups: Table = Table.none,
    /// The language's table: its required feature and its features.
    language: Table = Table.none,
    /// The features replaced for this font, if any.
    replaced: Table = Table.none,
    /// The tag of the script the table is read for; 0 where it has none
    /// of those tried.
    script: u32 = 0,

    /// What `table` - a `GSUB` or a `GPOS` - has for `script`, or else
    /// for `other_script`, and `language`, for a font at the place
    /// `coords` on its axes; nothing for a table of no length or of a
    /// version not known here.
    pub fn init(table: Table, script: u32, other_script: u32, language: u32, coords: []const i16) Layout {
        if (table.word(0) != 1) return .{};
        var layout: Layout = .{
            .features = table.partAt(6),
            .lookups = table.partAt(8),
        };
        const scripts = table.partAt(4);
        var chosen = Table.none;
        for ([_]u32{ script, other_script, tag("DFLT"), tag("dflt"), tag("latn") }) |tried| {
            chosen = findTagged(scripts, 0, tried) orelse continue;
            layout.script = tried;
            break;
        }
        if (!chosen.empty()) {
            layout.language = findTagged(chosen, 2, language) orelse
                findTagged(chosen, 2, tag("dflt")) orelse chosen.partAt(0);
        }
        if (table.word(2) >= 1) layout.replaced = replacedFeatures(table.partAtLong(10), coords);
        return layout;
    }

    /// The table of the feature of number `index`.
    fn feature(layout: *const Layout, index: u32) Table {
        const replaced = layout.replaced;
        for (0..replaced.count(4, 6, 6)) |entry| {
            const record = 6 + @as(u32, @intCast(entry)) * 6;
            if (replaced.word(record) == index) return replaced.partAtLong(record + 2);
        }
        if (index >= layout.features.count(0, 2, 6)) return Table.none;
        return layout.features.partAt(2 + index * 6 + 4);
    }

    /// The number of the language's first feature tagged `wanted`.
    fn findFeature(layout: *const Layout, wanted: u32) ?u32 {
        const language = layout.language;
        const count = layout.features.count(0, 2, 6);
        for (0..language.count(4, 6, 2)) |entry| {
            const index = language.word(6 + @as(u32, @intCast(entry)) * 2);
            if (index < count and layout.features.long(2 + index * 6) == wanted) return index;
        }
        return null;
    }

    /// Whether the language has a feature tagged `wanted`.
    pub fn has(layout: *const Layout, wanted: u32) bool {
        return layout.findFeature(wanted) != null;
    }

    /// The lookups of the features `wanted` - before them, with
    /// `required`, those of the feature the language requires - written
    /// to `entries` in the order found. Answers how many there are -
    /// which may be more than `entries` holds, and nothing is written
    /// past it.
    pub fn collect(layout: *const Layout, wanted: []const Wanted, required: bool, entries: []Entry) u32 {
        var count: u32 = 0;
        if (layout.language.empty()) return 0;
        const needed = layout.language.word(2);
        if (required and needed != no_feature) layout.add(needed, whole_run, 1, entries, &count);
        for (wanted) |feature_wanted| {
            if (feature_wanted.value == 0) continue;
            const index = layout.findFeature(feature_wanted.tag) orelse continue;
            const first = count;
            layout.add(index, feature_wanted.mask, feature_wanted.value, entries, &count);
            var added = first;
            while (added < count and added < entries.len) : (added += 1) {
                entries[added].forms = feature_wanted.forms;
                entries[added].per_syllable = feature_wanted.per_syllable;
                entries[added].by_hand = feature_wanted.by_hand;
            }
        }
        return count;
    }

    /// Whether a lookup of the feature `wanted` has a rule for exactly
    /// `glyphs` (`_would.zig`).
    pub fn wouldReplace(layout: *const Layout, wanted: u32, glyphs: []const u32, alone: bool) bool {
        const table = layout.feature(layout.findFeature(wanted) orelse return false);
        const listed = layout.lookups.count(0, 2, 2);
        for (0..table.count(2, 4, 2)) |entry| {
            const lookup = table.word(4 + @as(u32, @intCast(entry)) * 2);
            if (lookup >= listed) continue;
            if (_would.wouldReplace(layout.lookups, lookup, glyphs, alone)) return true;
        }
        return false;
    }

    fn add(layout: *const Layout, index: u32, mask: u32, value: u32, entries: []Entry, count: *u32) void {
        const table = layout.feature(index);
        const listed = layout.lookups.count(0, 2, 2);
        for (0..table.count(2, 4, 2)) |entry| {
            const lookup = table.word(4 + @as(u32, @intCast(entry)) * 2);
            if (lookup >= listed) continue;
            if (count.* >= entry_limit) return;
            if (count.* < entries.len) {
                entries[count.*] = .{ .lookup = lookup, .mask = mask, .value = value, .order = count.* };
            }
            count.* += 1;
        }
    }
};

/// The table a list of tagged records has for `wanted`: the list's
/// count is at `at`, each record a tag and an offset. Null when `wanted`
/// is 0 or not listed.
fn findTagged(list: Table, at: u32, wanted: u32) ?Table {
    if (wanted == 0) return null;
    for (0..list.count(at, at + 2, 6)) |entry| {
        const record = at + 2 + @as(u32, @intCast(entry)) * 6;
        if (list.long(record) != wanted) continue;
        const found = list.partAt(record + 4);
        return if (found.empty()) null else found;
    }
    return null;
}

/// The replaced features of the first of `variations`' records whose
/// conditions all hold for a font at the place `coords`.
fn replacedFeatures(variations: Table, coords: []const i16) Table {
    if (variations.word(0) != 1 or variations.bytes.len < 8) return Table.none;
    const room: u32 = @intCast((variations.bytes.len - 8) / 8);
    const said = variations.long(4);
    var left: u32 = condition_limit;
    for (0..if (said < room) said else room) |entry| {
        if (left == 0) break;
        const record = 8 + @as(u32, @intCast(entry)) * 8;
        if (!conditionsHold(variations.partAtLong(record), coords, &left)) continue;
        const replaced = variations.partAtLong(record + 4);
        return if (replaced.word(0) == 1) replaced else Table.none;
    }
    return Table.none;
}

/// Whether each condition of the set holds: an axis's coordinate - the
/// one `coords` has for it, 0 for an axis past them - within a range,
/// its ends included. A condition of another kind does not hold. A set
/// of no length has none, and holds. `left` is how many conditions may
/// still be looked at; a set that needs more does not hold.
fn conditionsHold(set: Table, coords: []const i16, left: *u32) bool {
    for (0..set.count(0, 2, 4)) |entry| {
        if (left.* == 0) return false;
        left.* -= 1;
        const condition = set.partAtLong(2 + @as(u32, @intCast(entry)) * 4);
        if (condition.word(0) != 1) return false;
        const axis = condition.word(2);
        const coord: i32 = if (axis < coords.len) coords[axis] else 0;
        if (condition.signed(4) > coord or condition.signed(6) < coord) return false;
    }
    return true;
}

fn before(left: Entry, right: Entry) bool {
    return if (left.lookup != right.lookup) left.lookup < right.lookup else left.order < right.order;
}

/// Sorts `entries` by lookup, keeping the order of those for one lookup,
/// and makes one entry of those for one lookup with one value: it holds
/// for all they hold for, leaves the joiners to the model where one of
/// them does, and stays in a syllable where the first does. Answers how
/// many are left.
pub fn arrange(entries: []Entry) u32 {
    // A heap sort: the largest to the end, one after the other.
    var start = entries.len / 2;
    while (start > 0) {
        start -= 1;
        sift(entries, start, entries.len);
    }
    var end = entries.len;
    while (end > 1) {
        end -= 1;
        const largest = entries[0];
        entries[0] = entries[end];
        entries[end] = largest;
        sift(entries, 0, end);
    }
    var kept: u32 = 0;
    for (entries) |entry| {
        if (kept > 0 and entries[kept - 1].lookup == entry.lookup and entries[kept - 1].value == entry.value) {
            entries[kept - 1].mask |= entry.mask;
            entries[kept - 1].forms |= entry.forms;
            if (entry.by_hand) entries[kept - 1].by_hand = true;
            continue;
        }
        entries[kept] = entry;
        kept += 1;
    }
    return kept;
}

fn sift(entries: []Entry, from: usize, end: usize) void {
    var root = from;
    while (true) {
        var child = root * 2 + 1;
        if (child >= end) return;
        if (child + 1 < end and before(entries[child], entries[child + 1])) child += 1;
        if (!before(entries[root], entries[child])) return;
        const moved = entries[root];
        entries[root] = entries[child];
        entries[child] = moved;
        root = child;
    }
}

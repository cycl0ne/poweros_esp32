// SPDX-License-Identifier: MIT
//! A stretch of text made the characters a font draws it with, before
//! the font's tables see a glyph: characters taken apart, their marks
//! put in order, and put together again.
//!
//! A text spells one letter in several ways - `é` as one character, or
//! as `e` with an acute behind it - and a font has a glyph for some of
//! the spellings; its lookups expect the marks of a letter in one
//! order. `List.fill` rewrites a stretch in three rounds, and what is
//! left is the stretch's characters, each with the glyph it is drawn
//! by and the place in the text it stands for.
//!
//! Round 1, apart. A character with no mark behind it stays as it is
//! where the font has a glyph for it. Where it has none, the character
//! becomes its parts, a step of the table at a time, as soon as the
//! font has all of them: the shortest form. A character with marks
//! behind it, and each of those marks, is taken apart as far as the
//! font has the parts, so that its own marks get in order with the
//! ones behind it: the longest form. A character the font has no form
//! of stays whole, with glyph 0. Every part has its character's
//! cluster.
//!
//! Two kinds of character get a glyph the font has for another one. A
//! space of a set width (U+2000 to U+200A, U+202F, U+205F, U+3000, and
//! the no-break space) is the font's space, and `spaceAdvance` gives it
//! its width once the glyphs have their advances. The non-breaking
//! hyphen (U+2011) is the hyphen (U+2010).
//!
//! A character with a variation selector among the marks behind it is
//! left as it is, and so are its marks: the glyph the font has for the
//! character and the selector stands for both.
//!
//! Round 2, in order. A run of marks - up to 32 of them - is sorted by
//! the marks' order (`orderOf`), those of one order staying as they
//! were. A mark that moves forward and the ones it passes all get the
//! lowest of their clusters.
//!
//! The combining grapheme joiner (U+034F) has the order 0, so it ends a
//! run and the marks on its two sides are not sorted across it. Where
//! it kept two marks apart that way, a lookup's sequence does not step
//! over it (`hidden`); every other one is stepped over.
//!
//! Round 3, together. A mark and the last character of order 0 before
//! it become the one character the table has for the two, where the
//! font has a glyph for that one and nothing stands between the two
//! that has the mark's order or a higher one. The syllables of Hangul
//! are taken apart and never put together: a single jamo is no mark.
//!
//! A stretch in which no character has a mark behind it is done after
//! round 1: what a character was taken apart into stays in the table's
//! order.
//!
//! A stretch of a script with a model of its own (`List.model`) reads
//! each character by its parts: one is taken apart also where the font
//! has a glyph for it, and nothing is put together with a mark.

const sdk = @import("sdk");
const utf8 = sdk.utility.utf8;
const unicode = sdk.utility.unicode;
const _buffer = @import("_buffer.zig");
const Memory = _buffer.Memory;
const Font = @import("_shape.zig").Font;
const _scripts = @import("_scripts.zig");
const _table = @import("_normal_table.zig");

/// The widths a space is given where the font lacks its glyph: none; an
/// em divided by the number (1 to 6, 16); four eighteenths of an em; the
/// font's space as it is; a digit's width; a full stop's; half the
/// font's space.
pub const space_none = 0;
const space_sixteenth = 16;
const space_four_eighteenths = 17;
const space_plain = 18;
const space_figure = 19;
const space_punctuation = 20;
const space_narrow = 21;

/// The longest run of marks that is sorted.
const longest_run = 32;

const joiner = 0x034F;
const blank = 0x0020;
const hyphen = 0x2010;
const hard_hyphen = 0x2011;

/// Hangul's syllables: where they, the leading consonants, the vowels
/// and the trailing consonants start, and how many of each there are.
const syllable_base = 0xAC00;
const leading_base = 0x1100;
const vowel_base = 0x1161;
const trailing_base = 0x11A7;
const trailing_count = 28;
const vowel_span = 21 * trailing_count;
const syllable_count = 19 * vowel_span;

/// The order of Hebrew's marks, by their combining classes 10 to 26, and
/// of Arabic's, by 27 to 35.
const hebrew = [17]u8{ 22, 15, 16, 17, 23, 18, 19, 20, 21, 14, 24, 12, 25, 13, 10, 11, 26 };
const arabic = [9]u8{ 28, 29, 30, 31, 32, 33, 27, 34, 35 };

/// Whether `char` is a mark: a character that goes with the one before
/// it.
fn isMark(char: u32) bool {
    return char >= 0x0300 and unicode.class(char) == .mark;
}

/// The combining class Unicode gives `char`.
pub fn combiningOf(char: u32) u8 {
    const starts = &_table.starts;
    // The last entry that starts at or before the character; the first
    // starts at 0.
    var low: usize = 0;
    var high: usize = starts.len;
    while (high - low > 1) {
        const middle = low + (high - low) / 2;
        if (starts[middle] >> 8 <= char) low = middle else high = middle;
    }
    return @truncate(starts[low]);
}

/// The order the mark `char` is sorted by: its combining class, but for
/// the marks of a few scripts. A font's lookups for Hebrew and Arabic
/// take the points and the vowel signs in the order they are written
/// in, which their classes do not give; and a few marks of Telugu, Thai
/// and Tibetan go before or behind the ones their classes put them
/// with.
pub fn orderOf(char: u32) u8 {
    switch (char) {
        0x1A60, 0x0FC6 => return 254,
        0x0F39 => return 127,
        else => {},
    }
    const combining = combiningOf(char);
    return switch (combining) {
        10...26 => hebrew[combining - 10],
        27...35 => arabic[combining - 27],
        84 => 4,
        91 => 5,
        103 => 3,
        130 => 132,
        132 => 131,
        else => combining,
    };
}

const Parts = struct {
    first: u32,
    /// 0 for a character that is one other.
    second: u32,
};

/// The one or two characters `char` is, a step of the table; null for a
/// character that is no others.
fn partsOf(char: u32) ?Parts {
    if (char < 0x00C0) return null;
    if (char >= syllable_base and char < syllable_base + syllable_count) {
        const index = char - syllable_base;
        const trailing = index % trailing_count;
        if (trailing != 0) return .{ .first = char - trailing, .second = trailing_base + trailing };
        return .{
            .first = leading_base + index / vowel_span,
            .second = vowel_base + (index % vowel_span) / trailing_count,
        };
    }
    const parts = &_table.parts;
    var low: usize = 0;
    var high: usize = parts.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = parts[middle];
        const code: u32 = @intCast(entry >> 42);
        if (code == char) {
            return .{ .first = @intCast((entry >> 21) & 0x1F_FFFF), .second = @intCast(entry & 0x1F_FFFF) };
        }
        if (code < char) low = middle + 1 else high = middle;
    }
    return null;
}

/// The character `first` and `second` are put together into; 0 for
/// none.
fn joinedOf(first: u32, second: u32) u32 {
    const wanted = @as(u64, first) << 21 | second;
    const joined = &_table.joined;
    var low: usize = 0;
    var high: usize = joined.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = _table.parts[joined[middle]];
        const pair = entry & 0x3FF_FFFF_FFFF;
        if (pair == wanted) return @intCast(entry >> 42);
        if (pair < wanted) low = middle + 1 else high = middle;
    }
    return 0;
}

/// The width the space `char` gets where the font lacks its glyph.
fn spaceOf(char: u32) u8 {
    return switch (char) {
        0x0020, 0x00A0 => space_plain,
        0x2000, 0x2002 => 2,
        0x2001, 0x2003, 0x3000 => 1,
        0x2004 => 3,
        0x2005 => 4,
        0x2006 => 6,
        0x2007 => space_figure,
        0x2008 => space_punctuation,
        0x2009 => 5,
        0x200A => space_sixteenth,
        0x202F => space_narrow,
        0x205F => space_four_eighteenths,
        else => space_none,
    };
}

/// The advance of a space of the kind `space` that is drawn with the
/// font's space glyph, whose advance is `advance`.
pub fn spaceAdvance(font: *const Font, space: u8, advance: i32) i32 {
    switch (space) {
        space_none, space_plain => return advance,
        space_narrow => return @divTrunc(advance, 2),
        space_figure => {
            const glyphFn = font.glyphFn orelse return advance;
            var digit: u32 = '0';
            while (digit <= '9') : (digit += 1) {
                const glyph = glyphFn(font.context, digit);
                if (glyph != 0) return font.advanceFn(font.context, glyph);
            }
            return advance;
        },
        space_punctuation => {
            const glyphFn = font.glyphFn orelse return advance;
            var glyph = glyphFn(font.context, '.');
            if (glyph == 0) glyph = glyphFn(font.context, ',');
            return if (glyph != 0) font.advanceFn(font.context, glyph) else advance;
        },
        else => {},
    }
    const emFn = font.emFn orelse return advance;
    const em: i64 = emFn(font.context);
    if (space == space_four_eighteenths) return @intCast(@divTrunc(em * 4, 18));
    if (space > space_sixteenth) return advance;
    return @intCast(@divTrunc(em + space / 2, space));
}

/// A character of the stretch as it is shaped.
pub const Entry = struct {
    char: u32,
    /// The place in the text of the first byte it stands for.
    cluster: u32,
    /// The glyph it is drawn by; 0 where the font has none.
    glyph: u32,
    /// What a mark is sorted by; 0 for every other character.
    order: u8,
    mark: bool,
    /// A grapheme joiner that kept two marks apart.
    hidden: bool = false,
    /// The width it gets as a space drawn with the font's space glyph.
    space: u8 = space_none,
};

/// The ra with a dot below, which a model keeps whole.
const whole_ra = 0x0931;

pub const List = struct {
    memory: Memory,
    font: *const Font,
    entries: [*]Entry,
    len: u32,
    room: u32,
    /// There was not the memory: the list is not the stretch.
    failed: bool = false,
    /// No character had a mark behind it.
    simple: bool = true,
    /// The stretch is of a script with a model of its own, which reads
    /// each character by its parts: a character is taken apart where the
    /// font has its parts, also one the font has a glyph for; the ra
    /// with a dot below (U+0931) stays whole, because its parts would
    /// make a reph the character does not; and nothing is put together
    /// with a mark.
    model: bool = false,

    /// A list for a stretch of `chars` characters, with none in it yet.
    /// Null without the memory.
    pub fn init(memory: Memory, font: *const Font, chars: u32) ?List {
        const room = chars + chars / 4 + 8;
        const block = memory.alloc(@as(usize, room) * @sizeOf(Entry)) orelse return null;
        return .{ .memory = memory, .font = font, .entries = @ptrCast(@alignCast(block)), .len = 0, .room = room };
    }

    pub fn deinit(list: *List) void {
        list.memory.free(@ptrCast(list.entries));
    }

    pub fn slice(list: *const List) []Entry {
        return list.entries[0..list.len];
    }

    fn glyphOf(list: *const List, char: u32) u32 {
        const glyphFn = list.font.glyphFn orelse return 0;
        return glyphFn(list.font.context, char);
    }

    fn push(list: *List, entry: Entry) void {
        if (list.failed) return;
        if (list.len == list.room) {
            const room = list.room * 2;
            const block = list.memory.alloc(@as(usize, room) * @sizeOf(Entry)) orelse {
                list.failed = true;
                return;
            };
            const entries: [*]Entry = @ptrCast(@alignCast(block));
            for (entries[0..list.len], list.entries[0..list.len]) |*target, source| target.* = source;
            list.memory.free(@ptrCast(list.entries));
            list.entries = entries;
            list.room = room;
        }
        list.entries[list.len] = entry;
        list.len += 1;
    }

    fn add(list: *List, char: u32, cluster: u32, glyph: u32, space: u8) void {
        const mark = isMark(char);
        list.push(.{
            .char = char,
            .cluster = cluster,
            .glyph = glyph,
            .order = if (mark) orderOf(char) else 0,
            .mark = mark,
            .space = space,
        });
    }

    /// Adds `char` with the glyph the font has for it.
    fn nominal(list: *List, char: u32, cluster: u32) void {
        list.add(char, cluster, list.glyphOf(char), space_none);
    }

    /// Adds the parts of `char` the font has glyphs for: the first form
    /// that is there (`shortest`), or the one of the most parts. How
    /// many were added; 0, and nothing added, where the font has no
    /// form of its parts.
    fn apart(list: *List, shortest: bool, char: u32, cluster: u32) u32 {
        if (list.model and char == whole_ra) return 0;
        const parts = partsOf(char) orelse return 0;
        var second: u32 = 0;
        if (parts.second != 0) {
            second = list.glyphOf(parts.second);
            if (second == 0) return 0;
        }
        const first = list.glyphOf(parts.first);
        var count: u32 = 0;
        if (!shortest or first == 0) count = list.apart(shortest, parts.first, cluster);
        if (count == 0) {
            if (first == 0) return 0;
            list.add(parts.first, cluster, first, space_none);
            count = 1;
        }
        if (parts.second == 0) return count;
        list.add(parts.second, cluster, second, space_none);
        return count + 1;
    }

    /// Adds `char` as round 1 has it.
    fn current(list: *List, char: u32, cluster: u32, shortest: bool) void {
        const glyph = list.glyphOf(char);
        if (shortest and glyph != 0) return list.add(char, cluster, glyph, space_none);
        if (list.apart(shortest, char, cluster) != 0) return;
        if (glyph != 0) return list.add(char, cluster, glyph, space_none);
        const space = spaceOf(char);
        if (space != space_none) {
            const drawn = list.glyphOf(blank);
            if (drawn != 0) return list.add(char, cluster, drawn, space);
        }
        if (char == hard_hyphen) {
            const drawn = list.glyphOf(hyphen);
            if (drawn != 0) return list.add(char, cluster, drawn, space_none);
        }
        list.add(char, cluster, 0, space_none);
    }

    /// Adds the characters of a cluster that has a variation selector,
    /// as they are: a character and the selector behind it as the glyph
    /// the font has for the two, or else each by itself.
    fn selected(list: *List, bytes: []const u8, start: usize, end: usize) void {
        const font = list.font;
        var at = start;
        while (at < end) {
            const read = utf8.read(bytes[at..end]);
            const next = at + read.length;
            if (next < end) {
                const behind = utf8.read(bytes[next..end]);
                if (_scripts.selects(behind.char)) {
                    var glyph: u32 = 0;
                    if (font.variantFn) |variantFn| glyph = variantFn(font.context, read.char, behind.char);
                    if (glyph != 0) {
                        list.add(read.char, @intCast(at), glyph, space_none);
                    } else {
                        list.nominal(read.char, @intCast(at));
                        list.nominal(behind.char, @intCast(next));
                    }
                    at = next + behind.length;
                    while (at < end) {
                        const more = utf8.read(bytes[at..end]);
                        if (!_scripts.selects(more.char)) break;
                        list.nominal(more.char, @intCast(at));
                        at += more.length;
                    }
                    continue;
                }
            }
            list.nominal(read.char, @intCast(at));
            at = next;
        }
    }

    /// Gives the entries from `start` up to `end` the lowest of their
    /// clusters, and with them the ones before and behind that share a
    /// cluster with the first and the last.
    fn mergeClusters(list: *List, start: usize, end: usize) void {
        const entries = list.slice();
        if (end - start < 2) return;
        var lowest = entries[start].cluster;
        for (entries[start + 1 .. end]) |entry| {
            if (entry.cluster < lowest) lowest = entry.cluster;
        }
        var from = start;
        var to = end;
        if (lowest != entries[to - 1].cluster) {
            while (to < entries.len and entries[to - 1].cluster == entries[to].cluster) to += 1;
        }
        if (lowest != entries[from].cluster) {
            while (from > 0 and entries[from - 1].cluster == entries[from].cluster) from -= 1;
        }
        for (entries[from..to]) |*entry| entry.cluster = lowest;
    }

    /// Round 2: each run of marks sorted by their order.
    fn sort(list: *List) void {
        const entries = list.slice();
        var at: usize = 0;
        while (at < entries.len) {
            if (entries[at].order == 0) {
                at += 1;
                continue;
            }
            var end = at + 1;
            while (end < entries.len and entries[end].order != 0) end += 1;
            if (end - at <= longest_run) {
                var moved = at + 1;
                while (moved < end) : (moved += 1) {
                    var place = moved;
                    while (place > at and entries[place - 1].order > entries[moved].order) place -= 1;
                    if (place == moved) continue;
                    list.mergeClusters(place, moved + 1);
                    const entry = entries[moved];
                    var index = moved;
                    while (index > place) : (index -= 1) entries[index] = entries[index - 1];
                    entries[place] = entry;
                }
            }
            at = end;
        }
    }

    /// Marks the grapheme joiners a sequence does not step over: the
    /// ones that kept the mark behind them from going before the mark
    /// in front of them, and one at the stretch's start or end.
    fn hideJoiners(list: *List) void {
        const entries = list.slice();
        for (entries, 0..) |*entry, index| {
            if (entry.char != joiner) continue;
            entry.hidden = true;
            if (index == 0 or index + 1 >= entries.len) continue;
            const behind = entries[index + 1].order;
            if (behind == 0 or entries[index - 1].order <= behind) entry.hidden = false;
        }
    }

    /// Round 3: marks put together with the character they stand on.
    fn compose(list: *List) void {
        const entries = list.slice();
        if (entries.len == 0) return;
        var starter: usize = 0;
        var kept: usize = 1;
        var at: usize = 1;
        while (at < entries.len) : (at += 1) {
            const entry = entries[at];
            if (entry.mark and (starter == kept - 1 or entries[kept - 1].order < entry.order)) {
                const joined = if (list.model and entries[starter].mark) 0 else joinedOf(entries[starter].char, entry.char);
                const glyph = if (joined != 0) list.glyphOf(joined) else 0;
                if (glyph != 0) {
                    // The one character stands for all it was made of
                    // and all between them.
                    var lowest = entry.cluster;
                    for (entries[starter..kept]) |held| {
                        if (held.cluster < lowest) lowest = held.cluster;
                    }
                    var from = starter;
                    while (from > 0 and entries[from - 1].cluster == entries[from].cluster) from -= 1;
                    var behind = at + 1;
                    while (behind < entries.len and entries[behind].cluster == entry.cluster) : (behind += 1) {
                        entries[behind].cluster = lowest;
                    }
                    for (entries[from..kept]) |*held| held.cluster = lowest;
                    const mark = isMark(joined);
                    entries[starter].char = joined;
                    entries[starter].glyph = glyph;
                    entries[starter].mark = mark;
                    entries[starter].order = if (mark) orderOf(joined) else 0;
                    continue;
                }
            }
            entries[kept] = entry;
            if (entry.order == 0) starter = kept;
            kept += 1;
        }
        list.len = @intCast(kept);
    }

    /// Makes the list the stretch `bytes[start..end]`. `failed` is set
    /// where there was not the memory.
    pub fn fill(list: *List, bytes: []const u8, start: usize, end: usize) void {
        var at = start;
        while (at < end) {
            const read = utf8.read(bytes[at..end]);
            // The marks behind it are its cluster.
            var selector = _scripts.selects(read.char);
            var cluster_end = at + read.length;
            while (cluster_end < end) {
                const behind = utf8.read(bytes[cluster_end..end]);
                if (!isMark(behind.char)) break;
                if (_scripts.selects(behind.char)) selector = true;
                cluster_end += behind.length;
            }
            if (cluster_end == at + read.length) {
                list.current(read.char, @intCast(at), !list.model);
            } else if (selector) {
                list.simple = false;
                list.selected(bytes, at, cluster_end);
            } else {
                list.simple = false;
                var part = at;
                while (part < cluster_end) {
                    const within = utf8.read(bytes[part..cluster_end]);
                    list.current(within.char, @intCast(part), false);
                    part += within.length;
                }
            }
            at = cluster_end;
        }
        if (list.failed) return;
        if (!list.simple) list.sort();
        list.hideJoiners();
        if (!list.simple) list.compose();
    }
};

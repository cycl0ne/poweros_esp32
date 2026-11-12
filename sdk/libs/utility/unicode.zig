// SPDX-License-Identifier: MIT
//! Characters by Unicode's tables: a character's folding, upper case and
//! lower case, names compared without regard to case, the letter a
//! letter with marks is written on, the cells of a console a character
//! takes, what a character is - a letter, a digit, a space, ... - the
//! clusters a text is made of, and which of them are emoji drawn as
//! pictures.
//!
//! The case tables are runs of code points that move by the same amount
//! (`unicode_case.zig`, written by tools/foldgen); a character is looked
//! up by a binary search over them, ASCII without one. The base letters
//! (`unicode_base.zig`, the same tool's) are a sorted list searched the
//! same way, the widths (`unicode_width.zig`) sorted ranges, and the
//! classes (`unicode_class.zig`) the code points where the class
//! changes, searched for the last at or before a character. Folding
//! is simple
//! case folding - one code point to one, the same whatever language is
//! set - which is what every name is compared by: `ß` stays `ß`, `ẞ` folds
//! to it, `Σ`, `σ` and `ς` are one letter.
//!
//! A cluster is what a reader takes for one character: a letter with
//! its marks, a carriage return with its line feed, a syllable of
//! Hangul written as its parts, consonants a virama joins with their
//! vowel sign, two regional indicators that are a flag, pictographs a
//! joiner makes one. Where one ends is Unicode's rule for extended
//! grapheme clusters, decided between two characters by what each is
//! (`unicode_cluster.zig`, the code points where that changes) - and for
//! a consonant, a pictograph and a regional indicator also by what the
//! cluster holds before them. `clusterEnd` goes forward from a
//! cluster's start; `clusterStart` goes back from any byte to a place a
//! cluster starts at whatever stands before, and forward from there.
//! Nothing is drawn, moved over or cut inside a cluster.
//!
//! An emoji is drawn as text or as a picture. Which, each has by
//! default (`unicode_emoji.zig`, the code points where that changes):
//! a heart and a digit are text, a face is a picture. U+FE0F behind
//! one asks for its picture and U+FE0E for its text, where Unicode has
//! the character with a selector; a skin tone behind a character that
//! takes one makes a picture of it. `emoji` is what one character is,
//! `pictured` what a cluster is drawn as - asked by whoever chooses the
//! font a cluster is drawn in, and the cells it takes in a console.
//!
//! The compares and the clusters read their bytes as text is read (`utf8.read`), so a
//! byte that is no UTF-8 compares as U+FFFD.

const utf8 = @import("utf8.zig");
const unicode_case = @import("unicode_case.zig");
const unicode_base = @import("unicode_base.zig");
const unicode_compose = @import("unicode_compose.zig");
const unicode_width = @import("unicode_width.zig");
const unicode_class = @import("unicode_class.zig");
const unicode_cluster = @import("unicode_cluster.zig");
const unicode_emoji = @import("unicode_emoji.zig");

/// The Unicode version the tables are from.
pub const version = unicode_case.unicode_version;

/// The character `runs` map `char` to: the run it falls in moves it by
/// its `delta`, and a character in none stays as it is. `runs` is an
/// array of a run type with `first`, `count`, `stride` and `delta`,
/// sorted by `first`.
pub fn mapped(runs: anytype, char: u32) u32 {
    if (char > utf8.last) return char;
    // The last run that starts at or before the character.
    var low: usize = 0;
    var high: usize = runs.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (runs[middle].first <= char) low = middle + 1 else high = middle;
    }
    if (low == 0) return char;
    const run = runs[low - 1];
    const distance: u32 = char - run.first;
    const stride: u32 = run.stride;
    if (distance % stride != 0 or distance / stride >= run.count) return char;
    const moved: i64 = @as(i64, char) + run.delta;
    return @intCast(moved);
}

/// What a character folds to.
pub fn fold(char: u32) u32 {
    if (char < 0x80) return if (char >= 'A' and char <= 'Z') char + 32 else char;
    return mapped(&unicode_case.fold, char);
}

/// A character's upper case, or the character when it has none.
pub fn upper(char: u32) u32 {
    if (char < 0x80) return if (char >= 'a' and char <= 'z') char - 32 else char;
    return mapped(&unicode_case.upper, char);
}

/// A character's lower case, or the character when it has none.
pub fn lower(char: u32) u32 {
    if (char < 0x80) return if (char >= 'A' and char <= 'Z') char + 32 else char;
    return mapped(&unicode_case.lower, char);
}

/// The one character `first` and `second` are put together as - `é` for
/// `e` and U+0301, `が` for `か` and U+3099 - or null for two that make
/// none. The pairs are Unicode's canonical ones of the BMP; a letter
/// with two marks is made a mark at a time, the answer asked again with
/// the next.
pub fn compose(first: u32, second: u32) ?u32 {
    // No pair's second character is below the combining marks.
    if (second < 0x300 or first > 0xFFFF or second > 0xFFFF) return null;
    const pair = first << 16 | second;
    const pairs = &unicode_compose.pairs;
    var low: usize = 0;
    var high: usize = pairs.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (pairs[middle] < pair) {
            low = middle + 1;
        } else if (pairs[middle] > pair) {
            high = middle;
        } else {
            return unicode_compose.wholes[middle];
        }
    }
    return null;
}

/// The letter `char` is written on with marks - `A` for `Ā`, `α` for
/// `ἀ`, `Å` for `Ǻ` - or null for a character that is no Latin, Greek or
/// Cyrillic letter with marks. What a font that lacks a letter draws
/// instead; asked again of the answer, it goes on to the bare letter.
pub fn base(char: u32) ?u32 {
    const letters = &unicode_base.letters;
    if (char < letters[0] or char > letters[letters.len - 1]) return null;
    var low: usize = 0;
    var high: usize = letters.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (letters[middle] < char) {
            low = middle + 1;
        } else if (letters[middle] > char) {
            high = middle;
        } else {
            return unicode_base.bases[middle];
        }
    }
    return null;
}

/// How many cells of a console `char` takes: 0 for a mark written on the
/// character before it, a format character or a Hangul vowel or final
/// that joins the syllable before; 2 for a wide or full-width character
/// - CJK, kana, Hangul syllables, emoji; 1 for the rest. A control is
/// the console's to act on and never asked about.
pub fn width(char: u32) u2 {
    // Nothing below the combining marks is of any width but one.
    if (char < unicode_width.zero[0][0]) return 1;
    if (within(&unicode_width.zero, char)) return 0;
    if (within(&unicode_width.wide, char)) return 2;
    return 1;
}

/// What a character is, by its general category.
pub const Class = unicode_class.Class;

/// What `char` is: a capital, a small letter, a digit, a space, ... -
/// `.unassigned` for a code point that is no character, a surrogate, or
/// a value past U+10FFFF.
pub fn class(char: u32) Class {
    if (char > utf8.last) return .unassigned;
    const starts = &unicode_class.starts;
    // The last entry that starts at or before the character; the first
    // starts at 0.
    var low: usize = 0;
    var high: usize = starts.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (starts[middle] >> 8 <= char) low = middle + 1 else high = middle;
    }
    const start = starts[low - 1];
    const number: u8 = @truncate(start);
    if (number == unicode_class.pairs) return if ((char - (start >> 8)) % 2 == 0) .upper else .lower;
    return @enumFromInt(number);
}

/// What a character is in a cluster.
pub const Part = unicode_cluster.Part;

/// What `char` is in a cluster: a mark, a consonant a virama joins, a
/// pictograph, ... - `.other` for a character that only starts one, and
/// for a value past U+10FFFF.
pub fn part(char: u32) Part {
    if (char >= 0x20 and char < 0x7F) return .other;
    if (char > utf8.last) return .other;
    const starts = &unicode_cluster.starts;
    // The last entry that starts at or before the character; the first
    // starts at 0.
    var low: usize = 0;
    var high: usize = starts.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (starts[middle] >> 8 <= char) low = middle + 1 else high = middle;
    }
    const start = starts[low - 1];
    const number: u8 = @truncate(start);
    if (number == unicode_cluster.syllables) return if ((char - (start >> 8)) % 28 == 0) .syllable else .syllable_trail;
    return @enumFromInt(number);
}

/// How a character stands to the emoji.
pub const Emoji = unicode_emoji.Emoji;

/// The selector that asks for an emoji's text form.
pub const text_selector = 0xFE0E;
/// The selector that asks for an emoji's picture.
pub const picture_selector = 0xFE0F;

/// The low byte of `char`'s entry in the emoji table: its kind, and
/// `unicode_emoji.selected` beside it.
fn emojiEntry(char: u32) u8 {
    if (char > utf8.last) return 0;
    const starts = &unicode_emoji.starts;
    // The last entry that starts at or before the character; the first
    // starts at 0.
    var low: usize = 0;
    var high: usize = starts.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (starts[middle] >> 8 <= char) low = middle + 1 else high = middle;
    }
    return @truncate(starts[low - 1]);
}

/// How `char` stands to the emoji: none of them, one drawn as text or
/// as a picture, one of either that takes a skin tone, a skin tone -
/// `.none` for a value past U+10FFFF.
pub fn emoji(char: u32) Emoji {
    return @enumFromInt(emojiEntry(char) & ~@as(u8, unicode_emoji.selected));
}

/// Whether a selector may stand behind `char`: U+FE0E to have its text
/// form, U+FE0F its picture. Behind any other character a selector
/// changes nothing.
pub fn selectable(char: u32) bool {
    return emojiEntry(char) & unicode_emoji.selected != 0;
}

/// Whether `cluster` - one cluster, as `clusterEnd` cuts them - is an
/// emoji drawn as a picture: its first character one by default (a
/// face, a flag's regional indicator, a skin tone), one a skin tone
/// stands behind, or one U+FE0F asks the picture of (`❤️`, the digit of
/// a keycap); and none U+FE0E asks the text of. A cluster whose first
/// character is no emoji is never one.
pub fn pictured(cluster: []const u8) bool {
    if (cluster.len == 0) return false;
    const first = utf8.read(cluster);
    const entry = emojiEntry(first.char);
    const kind: Emoji = @enumFromInt(entry & ~@as(u8, unicode_emoji.selected));
    if (kind == .none) return false;
    if (first.length < cluster.len) {
        const next = utf8.read(cluster[first.length..]).char;
        if (entry & unicode_emoji.selected != 0) {
            if (next == picture_selector) return true;
            if (next == text_selector) return false;
        }
        if ((kind == .toned_text or kind == .toned_picture) and emoji(next) == .tone) return true;
    }
    return switch (kind) {
        .none, .text, .toned_text => false,
        .picture, .toned_picture, .tone => true,
    };
}

/// Whether two characters next to each other are in one cluster: never,
/// always, or as what the cluster holds before them says.
const Link = enum { never, always, asked };

/// How a character that is `after` stands to the one before it.
fn link(before: Part, after: Part) Link {
    if (before == .cr) return if (after == .lf) .always else .never;
    if (before == .lf or before == .control) return .never;
    switch (after) {
        .cr, .lf, .control => return .never,
        .extend, .conjunct_extend, .linker, .joiner, .spacing => return .always,
        else => {},
    }
    if (before == .prepend) return .always;
    const joined = switch (after) {
        .lead, .syllable, .syllable_trail => before == .lead,
        .vowel => before == .lead or before == .vowel or before == .syllable,
        .trail => before == .vowel or before == .trail or before == .syllable or before == .syllable_trail,
        // A consonant joins one a linker stands behind, a pictograph one
        // a joiner stands behind, a regional indicator the one before
        // that is not a flag's second already.
        .consonant => return if (before == .linker or before == .conjunct_extend or before == .joiner) .asked else .never,
        .pictographic => return if (before == .joiner) .asked else .never,
        .regional => return if (before == .regional) .asked else .never,
        else => false,
    };
    return if (joined) .always else .never;
}

/// What a cluster holds so far, for the characters `link` asks about.
const Held = struct {
    /// A consonant with nothing but marks behind it, and whether a
    /// linker is among them.
    conjunct: enum { none, consonant, linked } = .none,
    /// A pictograph with nothing but marks behind it.
    pictograph: bool = false,
    /// The last character is a joiner behind such a pictograph.
    joined: bool = false,
    /// The regional indicators the cluster ends with.
    regionals: u32 = 0,

    fn take(self: *Held, what: Part) void {
        self.conjunct = switch (what) {
            .consonant => .consonant,
            .linker => if (self.conjunct == .none) .none else .linked,
            .conjunct_extend, .joiner => self.conjunct,
            else => .none,
        };
        self.joined = what == .joiner and self.pictograph;
        self.pictograph = switch (what) {
            .pictographic => true,
            .extend, .conjunct_extend, .linker => self.pictograph,
            else => false,
        };
        self.regionals = if (what == .regional) self.regionals + 1 else 0;
    }

    fn joins(self: Held, after: Part) bool {
        return switch (after) {
            .consonant => self.conjunct == .linked,
            .pictographic => self.joined,
            else => self.regionals % 2 == 1,
        };
    }
};

/// Where the cluster that starts at `start` ends: the offset behind its
/// last byte, `text.len` for the last cluster and for a `start` at or
/// past the end. `start` is a cluster's start - 0, or what this or
/// `clusterStart` answered.
pub fn clusterEnd(text: []const u8, start: usize) usize {
    if (start >= text.len) return text.len;
    const first = utf8.read(text[start..]);
    var held: Held = .{};
    var before = part(first.char);
    held.take(before);
    var end = start + first.length;
    while (end < text.len) {
        const next = utf8.read(text[end..]);
        const after = part(next.char);
        const joined = switch (link(before, after)) {
            .never => false,
            .always => true,
            .asked => held.joins(after),
        };
        if (!joined) break;
        held.take(after);
        before = after;
        end += next.length;
    }
    return end;
}

/// Where the cluster starts that the byte at `at` is in: `at` itself
/// when a cluster starts there, `text.len` for an `at` at or past the
/// end.
pub fn clusterStart(text: []const u8, at: usize) usize {
    if (at >= text.len) return text.len;
    // The character the byte is in.
    var start = at;
    while (start > 0 and at - start < 3 and text[start] & 0xC0 == 0x80) start -= 1;
    if (start + utf8.read(text[start..]).length <= at) start = at;
    // Back to where a cluster starts whatever stands before it.
    var after = part(utf8.read(text[start..]).char);
    while (start > 0) {
        const last = utf8.readLast(text[0..start]);
        const before = part(last.char);
        if (link(before, after) == .never) break;
        start -= last.length;
        after = before;
    }
    // And forward to the cluster with the byte.
    while (true) {
        const end = clusterEnd(text, start);
        if (end > at) return start;
        start = end;
    }
}

/// Whether `char` is in one of `ranges`, sorted pairs of first and last.
fn within(ranges: []const [2]u32, char: u32) bool {
    if (char < ranges[0][0] or char > ranges[ranges.len - 1][1]) return false;
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (ranges[middle][1] < char) {
            low = middle + 1;
        } else if (ranges[middle][0] > char) {
            high = middle;
        } else {
            return true;
        }
    }
    return false;
}

/// How two texts compare without regard to case: less than 0, 0 or more
/// than 0 as `one` sorts before, the same as or after `other` - the
/// difference of the first two characters that differ once folded, the
/// end of a text counting as 0.
pub fn compareFolded(one: []const u8, other: []const u8) i32 {
    var at_one: usize = 0;
    var at_other: usize = 0;
    while (at_one < one.len or at_other < other.len) {
        const mine: u32 = if (at_one < one.len) fold(utf8.next(one, &at_one)) else 0;
        const theirs: u32 = if (at_other < other.len) fold(utf8.next(other, &at_other)) else 0;
        if (mine != theirs) return @as(i32, @intCast(mine)) - @as(i32, @intCast(theirs));
    }
    return 0;
}

/// Whether two names are the same name: the same characters once folded.
pub fn equalFolded(one: []const u8, other: []const u8) bool {
    return compareFolded(one, other) == 0;
}

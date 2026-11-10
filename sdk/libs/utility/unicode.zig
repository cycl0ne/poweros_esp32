// SPDX-License-Identifier: MIT
//! Characters by Unicode's tables: a character's folding, upper case and
//! lower case, names compared without regard to case, the letter a
//! letter with marks is written on, and the cells of a console a
//! character takes.
//!
//! The case tables are runs of code points that move by the same amount
//! (`unicode_case.zig`, written by tools/foldgen); a character is looked
//! up by a binary search over them, ASCII without one. The base letters
//! (`unicode_base.zig`, the same tool's) are a sorted list searched the
//! same way, and the widths (`unicode_width.zig`) sorted ranges. Folding
//! is simple
//! case folding - one code point to one, the same whatever language is
//! set - which is what every name is compared by: `ß` stays `ß`, `ẞ` folds
//! to it, `Σ`, `σ` and `ς` are one letter.
//!
//! The compares read their bytes as text is read (`utf8.read`), so a
//! byte that is no UTF-8 compares as the character it reads as.

const utf8 = @import("utf8.zig");
const unicode_case = @import("unicode_case.zig");
const unicode_base = @import("unicode_base.zig");
const unicode_width = @import("unicode_width.zig");

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

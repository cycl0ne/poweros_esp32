// SPDX-License-Identifier: MIT
//! The orders StrnCmp compares in and StrConvert writes keys for.
//!
//! SC_ASCII compares the characters' capitals - Unicode's simple upper
//! case - by their code points; its key is those capitals in UTF-8.
//!
//! SC_COLLATE1 compares each character's key, a byte or four, StrConvert
//! writing the bytes and StrnCmp comparing them as the number they make,
//! the first the highest. In the order of the keys:
//!
//! - what of Latin-1 is no letter, in the order of its code: a byte each,
//!   from 2 up;
//! - what past Latin-1 is no letter, in the order of its code point: the
//!   byte after those, then the code point as three digits of base 254,
//!   each from 2 up;
//! - every Latin letter, with the letter of the alphabet it is written on
//!   (`unicode.base`), its case and marks left out - `æ` with `a`, `ð`
//!   with `d`, `ß` with `s`, `œ` with `o`, `ª` with `a`, `º` with `o`, and
//!   `þ` after `z` - and the letters a language sorts after one of the
//!   alphabet's in their own places (`AFTER_Z=Å,ÄÆ,ÖØ`): a byte each, in
//!   the language's order;
//! - every other letter - Greek, Cyrillic, the kana, the ideographs -
//!   folded and without its marks, in the order of its code point: 255,
//!   then the code point as the second kind's.
//!
//! A mark written on the character before and a format character have no
//! key and are passed over. SC_COLLATE2 compares as SC_COLLATE1 does and,
//! where that finds the two the same, takes the first byte they differ
//! in, so `Ab` comes before `ab` and `a` before `ä`; its key is the
//! SC_COLLATE1 key, a 1, and the string's own bytes.
//!
//! No byte of a key is 0, so a key is a C string, and one ending first
//! sorts first.

const sdk = @import("sdk");
const locale = sdk.locale;
const utf8 = sdk.utility.utf8;
const unicode = sdk.utility.unicode;
const _base = @import("../locale_base.zig");
const _chars = @import("../chars/_chars.zig");
const ExtLocale = _base.ExtLocale;

/// The letter `þ` is: the one after z.
const thorn = 26;

/// The key byte of each character of Latin-1 that is no letter, from 2
/// up; 0 for the letters and the NUL.
const latin1_keys: [256]u8 = blk: {
    @setEvalBranchQuota(200_000);
    var table: [256]u8 = @splat(0);
    var key: u8 = 2;
    for (1..256) |code| {
        if (_chars.is(code, _chars.alpha)) continue;
        table[code] = key;
        key += 1;
    }
    break :blk table;
};

/// The byte that starts the key of what past Latin-1 is no letter.
pub const beyond_latin1: u8 = blk: {
    var highest: u8 = 0;
    for (latin1_keys) |key| highest = @max(highest, key);
    break :blk highest + 1;
};
/// The key byte of the first place a Latin letter sorts at.
pub const letters_first: u8 = beyond_latin1 + 1;
/// The byte that starts the key of every other letter.
pub const other_letters: u8 = 255;

comptime {
    // Every place a Latin letter can take has a key byte of its own.
    if (letters_first + _base.letter_bases + _base.max_placed > other_letters) @compileError("the letters' key bytes do not fit");
}

/// The order a compare type names: SC_ASCII for any number that is none.
pub fn orderOf(compare_type: u32) u32 {
    return if (compare_type == locale.SC_COLLATE1 or compare_type == locale.SC_COLLATE2) compare_type else locale.SC_ASCII;
}

/// The bytes of `string` up to its NUL, at most `length` (below 0: all).
pub fn bounded(string: [*:0]const u8, length: i32) []const u8 {
    var count: usize = 0;
    while (string[count] != 0 and (length < 0 or count < @as(usize, @intCast(length)))) count += 1;
    return string[0..count];
}

/// The key of the next character of `text` from `at` on in `order`
/// (SC_ASCII or SC_COLLATE1), `at` moved past it; 0 at the end, below
/// every character. SC_ASCII's key is the capital's code point,
/// SC_COLLATE1's its key bytes as a number, the first the highest, a
/// one-byte key in the top byte; a character with no key is passed over.
pub fn nextKey(ext: *const ExtLocale, text: []const u8, at: *usize, order: u32) u32 {
    while (at.* < text.len) {
        const char = utf8.next(text, at);
        if (order == locale.SC_ASCII) return unicode.upper(char);
        if (keyOf(ext, char)) |key| return key;
    }
    return 0;
}

/// -1, 0 or 1, as `one` is below, the same as or above `other`.
pub fn sign(one: u32, other: u32) i32 {
    return if (one < other) -1 else if (one > other) 1 else 0;
}

/// The SC_COLLATE1 key of `char` (not the NUL) as a number, the first
/// byte the highest; null for a mark or a format character, which have
/// none.
pub fn keyOf(ext: *const ExtLocale, char: u32) ?u32 {
    if (char < 0x100 and latin1_keys[char] != 0) return @as(u32, latin1_keys[char]) << 24;
    switch (unicode.class(char)) {
        .mark, .format => return null,
        .upper, .lower, .title, .letter => {},
        else => return digits(beyond_latin1, char),
    }
    if (placeOf(ext, char)) |place| return @as(u32, ext.letter_keys[place]) << 24;
    return digits(other_letters, bare(char));
}

/// The bytes of `key`, a key nextKey answered in `order`, into `into`;
/// how many.
pub fn keyBytes(key: u32, order: u32, into: *[4]u8) usize {
    if (order == locale.SC_ASCII) return utf8.encode(key, into);
    const first: u8 = @intCast(key >> 24);
    into.* = .{ first, @truncate(key >> 16), @truncate(key >> 8), @truncate(key) };
    return if (first == beyond_latin1 or first == other_letters) 4 else 1;
}

/// The key starting with `first` of the code point `value`: its three
/// digits of base 254, each from 2 up.
fn digits(first: u8, value: u32) u32 {
    const high = value / (254 * 254);
    const middle = value / 254 % 254;
    const low = value % 254;
    return @as(u32, first) << 24 | (high + 2) << 16 | (middle + 2) << 8 | (low + 2);
}

/// The place a letter sorts at among the Latin ones (`letter * 8 +
/// slot`): the place the language gives it or the letter it is written
/// on, asked of the letter and of each it is written on in turn; null
/// for a letter that is no Latin one.
pub fn placeOf(ext: *const ExtLocale, char: u32) ?usize {
    var letter = unicode.fold(char);
    while (true) {
        for (ext.placed[0..ext.placed_count]) |placed| {
            if (placed.char == letter) return placed.place;
        }
        letter = unicode.fold(unicode.base(letter) orelse break);
    }
    const alphabet: usize = switch (letter) {
        'a'...'z' => letter - 'a',
        0xAA, 0xE6 => 'a' - 'a', // ª, æ
        0xF0 => 'd' - 'a', // ð
        0xBA, 0x0153 => 'o' - 'a', // º, œ
        0xDF => 's' - 'a', // ß
        0xFE => thorn, // þ
        else => return null,
    };
    return alphabet * _base.letter_slots;
}

/// `char` folded, and without the marks it is written with.
fn bare(char: u32) u32 {
    var letter = unicode.fold(char);
    while (unicode.base(letter)) |under| letter = unicode.fold(under);
    return letter;
}

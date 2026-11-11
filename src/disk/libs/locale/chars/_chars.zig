// SPDX-License-Identifier: MIT
//! What each character is, and its other case, by Unicode's tables
//! (`sdk.utility.unicode`): the same in every language - what a language
//! decides is the order its letters sort in (compare/).
//!
//! The classes come from a character's general category:
//!
//! - the letters are every letter of every script; the capitals (Lu) are
//!   upper, the small letters (Ll) lower, a letter that is a capital and
//!   a small one in one (`ǅ`) and those of no case (`ª`, the kana, the
//!   ideographs) neither;
//! - the digits are the decimal digits of every script (Nd), the
//!   hexadecimal ones 0 to 9, A to F and a to f;
//! - the blanks are the spaces (Zs, the one that does not break among
//!   them), the line and paragraph separators, and the five from tab to
//!   carriage return;
//! - the control characters are 0 to 31, 127 and 128 to 159;
//! - every character that is neither a control, a blank nor unassigned
//!   is printed and not blank, and the spaces are printed too;
//! - of those printed and not blank, every one that is neither a letter
//!   nor a digit is punctuation: the marks, the numbers like `²`, the
//!   symbols, the format characters and those for private use with the
//!   punctuation proper.
//!
//! The other case is Unicode's simple one, a character to a character:
//! `ß` has no capital, `ÿ` has `Ÿ`.

const unicode = @import("sdk").utility.unicode;

pub const cntrl: u16 = 1 << 0;
pub const space: u16 = 1 << 1;
pub const upper: u16 = 1 << 2;
pub const lower: u16 = 1 << 3;
pub const alpha: u16 = 1 << 4;
pub const digit: u16 = 1 << 5;
pub const xdigit: u16 = 1 << 6;
pub const punct: u16 = 1 << 7;
pub const graph: u16 = 1 << 8;
pub const print: u16 = 1 << 9;

/// The classes of `character`, a code point.
pub fn classesOf(character: u32) u16 {
    var bits: u16 = switch (unicode.class(character)) {
        .unassigned => 0,
        .control => cntrl,
        .upper => upper | alpha | graph | print,
        .lower => lower | alpha | graph | print,
        .title, .letter => alpha | graph | print,
        .digit => digit | graph | print,
        .space => space | print,
        .separator => space,
        .format, .private, .mark, .number, .punctuation, .symbol => punct | graph | print,
    };
    if (character >= 0x09 and character <= 0x0D) bits |= space;
    const hexadecimal = (character >= '0' and character <= '9') or
        (character >= 'A' and character <= 'F') or (character >= 'a' and character <= 'f');
    if (hexadecimal) bits |= xdigit;
    return bits;
}

/// Whether `character` has any of the classes `bits`.
pub fn is(character: u32, bits: u16) bool {
    return classesOf(character) & bits != 0;
}

/// `character` as a small letter, as it is when it has none.
pub fn toLower(character: u32) u32 {
    return unicode.lower(character);
}

/// `character` as a capital letter, as it is when it has none.
pub fn toUpper(character: u32) u32 {
    return unicode.upper(character);
}

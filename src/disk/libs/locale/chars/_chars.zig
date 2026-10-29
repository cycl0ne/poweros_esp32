// SPDX-License-Identifier: MIT
//! What each character of the code set is, and its other case.
//!
//! The code set is Latin-1, so a table of 256 entries made at compile
//! time answers every class: a character past 255 is in none of them and
//! has no other case. The classes are the code set's, the same in every
//! language; what a language decides is the order its letters sort in
//! (compare/).
//!
//! The letters are A to Z, À to Þ but ×, and their small partners; ß, ÿ
//! and µ are small letters without a capital in the code set, ª and º
//! letters of neither case. The blanks are a space, the five from tab to
//! carriage return, and the space that does not break; the control
//! characters 0 to 31, 127 and 128 to 159. Every character from 33 to
//! 126 and from 161 to 255 is printed and not blank, and of those every
//! one that is neither a letter nor a digit is punctuation.

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

/// Each character's classes.
pub const classes: [256]u16 = blk: {
    @setEvalBranchQuota(20_000);
    var table: [256]u16 = @splat(0);
    for (0..256) |code| {
        const c: u8 = @intCast(code);
        var bits: u16 = 0;
        if (c < 0x20 or c == 0x7F or (c >= 0x80 and c < 0xA0)) bits |= cntrl;
        if ((c >= 0x09 and c <= 0x0D) or c == ' ' or c == 0xA0) bits |= space;
        if (isCapital(c)) bits |= upper | alpha;
        if (isSmall(c)) bits |= lower | alpha;
        if (c == 0xAA or c == 0xBA) bits |= alpha;
        if (c >= '0' and c <= '9') bits |= digit | xdigit;
        if ((c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f')) bits |= xdigit;
        if ((c > 0x20 and c < 0x7F) or c > 0xA0) bits |= graph | print;
        if (c == ' ' or c == 0xA0) bits |= print;
        if (bits & graph != 0 and bits & (alpha | digit) == 0) bits |= punct;
        table[code] = bits;
    }
    break :blk table;
};

fn isCapital(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 0xC0 and c <= 0xDE and c != 0xD7);
}

fn isSmall(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 0xDF and c != 0xF7) or c == 0xB5;
}

/// Whether `character` has any of the classes `bits`.
pub fn is(character: u32, bits: u16) bool {
    if (character > 0xFF) return false;
    return classes[character] & bits != 0;
}

/// `character` as a small letter, as it is when it has none.
pub fn toLower(character: u32) u32 {
    if (character > 0xFF) return character;
    const c: u8 = @intCast(character);
    return if (isCapital(c)) c + 0x20 else c;
}

/// `character` as a capital letter, as it is when it has none.
pub fn toUpper(character: u32) u32 {
    if (character > 0xFF) return character;
    const c: u8 = @intCast(character);
    if (c == 0xDF or c == 0xFF or c == 0xB5) return c;
    return if (isSmall(c)) c - 0x20 else c;
}

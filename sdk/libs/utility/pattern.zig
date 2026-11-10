// SPDX-License-Identifier: MIT
//! Pattern tokens: what utility.library's ParsePattern makes of a pattern
//! for MatchPattern. A parsed pattern is these bytes and the literal
//! characters in UTF-8, NUL-terminated. The tokens are F5 to FF, bytes
//! UTF-8 never holds, so a literal is never taken for one and a parsed
//! pattern can be scanned byte by byte for them.

/// `#?`, and `*` when WildStar is on: any string.
pub const P_ANY: u8 = 0xF5;
/// `?`: any one character.
pub const P_SINGLE: u8 = 0xF6;
/// `(`, `|` and `)`: a group of alternatives.
pub const P_ORSTART: u8 = 0xF7;
pub const P_ORNEXT: u8 = 0xF8;
pub const P_OREND: u8 = 0xF9;
/// `~x`: before and after the item it negates.
pub const P_NOT: u8 = 0xFA;
pub const P_NOTEND: u8 = 0xFB;
/// `[~`: opens a negated class, which P_CLASS closes.
pub const P_NOTCLASS: u8 = 0xFC;
/// `[` and `]`: a class opens and closes with it.
pub const P_CLASS: u8 = 0xFD;
/// `#x`: before and after the item repeated.
pub const P_REPBEG: u8 = 0xFE;
pub const P_REPEND: u8 = 0xFF;

/// Whether a byte of a parsed pattern is a token.
pub fn isToken(byte: u8) bool {
    return byte >= P_ANY;
}

/// The bytes ParsePattern may need for a pattern of `len` bytes: two per
/// byte at most - a token and the character, or a byte that is no UTF-8
/// written as the two bytes of its Latin-1 character - then the NUL and a
/// byte the parser keeps free.
pub fn parsedSize(len: usize) usize {
    return 2 * len + 2;
}

// SPDX-License-Identifier: MIT
//! Pattern tokens: what utility.library's ParsePattern makes of a pattern
//! for MatchPattern. A parsed pattern is these bytes and the literal
//! characters, NUL-terminated.

/// `#?`, and `*` when WildStar is on: any string.
pub const P_ANY: u8 = 0x80;
/// `?`: any one character.
pub const P_SINGLE: u8 = 0x81;
/// `(`, `|` and `)`: a group of alternatives.
pub const P_ORSTART: u8 = 0x82;
pub const P_ORNEXT: u8 = 0x83;
pub const P_OREND: u8 = 0x84;
/// `~x`: before and after the item it negates.
pub const P_NOT: u8 = 0x85;
pub const P_NOTEND: u8 = 0x86;
/// `[~`: opens a negated class, which P_CLASS closes.
pub const P_NOTCLASS: u8 = 0x87;
/// `[` and `]`: a class opens and closes with it.
pub const P_CLASS: u8 = 0x88;
/// `#x`: before and after the item repeated.
pub const P_REPBEG: u8 = 0x89;
pub const P_REPEND: u8 = 0x8A;
/// Reserved: ParsePattern never makes it, and the matcher never writes
/// into a pattern.
pub const P_STOP: u8 = 0x8B;

/// The bytes ParsePattern may need for a pattern of `len` characters: two
/// per character at most, a token and the character, then the NUL and a
/// byte the parser keeps free.
pub fn parsedSize(len: usize) usize {
    return 2 * len + 2;
}

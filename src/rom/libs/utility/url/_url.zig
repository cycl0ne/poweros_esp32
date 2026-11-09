// SPDX-License-Identifier: MPL-2.0
//! What the URL calls share: the characters a part holds as they are,
//! and hex digits both ways.

/// RFC 3986's unreserved characters: a letter, a digit, `-`, `.`, `_`
/// and `~`, which no part of a URL needs escaped.
pub fn isUnreserved(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or (char >= '0' and char <= '9') or
        char == '-' or char == '.' or char == '_' or char == '~';
}

/// A hex digit's value, either case; null for another character.
pub fn hexValue(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// The digits an escape is written with.
pub const hex_digits = "0123456789ABCDEF";

// SPDX-License-Identifier: MIT
//! The orders StrnCmp compares in and StrConvert writes keys for.
//!
//! SC_ASCII compares the capitals of the characters by their codes.
//! SC_COLLATE1 compares each character's primary weight, the byte the
//! locale gives it from 2 up (locale/_locale.zig): every letter with the
//! letter it is written on, case and accent left out, in the language's
//! order, and everything else below the letters by its code. SC_COLLATE2
//! compares as SC_COLLATE1 does and, where that finds the two the same,
//! takes the first byte they differ in, so `Ab` comes before `ab` and `a`
//! before `ä`.
//!
//! A key is the bytes of one string in its order, compared byte by byte:
//! the capitals for SC_ASCII, the weights for SC_COLLATE1, and for
//! SC_COLLATE2 the weights, a 1, and the string's own bytes. No byte of a
//! key is 0, and a 1 only parts the halves, so a key is a C string and
//! one ending first sorts first.

const sdk = @import("sdk");
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const _chars = @import("../chars/_chars.zig");
const ExtLocale = _base.ExtLocale;

/// The byte `c` is compared by in `order` (SC_ASCII or SC_COLLATE1); 0 for
/// the NUL, below every character.
pub fn weightOf(ext: *const ExtLocale, c: u8, order: u32) u8 {
    if (c == 0) return 0;
    if (order == locale.SC_ASCII) return @intCast(_chars.toUpper(c));
    return ext.primary[c];
}

/// The order a compare type names: SC_ASCII for any number that is none.
pub fn orderOf(compare_type: u32) u32 {
    return if (compare_type == locale.SC_COLLATE1 or compare_type == locale.SC_COLLATE2) compare_type else locale.SC_ASCII;
}

/// -1, 0 or 1, as `a` is below, the same as or above `b`.
pub fn sign(a: u8, b: u8) i32 {
    return if (a < b) -1 else if (a > b) 1 else 0;
}

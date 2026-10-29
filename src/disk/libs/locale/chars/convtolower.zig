// SPDX-License-Identifier: MIT
//! ConvToLower: a character as a small letter.

const sdk = @import("sdk");
const locale = sdk.locale;
const LocaleBase = @import("../locale_base.zig").LocaleBase;
const _chars = @import("_chars.zig");

/// Answers a character as a small letter.
///
/// SYNOPSIS:
/// ```zig
/// fn ConvToLower(_: *LocaleBase, loc: *const locale.Locale, character: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale.
/// - `character` - a character of the locale's code set, by its number.
///
/// RESULT:
/// The small letter for a capital one; anything else as it is. A to Z and À to Þ but × are
/// answered as a to z and à to þ.
/// A character past 255 is answered as it is.
///
/// BEHAVIOR:
/// The cases are the code set's: Latin-1's, the same in every language.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe; it reads no memory but its argument.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// The answer fits a byte whenever the character does, so a string can be
/// changed in place.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ConvToUpper`, `IsUpper`
///
/// EXAMPLES:
/// ```zig
/// const small: u8 = @intCast(lb.ConvToLower(loc, key));
/// ```
pub fn ConvToLower(_: *LocaleBase, loc: *const locale.Locale, character: u32) u32 {
    _ = loc;
    return _chars.toLower(character);
}

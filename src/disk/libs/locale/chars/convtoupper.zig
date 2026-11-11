// SPDX-License-Identifier: MIT
//! ConvToUpper: a character as a capital letter.

const sdk = @import("sdk");
const locale = sdk.locale;
const LocaleBase = @import("../locale_base.zig").LocaleBase;
const _chars = @import("_chars.zig");

/// Answers a character as a capital letter.
///
/// SYNOPSIS:
/// ```zig
/// fn ConvToUpper(_: *LocaleBase, loc: *const locale.Locale, character: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -84.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale.
/// - `character` - a character, by its code point.
///
/// RESULT:
/// The capital letter for a small one; anything else as it is. `a` is
/// answered as `A`, `ä` as `Ä`, `ÿ` as `Ÿ`, `ω` as `Ω`; `ß` has no
/// capital of its own and stays as it is.
///
/// BEHAVIOR:
/// The cases are Unicode's simple ones, a character to a character, the
/// same in every language.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe; it reads a table.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// The answer may take another number of bytes in UTF-8 than the
/// character did (`ı` is two, `I` one), so a string changed character by
/// character is written anew, not in place.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ConvToLower`, `IsLower`
///
/// EXAMPLES:
/// ```zig
/// var at: usize = 0;
/// var length: usize = 0;
/// while (at < word.len) length += utf8.encode(lb.ConvToUpper(loc, utf8.next(word, &at)), capitals[length..][0..4]);
/// ```
pub fn ConvToUpper(_: *LocaleBase, loc: *const locale.Locale, character: u32) u32 {
    _ = loc;
    return _chars.toUpper(character);
}

// SPDX-License-Identifier: MIT
//! IsAlNum: whether a character is a letter or a digit.

const sdk = @import("sdk");
const locale = sdk.locale;
const LocaleBase = @import("../locale_base.zig").LocaleBase;
const _chars = @import("_chars.zig");

/// Says whether a character is a letter or a digit.
///
/// SYNOPSIS:
/// ```zig
/// fn IsAlNum(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale.
/// - `character` - a character of the locale's code set, by its number.
///
/// RESULT:
/// True for a letter - A to Z, a to z, À to ÿ but × and ÷, and ª, µ, º -
/// or a digit, 0 to 9. False for anything past 255.
///
/// BEHAVIOR:
/// The classes are the code set's: Latin-1's, the same in every
/// language. A language decides the order its letters sort in
/// (`StrnCmp`), not which characters are letters.
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
/// A byte from a string is handed over as it is: the code set's
/// characters are its bytes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `IsAlpha`, `IsDigit`, `IsPunct`
///
/// EXAMPLES:
/// ```zig
/// while (at < name.len and lb.IsAlNum(loc, name[at])) at += 1;
/// ```
pub fn IsAlNum(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool {
    _ = loc;
    return _chars.is(character, _chars.alpha | _chars.digit);
}

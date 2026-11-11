// SPDX-License-Identifier: MIT
//! IsPrint: whether a character is printed, blanks included.

const sdk = @import("sdk");
const locale = sdk.locale;
const LocaleBase = @import("../locale_base.zig").LocaleBase;
const _chars = @import("_chars.zig");

/// Says whether a character is printed, blanks included.
///
/// SYNOPSIS:
/// ```zig
/// fn IsPrint(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale.
/// - `character` - a character, by its code point.
///
/// RESULT:
/// True for what IsGraph is true for, and for the spaces - the space
/// (32), the one that does not break (160) and the others of Unicode's.
///
/// BEHAVIOR:
/// The classes are Unicode's, from each character's general category,
/// the same in every language. A language decides the order its letters
/// sort in (`StrnCmp`), not which characters are letters.
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
/// A character of a string is its code point, as `sdk.utility.utf8.next`
/// reads it; a byte past 127 alone is part of one.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `IsGraph`, `IsCntrl`
///
/// EXAMPLES:
/// ```zig
/// const shown: u32 = if (lb.IsPrint(loc, char)) char else '.';
/// ```
pub fn IsPrint(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool {
    _ = loc;
    return _chars.is(character, _chars.print);
}

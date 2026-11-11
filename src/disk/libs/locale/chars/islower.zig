// SPDX-License-Identifier: MIT
//! IsLower: whether a character is a small letter.

const sdk = @import("sdk");
const locale = sdk.locale;
const LocaleBase = @import("../locale_base.zig").LocaleBase;
const _chars = @import("_chars.zig");

/// Says whether a character is a small letter.
///
/// SYNOPSIS:
/// ```zig
/// fn IsLower(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale.
/// - `character` - a character, by its code point.
///
/// RESULT:
/// True for a small letter of any script: `a` to `z`, `ß`, `ÿ`, `µ`,
/// `ω`, `ж`.
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
/// `IsUpper`, `ConvToUpper`
///
/// EXAMPLES:
/// ```zig
/// if (lb.IsLower(loc, first)) first = lb.ConvToUpper(loc, first);
/// ```
pub fn IsLower(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool {
    _ = loc;
    return _chars.is(character, _chars.lower);
}

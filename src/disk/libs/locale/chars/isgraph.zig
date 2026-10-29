// SPDX-License-Identifier: MIT
//! IsGraph: whether a character is printed and not blank.

const sdk = @import("sdk");
const locale = sdk.locale;
const LocaleBase = @import("../locale_base.zig").LocaleBase;
const _chars = @import("_chars.zig");

/// Says whether a character is printed and not blank.
///
/// SYNOPSIS:
/// ```zig
/// fn IsGraph(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale.
/// - `character` - a character of the locale's code set, by its number.
///
/// RESULT:
/// True for 33 to 126 and 161 to 255: a letter, a digit or punctuation. False for anything past 255.
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
/// `IsPrint`, `IsSpace`, `IsPunct`
///
/// EXAMPLES:
/// ```zig
/// if (!lb.IsGraph(loc, key)) return; // a blank or a control character
/// ```
pub fn IsGraph(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool {
    _ = loc;
    return _chars.is(character, _chars.graph);
}

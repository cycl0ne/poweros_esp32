// SPDX-License-Identifier: MIT
//! IsSpace: whether a character is blank.

const sdk = @import("sdk");
const locale = sdk.locale;
const LocaleBase = @import("../locale_base.zig").LocaleBase;
const _chars = @import("_chars.zig");

/// Says whether a character is blank.
///
/// SYNOPSIS:
/// ```zig
/// fn IsSpace(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale.
/// - `character` - a character, by its code point.
///
/// RESULT:
/// True for the space, for tab, line feed, vertical tab, form feed and
/// carriage return (9 to 13), for the space that does not break (160),
/// for Unicode's other spaces, and for its line and paragraph
/// separators.
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
/// `IsPrint`, `IsGraph`
///
/// EXAMPLES:
/// ```zig
/// var after = at;
/// while (at < text.len and lb.IsSpace(loc, utf8.next(text, &after))) at = after;
/// ```
pub fn IsSpace(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool {
    _ = loc;
    return _chars.is(character, _chars.space);
}

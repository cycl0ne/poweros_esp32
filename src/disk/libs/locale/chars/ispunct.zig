// SPDX-License-Identifier: MIT
//! IsPunct: whether a character is punctuation.

const sdk = @import("sdk");
const locale = sdk.locale;
const LocaleBase = @import("../locale_base.zig").LocaleBase;
const _chars = @import("_chars.zig");

/// Says whether a character is punctuation.
///
/// SYNOPSIS:
/// ```zig
/// fn IsPunct(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale.
/// - `character` - a character, by its code point.
///
/// RESULT:
/// True for a character that is printed and neither blank, a letter nor
/// a digit: `!` to `/`, `:` to `@`, `[` to `` ` ``, `{` to `~`, `¡` to `¿`
/// but `ª`, `µ` and `º`, `×` and `÷`, and past Latin-1 the marks, the
/// numbers like `½`, the symbols - `€`, the emoji - the format characters
/// and those for private use.
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
/// `IsGraph`, `IsAlNum`
///
/// EXAMPLES:
/// ```zig
/// var after = at;
/// while (at < text.len and lb.IsPunct(loc, utf8.next(text, &after))) at = after;
/// ```
pub fn IsPunct(_: *LocaleBase, loc: *const locale.Locale, character: u32) bool {
    _ = loc;
    return _chars.is(character, _chars.punct);
}

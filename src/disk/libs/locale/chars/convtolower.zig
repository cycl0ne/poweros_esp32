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
/// - `character` - a character, by its code point.
///
/// RESULT:
/// The small letter for a capital one; anything else as it is. `A` is
/// answered as `a`, `Ä` as `ä`, `Ω` as `ω`, `Ж` as `ж`.
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
/// `ConvToUpper`, `IsUpper`
///
/// EXAMPLES:
/// ```zig
/// const small = lb.ConvToLower(loc, message.code); // a VANILLAKEY
/// ```
pub fn ConvToLower(_: *LocaleBase, loc: *const locale.Locale, character: u32) u32 {
    _ = loc;
    return _chars.toLower(character);
}

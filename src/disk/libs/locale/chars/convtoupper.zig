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
/// - `character` - a character of the locale's code set, by its number.
///
/// RESULT:
/// The capital letter for a small one; anything else as it is. a to z and à to þ but ÷ are
/// answered as A to Z and À to Þ; ß, ÿ and µ have no capital in the
/// code set and stay as they are.
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
/// `ConvToLower`, `IsLower`
///
/// EXAMPLES:
/// ```zig
/// for (word) |*c| c.* = @intCast(lb.ConvToUpper(loc, c.*));
/// ```
pub fn ConvToUpper(_: *LocaleBase, loc: *const locale.Locale, character: u32) u32 {
    _ = loc;
    return _chars.toUpper(character);
}

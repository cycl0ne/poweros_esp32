// SPDX-License-Identifier: MIT
//! StrnCmp: two strings compared in the locale's order.

const sdk = @import("sdk");
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const _compare = @import("_compare.zig");
const LocaleBase = _base.LocaleBase;

/// Compares two strings in the order of the locale's language.
///
/// SYNOPSIS:
/// ```zig
/// fn StrnCmp(_: *LocaleBase, loc: *const locale.Locale, string1: [*:0]const u8, string2: [*:0]const u8, length: i32, compare_type: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -88.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale.
/// - `string1`, `string2` - the strings, in the locale's code set.
/// - `length` - the most bytes of each to compare; below 0 for all.
/// - `compare_type` - SC_ASCII, SC_COLLATE1 or SC_COLLATE2; any other
///   number is taken as SC_ASCII.
///
/// RESULT:
/// -1 when `string1` comes first, 0 when the two are the same in that
/// order, 1 when `string2` comes first. 0 when `length` is 0.
///
/// BEHAVIOR:
/// SC_ASCII leaves the case of letters out and compares their capitals
/// by their codes, as a file name is compared. SC_COLLATE1 leaves case
/// and accent out and orders the letters as the language does: in
/// Swedish Å, Ä and Ö come after Z, in Spanish Ñ after N, and anything
/// that is not a letter comes before every letter. SC_COLLATE2 orders as
/// SC_COLLATE1 and, where that finds the two the same, by the first byte
/// they differ in: the order a sorted list is shown in, where `apple`,
/// `Apple` and `äpple` stand together and always in the same order.
///
/// A string that ends where the other goes on comes first.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe; it reads the locale and the strings.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// To sort many strings, StrConvert each once and compare the keys
/// byte by byte: the order is the same.
///
/// BUGS:
/// A letter is weighed alone: `ß` is an `s` and `æ` an `a`, not two
/// letters each.
///
/// SEE ALSO:
/// `StrConvert`, utility.library `Stricmp`
///
/// EXAMPLES:
/// ```zig
/// if (lb.StrnCmp(loc, left.name, right.name, -1, locale.SC_COLLATE2) > 0) swap(left, right);
/// ```
pub fn StrnCmp(_: *LocaleBase, loc: *const locale.Locale, string1: [*:0]const u8, string2: [*:0]const u8, length: i32, compare_type: u32) i32 {
    const ext = _base.extOf(loc);
    const order = _compare.orderOf(compare_type);
    const first = if (order == locale.SC_COLLATE2) locale.SC_COLLATE1 else order;
    var at: usize = 0;
    while (length < 0 or at < @as(usize, @intCast(length))) : (at += 1) {
        const one = _compare.weightOf(ext, string1[at], first);
        const two = _compare.weightOf(ext, string2[at], first);
        if (one != two) return _compare.sign(one, two);
        if (one == 0) break;
    }
    if (order != locale.SC_COLLATE2) return 0;
    // The same by their weights, so as long as each other: the first byte
    // that differs decides.
    var again: usize = 0;
    while (again < at) : (again += 1) {
        if (string1[again] != string2[again]) return _compare.sign(string1[again], string2[again]);
    }
    return 0;
}

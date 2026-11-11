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
/// - `string1`, `string2` - the strings, UTF-8.
/// - `length` - the most bytes of each to compare; below 0 for all.
/// - `compare_type` - SC_ASCII, SC_COLLATE1 or SC_COLLATE2; any other
///   number is taken as SC_ASCII.
///
/// RESULT:
/// -1 when `string1` comes first, 0 when the two are the same in that
/// order, 1 when `string2` comes first. 0 when `length` is 0.
///
/// BEHAVIOR:
/// The strings are compared character by character. SC_ASCII leaves the
/// case of letters out and compares their capitals by their code points,
/// as a file name is compared. SC_COLLATE1 leaves case and marks out and
/// orders the letters as the language does: in Swedish Å, Ä and Ö come
/// after Z, in Spanish Ñ after N; `ł` is an `l` and `č` a `c`. Anything
/// that is not a letter comes before every letter, the Latin letters
/// before those of other scripts - Greek, Cyrillic, the kana, the
/// ideographs - which are in the order of their code points, and a mark
/// written on the letter before counts for nothing. SC_COLLATE2 orders
/// as SC_COLLATE1 and, where that finds the two the same, by the first
/// byte they differ in: the order a sorted list is shown in, where
/// `apple`, `Apple` and `äpple` stand together and always in the same
/// order.
///
/// A string that ends where the other goes on comes first. A character
/// cut by `length` is compared as what of it is left.
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
/// letters each. The letters of other scripts have no language's order.
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
    const one = _compare.bounded(string1, length);
    const two = _compare.bounded(string2, length);
    var at_one: usize = 0;
    var at_two: usize = 0;
    while (true) {
        const mine = _compare.nextKey(ext, one, &at_one, first);
        const theirs = _compare.nextKey(ext, two, &at_two, first);
        if (mine != theirs) return _compare.sign(mine, theirs);
        if (mine == 0) break;
    }
    if (order != locale.SC_COLLATE2) return 0;
    // The same by their keys: the first byte that differs decides, and
    // the one that ends first comes first.
    for (one[0..@min(one.len, two.len)], two[0..@min(one.len, two.len)]) |byte_one, byte_two| {
        if (byte_one != byte_two) return _compare.sign(byte_one, byte_two);
    }
    return _compare.sign(@intCast(one.len), @intCast(two.len));
}

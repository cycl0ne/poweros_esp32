// SPDX-License-Identifier: MIT
//! StrConvert: a string as a key that sorts byte by byte.

const sdk = @import("sdk");
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const _compare = @import("_compare.zig");
const LocaleBase = _base.LocaleBase;

/// Writes a string as a key whose plain byte order is the string's order
/// in the locale.
///
/// SYNOPSIS:
/// ```zig
/// fn StrConvert(_: *LocaleBase, loc: *const locale.Locale, string: [*:0]const u8, buffer: [*]u8, buffer_size: u32, compare_type: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -92.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale.
/// - `string` - the string, in the locale's code set.
/// - `buffer` - where the key goes.
/// - `buffer_size` - its size in bytes, the NUL that ends the key
///   counted.
/// - `compare_type` - SC_ASCII, SC_COLLATE1 or SC_COLLATE2; any other
///   number is taken as SC_ASCII.
///
/// RESULT:
/// The bytes of the key written, the NUL left out; 0 when `buffer_size`
/// is 0, and nothing is written then.
///
/// BEHAVIOR:
/// Two keys compared byte by byte, as unsigned bytes, up to the NUL that
/// ends the first, come out as StrnCmp compares their strings with the
/// same type. A key is one byte
/// per character for SC_ASCII and SC_COLLATE1, two and one more for
/// SC_COLLATE2.
///
/// A key cut short by the buffer still orders by what it holds.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe; it reads the locale and the string.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The key is the caller's, in the caller's buffer.
///
/// NOTES:
/// A key is only good with the locale it was made with: another language
/// orders differently.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StrnCmp`
///
/// EXAMPLES:
/// ```zig
/// var key: [2 * 108 + 2]u8 = undefined;
/// _ = lb.StrConvert(loc, name, &key, key.len, locale.SC_COLLATE2);
/// ```
pub fn StrConvert(_: *LocaleBase, loc: *const locale.Locale, string: [*:0]const u8, buffer: [*]u8, buffer_size: u32, compare_type: u32) u32 {
    if (buffer_size == 0) return 0;
    const ext = _base.extOf(loc);
    const order = _compare.orderOf(compare_type);
    const first = if (order == locale.SC_COLLATE2) locale.SC_COLLATE1 else order;
    const room = buffer_size - 1;
    var written: u32 = 0;
    var at: usize = 0;
    while (string[at] != 0 and written < room) : (at += 1) {
        buffer[written] = _compare.weightOf(ext, string[at], first);
        written += 1;
    }
    if (order == locale.SC_COLLATE2 and written < room) {
        buffer[written] = 1;
        written += 1;
        at = 0;
        while (string[at] != 0 and written < room) : (at += 1) {
            buffer[written] = string[at];
            written += 1;
        }
    }
    buffer[written] = 0;
    return written;
}

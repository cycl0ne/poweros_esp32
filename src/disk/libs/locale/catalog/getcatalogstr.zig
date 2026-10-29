// SPDX-License-Identifier: MIT
//! GetCatalogStr: one of a catalog's strings.

const sdk = @import("sdk");
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const LocaleBase = _base.LocaleBase;

/// Answers one of a catalog's strings, or the one built in.
///
/// SYNOPSIS:
/// ```zig
/// fn GetCatalogStr(_: *LocaleBase, catalog: ?*const locale.Catalog, string_num: i32, default_string: [*:0]const u8) [*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -116.
///
/// INPUTS:
/// - `catalog` - a catalog from OpenCatalogA, or null.
/// - `string_num` - the string's number, as the program's `.cd` file
///   gives it.
/// - `default_string` - the string built into the program.
///
/// RESULT:
/// The catalog's string of that number, in the locale's code set;
/// `default_string` when `catalog` is null or has none of that number.
///
/// BEHAVIOR:
/// The strings are sorted by number when the catalog is read, so this is
/// a binary search.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe; a catalog does not change while it is held.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The string is the catalog's, good until it is closed, or the caller's
/// own `default_string`.
///
/// NOTES:
/// A translation may leave strings out: each is the one built in.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenCatalogA`, `CloseCatalog`, sdk.locale `Strings`
///
/// EXAMPLES:
/// ```zig
/// _ = dl.PutStr(lb.GetCatalogStr(catalog, MSG_HELLO, "Hello\n"));
/// ```
pub fn GetCatalogStr(_: *LocaleBase, catalog: ?*const locale.Catalog, string_num: i32, default_string: [*:0]const u8) [*:0]const u8 {
    const ext = _base.catalogOf(catalog orelse return default_string);
    var low: usize = 0;
    var high: usize = ext.count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = ext.entries[middle];
        if (entry.id == string_num) return entry.text;
        if (entry.id < string_num) low = middle + 1 else high = middle;
    }
    return default_string;
}

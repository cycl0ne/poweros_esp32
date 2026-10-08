// SPDX-License-Identifier: MIT
//! MatchToolValue: whether a tool type's value names a word.

const sdk = @import("sdk");
const IconBase = @import("../icon_base.zig").IconBase;
const _tooltype = @import("_tooltype.zig");

/// Whether `value` names `wanted` among its alternatives.
///
/// SYNOPSIS:
/// ```zig
/// fn MatchToolValue(base: *IconBase, value: [*:0]const u8, wanted: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `value` - a tool type's value, as `FindToolType` gives it.
/// - `wanted` - one word.
///
/// RESULT:
/// True when one of `value`'s alternatives is `wanted`.
///
/// BEHAVIOR:
/// `value` is one word or several with `|` between them; each is
/// compared whole with `wanted`, in any case.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: any.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// None.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindToolType`
///
/// EXAMPLES:
/// ```zig
/// // "text" matches "text" and "TEXT", not "data"; "a|b|c" matches
/// // "a" and "b", not "d", and not "a|b".
/// if (ib.FindToolType(object.tool_types, "FILETYPE")) |kind| {
///     if (ib.MatchToolValue(kind, "text")) {}
/// }
/// ```
pub fn MatchToolValue(base: *IconBase, value: [*:0]const u8, wanted: [*:0]const u8) bool {
    _ = base;
    const word = wanted[0.._tooltype.length(wanted)];
    const all = value[0.._tooltype.length(value)];
    var start: usize = 0;
    while (start <= all.len) {
        var end = start;
        while (end < all.len and all[end] != '|') end += 1;
        if (_tooltype.same(all[start..end], word)) return true;
        start = end + 1;
    }
    return false;
}

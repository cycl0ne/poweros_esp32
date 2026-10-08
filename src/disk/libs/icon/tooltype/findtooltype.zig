// SPDX-License-Identifier: MIT
//! FindToolType: a tool type's value.

const sdk = @import("sdk");
const IconBase = @import("../icon_base.zig").IconBase;
const _tooltype = @import("_tooltype.zig");

/// The value of the tool type `name` in `types`.
///
/// SYNOPSIS:
/// ```zig
/// fn FindToolType(base: *IconBase, types: ?[*]const ?[*:0]const u8, name: [*:0]const u8) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `types` - an icon's `tool_types`: strings ended by a null. Null
///   finds nothing.
/// - `name` - the tool type, in any case.
///
/// RESULT:
/// What follows the `=` of the first tool type called `name`; an empty
/// string for one written without `=`; null when there is none.
///
/// BEHAVIOR:
/// A tool type is `NAME=value` or `NAME`. It is called `name` when it
/// starts with `name` in any case and then ends or has its `=`; one that
/// only starts with it - `FILETYPES` for `FILETYPE` - is another, and
/// the search goes on.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: any.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The answer points into `types`' own string and lives as long as it.
///
/// NOTES:
/// `MatchToolValue` then tells whether the value names a particular
/// word.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MatchToolValue`
///
/// EXAMPLES:
/// ```zig
/// // tool types "FILETYPE=text" and "TEMPDIR=:t":
/// // FindToolType(types, "FILETYPE") and (types, "filetype") are "text",
/// // (types, "TEMPDIR") is ":t", (types, "MAXSIZE") is null.
/// const value = ib.FindToolType(object.tool_types, "FILETYPE");
/// ```
pub fn FindToolType(base: *IconBase, types: ?[*]const ?[*:0]const u8, name: [*:0]const u8) ?[*:0]const u8 {
    _ = base;
    const list = types orelse return null;
    const wanted = name[0.._tooltype.length(name)];
    var index: usize = 0;
    while (list[index]) |entry| : (index += 1) {
        if (!_tooltype.startsWith(entry, wanted)) continue;
        const rest = entry + wanted.len;
        if (rest[0] == 0) return rest;
        if (rest[0] == '=') return rest + 1;
    }
    return null;
}

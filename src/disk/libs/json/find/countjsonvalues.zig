// SPDX-License-Identifier: MIT
//! CountJSONValues: how many values an array or object holds.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;

/// Counts the values in an array or an object.
///
/// SYNOPSIS:
/// ```zig
/// fn CountJSONValues(base: *JSONBase, container: ?*const json.Value) u32
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `container`: the array or object; null, or any other value, holds
///   none.
///
/// RESULT:
/// How many items or members it has; 0 for anything else.
///
/// BEHAVIOR:
/// The count the array or object keeps, as `count` has it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Locks: none taken; the caller keeps other tasks off the document.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetJSONItem`, `InsertJSONItem`
///
/// EXAMPLES:
/// ```zig
/// const hours = jb.CountJSONValues(jb.FindJSONPointer(document.root, "/hourly/time"));
/// ```
pub fn CountJSONValues(_: *JSONBase, container: ?*const json.Value) u32 {
    const holder = container orelse return 0;
    if (holder.kind != json.JSON_ARRAY and holder.kind != json.JSON_OBJECT) return 0;
    return holder.count;
}

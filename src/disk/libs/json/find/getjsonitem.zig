// SPDX-License-Identifier: MIT
//! GetJSONItem: an array's or object's value by its place.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;

/// Finds the value at `index` in an array or an object.
///
/// SYNOPSIS:
/// ```zig
/// fn GetJSONItem(base: *JSONBase, container: ?*const json.Value, index: u32) ?*json.Value
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `container`: the array or object; null, or any other value, finds
///   nothing.
/// - `index`: the place, from 0.
///
/// RESULT:
/// The value; null past the last.
///
/// BEHAVIOR:
/// The values are counted from whichever end is nearer. An object's
/// members are in the order of its text, or as they were placed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; nothing is allocated.
/// - Locks: none taken; the caller keeps other tasks off the document.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The value is the document's.
///
/// NOTES:
/// Every value is a step from the next, so going through a long array
/// item by item is quicker along `first` and `next` than by index.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CountJSONValues`, `FindJSONMember`, `FindJSONPointer`, `InsertJSONItem`
///
/// EXAMPLES:
/// ```zig
/// const days = jb.FindJSONPointer(document.root, "/daily/time");
/// const tomorrow = jb.GetJSONString(jb.GetJSONItem(days, 1), null);
/// ```
pub fn GetJSONItem(_: *JSONBase, container: ?*const json.Value, index: u32) ?*json.Value {
    const holder = container orelse return null;
    if (holder.kind != json.JSON_ARRAY and holder.kind != json.JSON_OBJECT) return null;
    if (index >= holder.count) return null;
    if (index < holder.count / 2) {
        var at = holder.first;
        var left = index;
        while (left > 0) : (left -= 1) at = at.?.next;
        return at;
    }
    var at = holder.last;
    var left = holder.count - 1 - index;
    while (left > 0) : (left -= 1) at = at.?.prev;
    return at;
}

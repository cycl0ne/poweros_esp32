// SPDX-License-Identifier: MIT
//! InsertJSONItem: a value put into an array at a place.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("../document/_document.zig");

/// Puts a value into an array.
///
/// SYNOPSIS:
/// ```zig
/// fn InsertJSONItem(base: *JSONBase, array: *json.Value, value: *json.Value, index: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -96.
///
/// INPUTS:
/// - `array`: the array.
/// - `value`: the value, made in the array's document.
/// - `index`: the item it goes before, from 0; `JSON_END`, or any place
///   past the last, puts it after the last.
///
/// RESULT:
/// True; false, and nothing changed, when `array` is no array, the value
/// is another document's, or the array is inside the value - which would
/// hold itself.
///
/// BEHAVIOR:
/// A value placed elsewhere - in an array, an object, or as the root - is
/// taken out of there first, its name dropped; `index` counts the array
/// as it is after that, which matters when the value was in it already.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; nothing is allocated.
/// - Locks: none taken; the caller keeps other tasks off the document.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The values stay the document's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetJSONItem`, `RemoveJSONValue`, `SetJSONMember`
///
/// EXAMPLES:
/// ```zig
/// // The place shown last first in the list.
/// _ = jb.InsertJSONItem(places, place, 0);
/// ```
pub fn InsertJSONItem(_: *JSONBase, array: *json.Value, value: *json.Value, index: u32) bool {
    if (!_document.placeable(array, json.JSON_ARRAY, value)) return false;
    _document.unlink(value);
    var before = array.first;
    var left = index;
    while (left > 0) : (left -= 1) {
        const at = before orelse break;
        before = at.next;
    }
    _document.link(array, value, before);
    return true;
}

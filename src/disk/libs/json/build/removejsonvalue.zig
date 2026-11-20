// SPDX-License-Identifier: MIT
//! RemoveJSONValue: a value taken out of where it is placed.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("../document/_document.zig");

/// Takes a value out of its array or object, or off the root.
///
/// SYNOPSIS:
/// ```zig
/// fn RemoveJSONValue(base: *JSONBase, value: *json.Value) void
/// ```
///
/// SINCE: 1.0. LVO -100.
///
/// INPUTS:
/// - `value`: the value.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The value leaves its array or object - the values beside it closing
/// up, the count one less - or stops being its document's root, and
/// loses its name. What it holds goes with it. A value placed nowhere
/// stays so.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe in itself; nothing is allocated.
/// - Locks: none taken; the caller keeps other tasks off the document.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The value stays the document's and can be placed again; its memory
/// goes with the document.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `InsertJSONItem`, `SetJSONMember`, `SetJSONRoot`
///
/// EXAMPLES:
/// ```zig
/// if (jb.GetJSONItem(places, picked)) |place| jb.RemoveJSONValue(place);
/// ```
pub fn RemoveJSONValue(_: *JSONBase, value: *json.Value) void {
    _document.unlink(value);
}

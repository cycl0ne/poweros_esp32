// SPDX-License-Identifier: MIT
//! CreateJSONNumber: a new number.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("../document/_document.zig");

/// Makes a new number.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateJSONNumber(base: *JSONBase, document: *json.Document, number: f64) ?*json.Value
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `document`: the document to make it in.
/// - `number`: its value.
///
/// RESULT:
/// The number, placed nowhere; null without the memory.
///
/// BEHAVIOR:
/// Written out, the number takes the fewest digits that read back as the
/// same double: 3.6 as `3.6`, 2.0 as `2`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none taken; the caller keeps other tasks off the document.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The value is the document's, given back with it.
///
/// NOTES:
/// JSON has no infinity and no NaN: either is written as `null`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateJSONInteger`, `GetJSONNumber`, `FormatJSON`
///
/// EXAMPLES:
/// ```zig
/// const latitude = jb.CreateJSONNumber(document, 48.13743) orelse return;
/// _ = jb.SetJSONMember(place, "latitude", latitude);
/// ```
pub fn CreateJSONNumber(base: *JSONBase, document: *json.Document, number: f64) ?*json.Value {
    const made = _document.value(base, document, json.JSON_NUMBER) orelse return null;
    made.number = number;
    return made;
}

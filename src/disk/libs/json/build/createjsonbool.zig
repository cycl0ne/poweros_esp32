// SPDX-License-Identifier: MIT
//! CreateJSONBool: a new `true` or `false`.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("../document/_document.zig");

/// Makes a new boolean.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateJSONBool(base: *JSONBase, document: *json.Document, truth: bool) ?*json.Value
/// ```
///
/// SINCE: 1.0. LVO -84.
///
/// INPUTS:
/// - `document`: the document to make it in.
/// - `truth`: its value.
///
/// RESULT:
/// The boolean, placed nowhere; null without the memory.
///
/// BEHAVIOR:
/// Written out as `true` or `false`.
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
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetJSONBool`, `CreateJSONValue`
///
/// EXAMPLES:
/// ```zig
/// const fahrenheit = jb.CreateJSONBool(document, true) orelse return;
/// _ = jb.SetJSONMember(document.root.?, "fahrenheit", fahrenheit);
/// ```
pub fn CreateJSONBool(base: *JSONBase, document: *json.Document, truth: bool) ?*json.Value {
    const made = _document.value(base, document, json.JSON_BOOLEAN) orelse return null;
    made.truth = truth;
    return made;
}

// SPDX-License-Identifier: MIT
//! CreateJSONValue: a new value of a kind, empty or zero.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("../document/_document.zig");

/// Makes a new value of a kind.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateJSONValue(base: *JSONBase, document: *json.Document, kind: u32) ?*json.Value
/// ```
///
/// SINCE: 1.0. LVO -68.
///
/// INPUTS:
/// - `document`: the document to make it in.
/// - `kind`: `JSON_NULL`, `JSON_BOOLEAN`, `JSON_NUMBER`, `JSON_STRING`,
///   `JSON_ARRAY` or `JSON_OBJECT`.
///
/// RESULT:
/// The value - `null`, `false`, 0, an empty string, an empty array or
/// object - placed nowhere; null without the memory or for a kind that
/// is none of those.
///
/// BEHAVIOR:
/// A value placed nowhere is in no array or object and is not the root:
/// `SetJSONMember`, `InsertJSONItem` or `SetJSONRoot` place it. The
/// other `Create...` calls make a value with its content.
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
/// `CreateJSONNumber`, `CreateJSONString`, `CreateJSONBool`, `SetJSONMember`
///
/// EXAMPLES:
/// ```zig
/// const place = jb.CreateJSONValue(document, json.JSON_OBJECT) orelse return;
/// _ = jb.InsertJSONItem(places, place, json.JSON_END);
/// ```
pub fn CreateJSONValue(base: *JSONBase, document: *json.Document, kind: u32) ?*json.Value {
    if (kind > json.JSON_OBJECT) return null;
    return _document.value(base, document, kind);
}

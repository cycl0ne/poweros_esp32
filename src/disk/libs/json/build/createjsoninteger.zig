// SPDX-License-Identifier: MIT
//! CreateJSONInteger: a new whole number, kept exactly.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("../document/_document.zig");

/// Makes a new whole number.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateJSONInteger(base: *JSONBase, document: *json.Document, integer: i64) ?*json.Value
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// - `document`: the document to make it in.
/// - `integer`: its value.
///
/// RESULT:
/// The number, placed nowhere; null without the memory.
///
/// BEHAVIOR:
/// The number is kept exactly (`JSONVF_INTEGER`) and written digit for
/// digit, past 2^53 too; its `number` is the double nearest it.
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
/// `CreateJSONNumber`, `GetJSONInteger`
///
/// EXAMPLES:
/// ```zig
/// const shown = jb.CreateJSONInteger(document, 2) orelse return;
/// _ = jb.SetJSONMember(document.root.?, "shown", shown);
/// ```
pub fn CreateJSONInteger(base: *JSONBase, document: *json.Document, integer: i64) ?*json.Value {
    const made = _document.value(base, document, json.JSON_NUMBER) orelse return null;
    made.integer = integer;
    made.number = @floatFromInt(integer);
    made.flags = json.JSONVF_INTEGER;
    return made;
}

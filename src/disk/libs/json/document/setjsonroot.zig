// SPDX-License-Identifier: MIT
//! SetJSONRoot: a value made a document's outermost one.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("_document.zig");

/// Makes a value the document's root.
///
/// SYNOPSIS:
/// ```zig
/// fn SetJSONRoot(base: *JSONBase, document: *json.Document, value: ?*json.Value) bool
/// ```
///
/// SINCE: 1.0. LVO -104.
///
/// INPUTS:
/// - `document`: the document.
/// - `value`: a value made in it, or null for no root.
///
/// RESULT:
/// True; false, and nothing changed, when the value is another
/// document's.
///
/// BEHAVIOR:
/// A value placed in an array or object is taken out of it first. The
/// root before it is placed nowhere, and can be put somewhere again.
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
/// `CreateJSONDocument`, `RemoveJSONValue`, `WriteJSONFile`
///
/// EXAMPLES:
/// ```zig
/// const top = jb.CreateJSONValue(document, json.JSON_OBJECT) orelse return;
/// _ = jb.SetJSONRoot(document, top);
/// ```
pub fn SetJSONRoot(_: *JSONBase, document: *json.Document, value: ?*json.Value) bool {
    if (value) |made| {
        if (made.document != document) return false;
        _document.unlink(made);
    }
    if (document.root) |old| _document.unlink(old);
    document.root = value;
    return true;
}

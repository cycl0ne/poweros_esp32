// SPDX-License-Identifier: MIT
//! CreateJSONDocument: an empty document to build values in.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("_document.zig");

/// Makes an empty document.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateJSONDocument(base: *JSONBase) ?*json.Document
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The document, with no root; null without the memory.
///
/// BEHAVIOR:
/// The document is a memory pool of its own and the root that will be;
/// the `Create...` calls make values in it, `SetJSONRoot`,
/// `SetJSONMember` and `InsertJSONItem` put them together.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The document is the caller's, given back with `DisposeJSONDocument`,
/// and every value made in it with it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateJSONValue`, `SetJSONRoot`, `DisposeJSONDocument`, `ParseJSON`
///
/// EXAMPLES:
/// ```zig
/// const document = jb.CreateJSONDocument() orelse return;
/// defer jb.DisposeJSONDocument(document);
/// const places = jb.CreateJSONValue(document, json.JSON_ARRAY) orelse return;
/// _ = jb.SetJSONRoot(document, places);
/// ```
pub fn CreateJSONDocument(base: *JSONBase) ?*json.Document {
    return _document.make(base, 0);
}

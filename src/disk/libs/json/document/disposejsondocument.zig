// SPDX-License-Identifier: MIT
//! DisposeJSONDocument: a document and every value in it given back.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("_document.zig");

/// Gives a document back, and every value made in it.
///
/// SYNOPSIS:
/// ```zig
/// fn DisposeJSONDocument(base: *JSONBase, document: ?*json.Document) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `document`: what `ParseJSON`, `ReadJSONFile` or
///   `CreateJSONDocument` made; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The document's pool is given back whole: its values - placed or not,
/// taken out or never put in - their names and their texts.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing of the document may be used afterwards: not a value, not a
/// text `GetJSONString` gave.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParseJSON`, `ReadJSONFile`, `CreateJSONDocument`
///
/// EXAMPLES:
/// ```zig
/// const document = jb.ParseJSON(text.ptr, text.len, 0, null) orelse return;
/// defer jb.DisposeJSONDocument(document);
/// ```
pub fn DisposeJSONDocument(base: *JSONBase, document: ?*json.Document) void {
    const made = document orelse return;
    _document.free(base, made);
}

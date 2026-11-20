// SPDX-License-Identifier: MIT
//! CreateJSONString: a new string, its text copied.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("../document/_document.zig");

/// Makes a new string.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateJSONString(base: *JSONBase, document: *json.Document, text: [*]const u8, length: u32) ?*json.Value
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `document`: the document to make it in.
/// - `text`: the text, UTF-8.
/// - `length`: how many bytes of it; `JSON_TERMINATED` for all of it up
///   to its NUL.
///
/// RESULT:
/// The string, placed nowhere; null without the memory.
///
/// BEHAVIOR:
/// The text is copied, with a NUL after it, and needs no escapes: they
/// are made as it is written out, where bytes that are not UTF-8 are
/// written as U+FFFD.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none taken; the caller keeps other tasks off the document.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The text stays the caller's; the value and its copy are the
/// document's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetJSONString`, `SetJSONMember`
///
/// EXAMPLES:
/// ```zig
/// const name = jb.CreateJSONString(document, "München", json.JSON_TERMINATED) orelse return;
/// _ = jb.SetJSONMember(place, "name", name);
/// ```
pub fn CreateJSONString(base: *JSONBase, document: *json.Document, text: [*]const u8, length: u32) ?*json.Value {
    const bytes: usize = if (length == json.JSON_TERMINATED) _document.lengthOf(@ptrCast(text)) else length;
    const copy = _document.text(base, document, text, bytes) orelse return null;
    const made = _document.value(base, document, json.JSON_STRING) orelse return null;
    made.string = copy;
    made.length = @intCast(bytes);
    return made;
}

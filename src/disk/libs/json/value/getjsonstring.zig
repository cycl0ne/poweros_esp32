// SPDX-License-Identifier: MIT
//! GetJSONString: a string's text.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;

/// Reads a string's text.
///
/// SYNOPSIS:
/// ```zig
/// fn GetJSONString(base: *JSONBase, value: ?*const json.Value, length: ?*u32) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `value`: the value; null is no string.
/// - `length`: where the text's length in bytes goes; null when it is not
///   wanted.
///
/// RESULT:
/// The text, UTF-8 with a NUL after it; null, `length` as it was, for
/// anything but a string.
///
/// BEHAVIOR:
/// The text with its escapes undone. A `\u0000` in it is a NUL byte
/// inside the text, which `length` counts: the text's end is its length,
/// the NUL after it only a convenience.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Locks: none taken; the caller keeps other tasks off the document.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The text is the document's, there until the document is disposed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateJSONString`, `FindJSONMember`
///
/// EXAMPLES:
/// ```zig
/// const zone = jb.GetJSONString(jb.FindJSONMember(document.root, "timezone"), null) orelse "UTC";
/// ```
pub fn GetJSONString(_: *JSONBase, value: ?*const json.Value, length: ?*u32) ?[*:0]const u8 {
    const read = value orelse return null;
    if (read.kind != json.JSON_STRING) return null;
    if (length) |into| into.* = read.length;
    return read.string;
}

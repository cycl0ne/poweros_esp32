// SPDX-License-Identifier: MIT
//! GetJSONBool: a boolean's value.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;

/// Reads a boolean's value.
///
/// SYNOPSIS:
/// ```zig
/// fn GetJSONBool(base: *JSONBase, value: ?*const json.Value, truth: *bool) bool
/// ```
///
/// SINCE: 1.0. LVO -60.
///
/// INPUTS:
/// - `value`: the value; null is no boolean.
/// - `truth`: where its value goes.
///
/// RESULT:
/// True with `true` or `false` in `truth`; false, `truth` as it was, for
/// anything but a boolean - `null`, 0 and an empty string among them.
///
/// BEHAVIOR:
/// The boolean's own value; nothing else is made one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Locks: none taken; the caller keeps other tasks off the document.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateJSONBool`
///
/// EXAMPLES:
/// ```zig
/// var fahrenheit = false;
/// _ = jb.GetJSONBool(jb.FindJSONMember(kept.root, "fahrenheit"), &fahrenheit);
/// ```
pub fn GetJSONBool(_: *JSONBase, value: ?*const json.Value, truth: *bool) bool {
    const read = value orelse return false;
    if (read.kind != json.JSON_BOOLEAN) return false;
    truth.* = read.truth;
    return true;
}

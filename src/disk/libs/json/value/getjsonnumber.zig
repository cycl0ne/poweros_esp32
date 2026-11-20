// SPDX-License-Identifier: MIT
//! GetJSONNumber: a number's value.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;

/// Reads a number's value.
///
/// SYNOPSIS:
/// ```zig
/// fn GetJSONNumber(base: *JSONBase, value: ?*const json.Value, number: *f64) bool
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `value`: the value; null is no number.
/// - `number`: where its value goes.
///
/// RESULT:
/// True with the number in `number`; false, `number` as it was, for
/// anything but a number - a string of digits among them.
///
/// BEHAVIOR:
/// The double the text was read to, or the value made. A whole number
/// beyond 2^53 is the double nearest it; `GetJSONInteger` has it
/// exactly.
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
/// `GetJSONInteger`, `CreateJSONNumber`, `FindJSONPointer`
///
/// EXAMPLES:
/// ```zig
/// var wind: f64 = 0;
/// if (!jb.GetJSONNumber(jb.FindJSONPointer(document.root, "/current/wind_speed_10m"), &wind)) wind = 0;
/// ```
pub fn GetJSONNumber(_: *JSONBase, value: ?*const json.Value, number: *f64) bool {
    const read = value orelse return false;
    if (read.kind != json.JSON_NUMBER) return false;
    number.* = read.number;
    return true;
}

// SPDX-License-Identifier: MIT
//! GetJSONInteger: a whole number's value, exactly.

const sdk = @import("sdk");
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;

/// Reads a whole number's value.
///
/// SYNOPSIS:
/// ```zig
/// fn GetJSONInteger(base: *JSONBase, value: ?*const json.Value, integer: *i64) bool
/// ```
///
/// SINCE: 1.0. LVO -52.
///
/// INPUTS:
/// - `value`: the value; null is no number.
/// - `integer`: where its value goes.
///
/// RESULT:
/// True with the number in `integer`; false, `integer` as it was, for a
/// number with a fraction, one beyond 64 bits, or anything but a number.
///
/// BEHAVIOR:
/// A number written, or made, as a whole number that fits 64 bits is
/// answered exactly, digit for digit (`JSONVF_INTEGER`). Any other
/// number is answered when its double is whole and fits: `2.0` and `1e3`
/// are 2 and 1000.
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
/// `GetJSONNumber`, `CreateJSONInteger`
///
/// EXAMPLES:
/// ```zig
/// var code: i64 = 0;
/// if (jb.GetJSONInteger(jb.FindJSONPointer(document.root, "/current/weather_code"), &code)) {
///     // the WMO code of the weather now
/// }
/// ```
pub fn GetJSONInteger(_: *JSONBase, value: ?*const json.Value, integer: *i64) bool {
    const read = value orelse return false;
    if (read.kind != json.JSON_NUMBER) return false;
    if (read.flags & json.JSONVF_INTEGER != 0) {
        integer.* = read.integer;
        return true;
    }
    const number = read.number;
    // Whole, and within -2^63 up to but not including 2^63; a NaN fails
    // every comparison.
    if (!(number >= -9223372036854775808.0 and number < 9223372036854775808.0)) return false;
    if (@floor(number) != number) return false;
    integer.* = @intFromFloat(number);
    return true;
}

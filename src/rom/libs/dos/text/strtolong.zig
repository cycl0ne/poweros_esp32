// SPDX-License-Identifier: MPL-2.0
//! StrToLong: a decimal number read from a string.

const std = @import("std");
const DosBase = @import("../dos_base.zig").DosBase;
const _text = @import("_text.zig");
const TAB = _text.TAB;

/// Reads a decimal number from the start of a string.
///
/// SYNOPSIS:
/// ```zig
/// fn StrToLong(_: *DosBase, string: [*:0]const u8, value: *i32) i32
/// ```
///
/// SINCE: 1.0. LVO -472.
///
/// INPUTS:
/// - `string` - the text.
/// - `value` - where the number goes.
///
/// RESULT:
/// How many characters were used, blanks and sign included; -1, with
/// `value` 0, when there is no digit or the number is beyond an i32.
///
/// BEHAVIOR:
/// Spaces and tabs are skipped, then an optional '-', then the digits;
/// reading stops at the first byte that is not a digit. There is no '+'.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads `string` and writes `value`.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadArgs`
///
/// EXAMPLES:
/// ```zig
/// var n: i32 = 0;
/// if (dos_lib.StrToLong(text, &n) < 0) return dos.ERROR_BAD_NUMBER;
/// ```
pub fn StrToLong(_: *DosBase, string: [*:0]const u8, value: *i32) i32 {
    var i: usize = 0;
    while (string[i] == ' ' or string[i] == TAB) i += 1;
    const negative = string[i] == '-';
    if (negative) i += 1;
    const first = i;
    const limit: i64 = if (negative) -@as(i64, std.math.minInt(i32)) else std.math.maxInt(i32);
    var n: i64 = 0;
    while (string[i] >= '0' and string[i] <= '9') : (i += 1) {
        n = n * 10 + (string[i] - '0');
        if (n > limit) break;
    }
    if (i == first or n > limit) {
        value.* = 0;
        return -1;
    }
    value.* = @intCast(if (negative) -n else n);
    return @intCast(i);
}

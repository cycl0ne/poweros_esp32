// SPDX-License-Identifier: MPL-2.0
//! Strnicmp: compares at most `length` characters of two strings without
//! case, each character after `ToUpper`.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Compares at most a given number of characters of two strings without
/// regard to case.
///
/// SYNOPSIS:
/// ```zig
/// fn Strnicmp(_: *UtilityBase, string1: [*:0]const u8, string2: [*:0]const u8, length: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -112.
///
/// INPUTS:
/// - `string1` - a Latin-1 string.
/// - `string2` - the string to compare it with.
/// - `length` - how many characters at most. 0 or less compares nothing.
///
/// RESULT:
/// Less than 0, 0 or more than 0 as the first `length` characters of
/// `string1` sort before, the same as or after those of `string2`; 0 for a
/// `length` of 0 or less.
///
/// BEHAVIOR:
/// Each character goes through `ToUpper` before the comparison, so the
/// order is that of the upper-case codes: `_` (0x5F) sorts after `Z`, and
/// the Latin-1 letters after all of ASCII. There is no locale: `ß` has no
/// upper case and compares as itself. The comparison also ends at the end
/// of
/// either string.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads only its inputs and allocates nothing.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Stricmp`, `ToUpper`
///
/// EXAMPLES:
/// ```zig
/// if (ub.Strnicmp(line, "set ", 4) == 0) return parseSet(line + 4);
/// ```
pub fn Strnicmp(ub: *UtilityBase, string1: [*:0]const u8, string2: [*:0]const u8, length: i32) i32 {
    const utility = ub.iface();
    if (length <= 0) return 0;
    const limit: usize = @intCast(length);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const ca = utility.ToUpper(string1[i]);
        const cb = utility.ToUpper(string2[i]);
        if (ca != cb) return @as(i32, ca) - cb;
        if (ca == 0) break;
    }
    return 0;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "Strnicmp" {
    const ub = try library.setUp();
    defer kexec.deinit();
    try testing.expectEqual(@as(i32, 0), Strnicmp(ub, "abcX", "ABCy", 3));
    try testing.expect(Strnicmp(ub, "abcX", "ABCy", 4) < 0);
    try testing.expectEqual(@as(i32, 0), Strnicmp(ub, "x", "y", 0));
    try library.tearDown(ub);
}

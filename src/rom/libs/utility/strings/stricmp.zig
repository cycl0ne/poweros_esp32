// SPDX-License-Identifier: MPL-2.0
//! Stricmp: compares two strings without case, as `Strnicmp` with no
//! limit that matters.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Compares two strings without regard to case.
///
/// SYNOPSIS:
/// ```zig
/// fn Stricmp(ub: *UtilityBase, string1: [*:0]const u8, string2: [*:0]const u8) i32
/// ```
///
/// SINCE: 1.0. LVO -108.
///
/// INPUTS:
/// - `string1` - a Latin-1 string.
/// - `string2` - the string to compare it with.
///
/// RESULT:
/// Less than 0, 0 or more than 0 as `string1` sorts before, the same as or
/// after `string2` - the difference of the first two characters that
/// differ, after `ToUpper`.
///
/// BEHAVIOR:
/// Each character goes through `ToUpper` before the comparison, so the
/// order is that of the upper-case codes: `_` (0x5F) sorts after `Z`, and
/// the Latin-1 letters after all of ASCII. There is no locale: `ß` has no
/// upper case and compares as itself.
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
/// `Strnicmp`, `ToUpper`
///
/// EXAMPLES:
/// ```zig
/// if (ub.Stricmp(name, "ram") == 0) return ram;
/// ```
pub fn Stricmp(ub: *UtilityBase, string1: [*:0]const u8, string2: [*:0]const u8) i32 {
    const utility = ub.iface();
    return utility.Strnicmp(string1, string2, std.math.maxInt(i32));
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "Stricmp" {
    const ub = try library.setUp();
    defer kexec.deinit();
    try testing.expectEqual(@as(i32, 0), Stricmp(ub, "Hello", "hELLO"));
    try testing.expectEqual(@as(i32, 0), Stricmp(ub, "\xC4rger", "\xE4RGER"));
    try testing.expect(Stricmp(ub, "abc", "abd") < 0);
    try testing.expect(Stricmp(ub, "b", "A") > 0);
    try testing.expect(Stricmp(ub, "a", "ab") < 0);
    try testing.expect(Stricmp(ub, "_", "a") > 0); // after ToUpper: '_' > 'A'
    try testing.expect(Stricmp(ub, "a", "\xE4") < 0); // 'A' < 'Ä'
    try library.tearDown(ub);
}

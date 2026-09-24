// SPDX-License-Identifier: MPL-2.0
//! Strcmp: compares two strings, case included.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Compares two strings, case included.
///
/// SYNOPSIS:
/// ```zig
/// fn Strcmp(_: *UtilityBase, string1: [*:0]const u8, string2: [*:0]const u8) i32
/// ```
///
/// SINCE: 1.0. LVO -220.
///
/// INPUTS:
/// - `string1` - a string.
/// - `string2` - the string to compare it with.
///
/// RESULT:
/// Less than 0, 0 or more than 0 as `string1` sorts before, the same as or
/// after `string2` - the difference of the first two characters that
/// differ.
///
/// BEHAVIOR:
/// The characters are compared as the bytes they are, so the order is that
/// of their codes: every upper-case ASCII letter sorts before every
/// lower-case one, and the Latin-1 letters after all of ASCII. A string
/// that is the start of the other sorts first.
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
/// `Stricmp`, `Strnicmp`
///
/// EXAMPLES:
/// ```zig
/// if (ub.Strcmp(name, "System") == 0) return volume;
/// ```
pub fn Strcmp(_: *UtilityBase, string1: [*:0]const u8, string2: [*:0]const u8) i32 {
    var index: usize = 0;
    while (string1[index] == string2[index]) : (index += 1) {
        if (string1[index] == 0) return 0;
    }
    return @as(i32, string1[index]) - string2[index];
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "Strcmp" {
    const ub: *UtilityBase = undefined; // Strcmp never reads it
    try testing.expectEqual(@as(i32, 0), Strcmp(ub, "Name", "Name"));
    try testing.expectEqual(@as(i32, 0), Strcmp(ub, "", ""));
    try testing.expect(Strcmp(ub, "Name", "name") < 0); // 'N' < 'n'
    try testing.expect(Strcmp(ub, "abc", "abd") < 0);
    try testing.expect(Strcmp(ub, "b", "a") > 0);
    try testing.expect(Strcmp(ub, "a", "ab") < 0);
    try testing.expect(Strcmp(ub, "\xE4", "z") > 0); // Latin-1 after ASCII
}

// SPDX-License-Identifier: MPL-2.0
//! Strlen: the length of a string.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Returns the length of a string, without its NUL.
///
/// SYNOPSIS:
/// ```zig
/// fn Strlen(_: *UtilityBase, string: [*:0]const u8) usize
/// ```
///
/// SINCE: 1.0. LVO -224.
///
/// INPUTS:
/// - `string` - the string.
///
/// RESULT:
/// How many bytes come before the NUL; 0 for an empty string.
///
/// BEHAVIOR:
/// A count of bytes, not of characters: every byte but 0 counts one,
/// which in Latin-1 is the same thing.
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
/// `Strcmp`, `Stricmp`
///
/// EXAMPLES:
/// ```zig
/// const len = ub.Strlen(name);
/// @memcpy(copy[0..len], name[0..len]);
/// ```
pub fn Strlen(_: *UtilityBase, string: [*:0]const u8) usize {
    var count: usize = 0;
    while (string[count] != 0) count += 1;
    return count;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "Strlen" {
    const ub: *UtilityBase = undefined; // Strlen never reads it
    try testing.expectEqual(@as(usize, 0), Strlen(ub, ""));
    try testing.expectEqual(@as(usize, 5), Strlen(ub, "fonts"));
    try testing.expectEqual(@as(usize, 3), Strlen(ub, "\xE4b\xFF"));
}

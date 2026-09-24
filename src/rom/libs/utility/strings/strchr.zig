// SPDX-License-Identifier: MPL-2.0
//! Strchr: finds the first occurrence of a character in a string.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Finds the first occurrence of a character in a string.
///
/// SYNOPSIS:
/// ```zig
/// fn Strchr(_: *UtilityBase, string: [*:0]const u8, character: u8) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -240.
///
/// INPUTS:
/// - `string` - the string to search.
/// - `character` - the byte to find.
///
/// RESULT:
/// Where in `string` the first occurrence of `character` is, or null if it isn't
/// there. The part of the string before it is `string[0 .. result -
/// string]`.
///
/// BEHAVIOR:
/// The string is read from its start, and the search stops at the first match or at the NUL. A `character` of 0 finds the NUL that ends the string, so
/// the result is then never null.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It only reads its inputs.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The result points into `string`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Strrchr`, `Strlen`
///
/// EXAMPLES:
/// ```zig
/// const colon = ub.Strchr(name, ':') orelse return false; // no device in the name
/// ```
pub fn Strchr(_: *UtilityBase, string: [*:0]const u8, character: u8) ?[*:0]const u8 {
    var at: usize = 0;
    while (true) : (at += 1) {
        if (string[at] == character) return string + at;
        if (string[at] == 0) return null;
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "Strchr" {
    const ub: *UtilityBase = undefined; // Strchr never reads it
    const text: [*:0]const u8 = "sys:c/dir";
    try testing.expectEqual(@as(?[*:0]const u8, text + 3), Strchr(ub, text, ':'));
    try testing.expectEqual(@as(?[*:0]const u8, text + 5), Strchr(ub, text, '/'));
    try testing.expectEqual(@as(?[*:0]const u8, null), Strchr(ub, text, 'x'));
    try testing.expectEqual(@as(?[*:0]const u8, text + 9), Strchr(ub, text, 0));
}

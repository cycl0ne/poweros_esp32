// SPDX-License-Identifier: MPL-2.0
//! Strrchr: finds the last occurrence of a character in a string.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Finds the last occurrence of a character in a string.
///
/// SYNOPSIS:
/// ```zig
/// fn Strrchr(_: *UtilityBase, string: [*:0]const u8, character: u8) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -244.
///
/// INPUTS:
/// - `string` - the string to search.
/// - `character` - the byte to find.
///
/// RESULT:
/// Where in `string` the last occurrence of `character` is, or null if it isn't
/// there. The part of the string before it is `string[0 .. result -
/// string]`.
///
/// BEHAVIOR:
/// The whole string is read, and the last match before the NUL is the one kept. A `character` of 0 finds the NUL that ends the string, so
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
/// `Strchr`, `Strlen`
///
/// EXAMPLES:
/// ```zig
/// const slash = ub.Strrchr(path, '/') orelse path; // the last part of a path
/// ```
pub fn Strrchr(_: *UtilityBase, string: [*:0]const u8, character: u8) ?[*:0]const u8 {
    var found: ?[*:0]const u8 = null;
    var at: usize = 0;
    while (true) : (at += 1) {
        if (string[at] == character) found = string + at;
        if (string[at] == 0) return found;
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "Strrchr" {
    const ub: *UtilityBase = undefined; // Strrchr never reads it
    const text: [*:0]const u8 = "sys:c/dir";
    const two: [*:0]const u8 = "a/b/c";
    try testing.expectEqual(@as(?[*:0]const u8, two + 3), Strrchr(ub, two, '/'));
    try testing.expectEqual(@as(?[*:0]const u8, text + 3), Strrchr(ub, text, ':'));
    try testing.expectEqual(@as(?[*:0]const u8, null), Strrchr(ub, text, 'x'));
    try testing.expectEqual(@as(?[*:0]const u8, text + 9), Strrchr(ub, text, 0));
}

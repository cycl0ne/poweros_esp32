// SPDX-License-Identifier: MPL-2.0
//! ToLower: a Latin-1 character in lower case.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Turns a Latin-1 character into lower case.
///
/// SYNOPSIS:
/// ```zig
/// fn ToLower(_: *UtilityBase, character: u32) u8
/// ```
///
/// SINCE: 1.0. LVO -120.
///
/// INPUTS:
/// - `character` - the character, in the low 8 bits; the rest is ignored.
///
/// RESULT:
/// The lower case of `A`-`Z` and of the Latin-1 upper-case letters
/// 0xC0-0xDE but for `×` (0xD7); every other character as it is.
///
/// BEHAVIOR:
/// The inverse of `ToUpper` on the letters. `×` is not a letter and stays
/// as it is.
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
/// `ToUpper`
///
/// EXAMPLES:
/// ```zig
/// const c = ub.ToLower(key);
/// ```
pub fn ToLower(_: *UtilityBase, character: u32) u8 {
    const c: u8 = @truncate(character);
    return switch (c) {
        'A'...'Z', 0xC0...0xD6, 0xD8...0xDE => c + 0x20,
        else => c,
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "ToLower on Latin-1" {
    const ub: *UtilityBase = undefined; // the string calls never read it
    try testing.expectEqual(@as(u8, 'z'), ToLower(ub, 'Z'));
    try testing.expectEqual(@as(u8, 0xFE), ToLower(ub, 0xDE)); // Þ
    try testing.expectEqual(@as(u8, 0xD7), ToLower(ub, 0xD7)); // ×
}

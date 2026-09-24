// SPDX-License-Identifier: MPL-2.0
//! ToUpper: a Latin-1 character in upper case.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Turns a Latin-1 character into upper case.
///
/// SYNOPSIS:
/// ```zig
/// fn ToUpper(_: *UtilityBase, character: u32) u8
/// ```
///
/// SINCE: 1.0. LVO -116.
///
/// INPUTS:
/// - `character` - the character, in the low 8 bits; the rest is ignored.
///
/// RESULT:
/// The upper case of `a`-`z` and of the Latin-1 lower-case letters
/// 0xE0-0xFE but for `÷` (0xF7); every other character as it is.
///
/// BEHAVIOR:
/// `ß` and `ÿ` have no upper case in Latin-1 and stay as they are. Pattern
/// matching without case and the string compares use the same mapping.
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
/// `ToLower`, `Stricmp`
///
/// EXAMPLES:
/// ```zig
/// const c = ub.ToUpper(key);
/// ```
pub fn ToUpper(_: *UtilityBase, character: u32) u8 {
    const c: u8 = @truncate(character);
    return switch (c) {
        'a'...'z', 0xE0...0xF6, 0xF8...0xFE => c - 0x20,
        else => c,
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "ToUpper on Latin-1" {
    const ub: *UtilityBase = undefined; // the string calls never read it
    try testing.expectEqual(@as(u8, 'A'), ToUpper(ub, 'a'));
    try testing.expectEqual(@as(u8, '1'), ToUpper(ub, '1'));
    try testing.expectEqual(@as(u8, 0xC4), ToUpper(ub, 0xE4)); // ä
    try testing.expectEqual(@as(u8, 0xF7), ToUpper(ub, 0xF7)); // ÷
    try testing.expectEqual(@as(u8, 0xDF), ToUpper(ub, 0xDF)); // ß
    try testing.expectEqual(@as(u8, 0xFF), ToUpper(ub, 0xFF)); // ÿ
}

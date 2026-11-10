// SPDX-License-Identifier: MPL-2.0
//! ToLower: a character in lower case, by Unicode's simple case mapping.

const std = @import("std");
const unicode = @import("sdk").utility.unicode;

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Turns a character into lower case.
///
/// SYNOPSIS:
/// ```zig
/// fn ToLower(_: *UtilityBase, character: u32) u32
/// ```
///
/// SINCE: 1.0, any code point since 1.7. LVO -120.
///
/// INPUTS:
/// - `character` - the character, a code point.
///
/// RESULT:
/// Its lower case by Unicode's simple case mapping (one code point to
/// one), or the character itself when it has none - a character that is
/// no letter, one already in lower case, a value past U+10FFFF.
///
/// BEHAVIOR:
/// The mapping is the same whatever language is set: `I` is `i`
/// everywhere. `ẞ` (U+1E9E) is `ß`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads only its inputs and allocates nothing.
/// - Locks: none taken, none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// Names are compared by folding, not by lower case (`Stricmp`).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ToUpper`, `Stricmp`
///
/// EXAMPLES:
/// ```zig
/// const shown = ub.ToLower(key);
/// ```
pub fn ToLower(_: *UtilityBase, character: u32) u32 {
    return unicode.lower(character);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "ToLower over Unicode" {
    const ub: *UtilityBase = undefined; // the string calls never read it
    try testing.expectEqual(@as(u32, 'z'), ToLower(ub, 'Z'));
    try testing.expectEqual(@as(u32, 0xFE), ToLower(ub, 0xDE)); // Þ
    try testing.expectEqual(@as(u32, 0xD7), ToLower(ub, 0xD7)); // ×
    try testing.expectEqual(@as(u32, 0xFF), ToLower(ub, 0x178)); // Ÿ
    try testing.expectEqual(@as(u32, 0xDF), ToLower(ub, 0x1E9E)); // ẞ
    try testing.expectEqual(@as(u32, 0x3C3), ToLower(ub, 0x3A3)); // Σ
    try testing.expectEqual(@as(u32, 0x3C2), ToLower(ub, 0x3C2)); // ς stays
    try testing.expectEqual(@as(u32, 0x436), ToLower(ub, 0x416)); // Ж
    try testing.expectEqual(@as(u32, 0x10428), ToLower(ub, 0x10400)); // Deseret
    try testing.expectEqual(@as(u32, 0x2C65), ToLower(ub, 0x23A)); // Ⱥ
}

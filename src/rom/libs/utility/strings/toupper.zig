// SPDX-License-Identifier: MPL-2.0
//! ToUpper: a character in upper case, by Unicode's simple case mapping.

const std = @import("std");
const unicode = @import("sdk").utility.unicode;

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Turns a character into upper case.
///
/// SYNOPSIS:
/// ```zig
/// fn ToUpper(_: *UtilityBase, character: u32) u32
/// ```
///
/// SINCE: 1.0, any code point since 1.7. LVO -116.
///
/// INPUTS:
/// - `character` - the character, a code point.
///
/// RESULT:
/// Its upper case by Unicode's simple case mapping (one code point to
/// one), or the character itself when it has none - a character that is
/// no letter, one already in upper case, a value past U+10FFFF.
///
/// BEHAVIOR:
/// The mapping is the same whatever language is set. A letter whose
/// upper case is more than one character keeps itself: `ß` stays `ß`.
/// `ÿ` is `Ÿ` (U+0178) and `µ` is `Μ` (U+039C), so the upper case of a
/// Latin-1 character need not be one.
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
/// Names are compared by folding, not by upper case (`Stricmp`).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ToLower`, `Stricmp`
///
/// EXAMPLES:
/// ```zig
/// if (ub.ToUpper(key) == 'Q') return quit();
/// ```
pub fn ToUpper(_: *UtilityBase, character: u32) u32 {
    return unicode.upper(character);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "ToUpper over Unicode" {
    const ub: *UtilityBase = undefined; // the string calls never read it
    try testing.expectEqual(@as(u32, 'A'), ToUpper(ub, 'a'));
    try testing.expectEqual(@as(u32, '1'), ToUpper(ub, '1'));
    try testing.expectEqual(@as(u32, 0xC4), ToUpper(ub, 0xE4)); // ä
    try testing.expectEqual(@as(u32, 0xF7), ToUpper(ub, 0xF7)); // ÷
    try testing.expectEqual(@as(u32, 0xDF), ToUpper(ub, 0xDF)); // ß
    try testing.expectEqual(@as(u32, 0x178), ToUpper(ub, 0xFF)); // ÿ
    try testing.expectEqual(@as(u32, 0x39C), ToUpper(ub, 0xB5)); // µ
    try testing.expectEqual(@as(u32, 0x3A3), ToUpper(ub, 0x3C3)); // σ
    try testing.expectEqual(@as(u32, 0x3A3), ToUpper(ub, 0x3C2)); // ς
    try testing.expectEqual(@as(u32, 0x416), ToUpper(ub, 0x436)); // ж
    try testing.expectEqual(@as(u32, 0x100), ToUpper(ub, 0x101)); // ā
    try testing.expectEqual(@as(u32, 0x10400), ToUpper(ub, 0x10428)); // Deseret
    try testing.expectEqual(@as(u32, 0x65E5), ToUpper(ub, 0x65E5)); // 日
    try testing.expectEqual(@as(u32, 0x1F600), ToUpper(ub, 0x1F600)); // an emoji
    try testing.expectEqual(@as(u32, 0x110000), ToUpper(ub, 0x110000));
}

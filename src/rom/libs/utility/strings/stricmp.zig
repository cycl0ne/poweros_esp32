// SPDX-License-Identifier: MPL-2.0
//! Stricmp: compares two strings without regard to case, as `Strnicmp`
//! with no limit that matters.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Compares two strings without regard to case.
///
/// SYNOPSIS:
/// ```zig
/// fn Stricmp(ub: *UtilityBase, string1: [*:0]const u8, string2: [*:0]const u8) i32
/// ```
///
/// SINCE: 1.0, UTF-8 since 1.7. LVO -108.
///
/// INPUTS:
/// - `string1` - a UTF-8 string.
/// - `string2` - the string to compare it with.
///
/// RESULT:
/// Less than 0, 0 or more than 0 as `string1` sorts before, the same as or
/// after `string2` - the difference of the first two characters that
/// differ once folded, the end of a string counting as 0.
///
/// BEHAVIOR:
/// Each character is folded by Unicode's simple case folding before the
/// comparison - the same whatever language is set, and what names are
/// compared by everywhere: `Ä` and `ä` are one, `Σ`, `σ` and `ς` are one,
/// `ß` is itself. The order is that of the folded code points: `_`
/// (0x5F) before the letters, the letters past ASCII after all of it. A
/// byte that is no UTF-8 compares as U+FFFD, as `Strnicmp` says.
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
    try testing.expectEqual(@as(i32, 0), Stricmp(ub, "\xC3\x84rger", "\xC3\xA4RGER")); // Ärger
    try testing.expect(Stricmp(ub, "abc", "abd") < 0);
    try testing.expect(Stricmp(ub, "b", "A") > 0);
    try testing.expect(Stricmp(ub, "a", "ab") < 0);
    try testing.expect(Stricmp(ub, "_", "a") < 0); // folded: '_' < 'a'
    try testing.expect(Stricmp(ub, "a", "\xC3\xA4") < 0); // 'a' < 'ä'
    try testing.expectEqual(@as(i32, 0), Stricmp(ub, "M\xC3\xBCll", "M\xC3\x9CLL")); // Müll, MÜLL
    // A byte that is no UTF-8 is U+FFFD: never the letter its Latin-1
    // value was, past every character below U+FFFD, and itself.
    try testing.expect(Stricmp(ub, "M\xFCll", "m\xC3\x9Cll") > 0);
    try testing.expectEqual(@as(i32, 0), Stricmp(ub, "M\xFCll", "m\xE4LL"));
    try testing.expectEqual(@as(i32, 0), Stricmp(ub, "\xCE\x9F\xCE\xB4\xCF\x8C\xCF\x82", "\xCE\xBF\xCE\xB4\xCF\x8C\xCF\x83")); // Οδός, οδόσ
    try testing.expectEqual(@as(i32, 0), Stricmp(ub, "\xE1\xBA\x9E", "\xC3\x9F")); // ẞ, ß
    try testing.expect(Stricmp(ub, "stra\xC3\x9Fe", "strasse") != 0); // no full folding
    try testing.expectEqual(@as(i32, 0), Stricmp(ub, "\xF0\x9F\x98\x80", "\xF0\x9F\x98\x80"));
    try testing.expect(Stricmp(ub, "\xC3\xA4", "\xC3\xA4b") < 0);
    try library.tearDown(ub);
}

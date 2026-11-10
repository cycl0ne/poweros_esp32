// SPDX-License-Identifier: MPL-2.0
//! Strnicmp: compares at most `length` bytes of two strings without
//! regard to case, a character at a time once folded.

const std = @import("std");
const unicode = @import("sdk").utility.unicode;

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Compares at most a given number of bytes of two strings without
/// regard to case.
///
/// SYNOPSIS:
/// ```zig
/// fn Strnicmp(_: *UtilityBase, string1: [*:0]const u8, string2: [*:0]const u8, length: i32) i32
/// ```
///
/// SINCE: 1.0, UTF-8 since 1.7. LVO -112.
///
/// INPUTS:
/// - `string1` - a UTF-8 string.
/// - `string2` - the string to compare it with.
/// - `length` - how many bytes of each at most. 0 or less compares
///   nothing.
///
/// RESULT:
/// Less than 0, 0 or more than 0 as the first `length` bytes of `string1`
/// sort before, the same as or after those of `string2` - the difference
/// of the first two characters that differ once folded, the end of a
/// string counting as 0; 0 for a `length` of 0 or less.
///
/// BEHAVIOR:
/// Each string is read as UTF-8, up to its NUL or `length` bytes, and
/// each character folded by Unicode's simple case folding before the
/// comparison - the same whatever language is set, and what names are
/// compared by everywhere: `Ä` and `ä` are one, `Σ`, `σ` and `ς` are one,
/// `ß` is itself. The order is that of the folded code points: `_`
/// (0x5F) before the letters, the letters past ASCII after all of it.
/// Because characters are compared, not bytes, two strings of different
/// lengths in bytes can be the same.
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
/// A byte that is no UTF-8 compares as the character the system reads it
/// as (sdk.utility.utf8): its Latin-1 character, so a Latin-1 `\xE4` and
/// a UTF-8 `ä` are the same. A character `length` cuts in two is read as
/// its bytes are.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Stricmp`, `ToUpper`
///
/// EXAMPLES:
/// ```zig
/// if (ub.Strnicmp(line, "set ", 4) == 0) return parseSet(line + 4);
/// ```
pub fn Strnicmp(_: *UtilityBase, string1: [*:0]const u8, string2: [*:0]const u8, length: i32) i32 {
    if (length <= 0) return 0;
    const limit: usize = @intCast(length);
    return unicode.compareFolded(upTo(string1, limit), upTo(string2, limit));
}

/// A string's bytes before its NUL, `limit` at most.
fn upTo(string: [*:0]const u8, limit: usize) []const u8 {
    var length: usize = 0;
    while (length < limit and string[length] != 0) length += 1;
    return string[0..length];
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "Strnicmp" {
    const ub = try library.setUp();
    defer kexec.deinit();
    try testing.expectEqual(@as(i32, 0), Strnicmp(ub, "abcX", "ABCy", 3));
    try testing.expect(Strnicmp(ub, "abcX", "ABCy", 4) < 0);
    try testing.expectEqual(@as(i32, 0), Strnicmp(ub, "x", "y", 0));
    // Characters, not bytes: ä is two bytes, Ä too, and the limit counts
    // bytes.
    try testing.expectEqual(@as(i32, 0), Strnicmp(ub, "\xC3\xA4b", "\xC3\x84B", 3));
    try testing.expectEqual(@as(i32, 0), Strnicmp(ub, "\xCE\xA3x", "\xCF\x82y", 2)); // Σ and ς
    try library.tearDown(ub);
}

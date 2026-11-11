// SPDX-License-Identifier: MPL-2.0
//! Latin1ToUtf8: Latin-1 made UTF-8.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Turns Latin-1 - text an older file, tag or server holds - into UTF-8.
///
/// SYNOPSIS:
/// ```zig
/// fn Latin1ToUtf8(ub: *UtilityBase, from: [*]const u8, from_length: usize, into: [*]u8, into_length: usize) usize
/// ```
///
/// SINCE: 1.4. LVO -280.
///
/// INPUTS:
/// - `from`, `from_length` - the Latin-1.
/// - `into`, `into_length` - where the UTF-8 goes; not `from`.
///
/// RESULT:
/// The bytes the whole text takes in UTF-8, written or not.
///
/// BEHAVIOR:
/// An ASCII byte stays as it is; a byte from 0x80 on, the character of
/// that number, is its two bytes of UTF-8. As many whole characters are
/// written as `into` holds, no NUL after them: the whole is there when the
/// answer is no more than `into_length`. A length of 0 for `into` only
/// counts.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads its input and writes `into`.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. Everything given is the caller's.
///
/// NOTES:
/// The text grows by a byte for each character past ASCII: twice its
/// length always holds it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Utf8ToLatin1`, `Utf8Kind`
///
/// EXAMPLES:
/// ```zig
/// // A title from an ID3v1 tag, which holds Latin-1.
/// const length = ub.Latin1ToUtf8(&tag.title, tag.title.len, &title, title.len);
/// if (length > title.len) return null;
/// ```
pub fn Latin1ToUtf8(_: *UtilityBase, from: [*]const u8, from_length: usize, into: [*]u8, into_length: usize) usize {
    var needed: usize = 0;
    var out: usize = 0;
    var full = false;
    for (from[0..from_length]) |char| {
        const length: usize = if (char < 0x80) 1 else 2;
        needed += length;
        if (full or out + length > into_length) {
            full = true;
            continue;
        }
        if (char < 0x80) {
            into[out] = char;
        } else {
            into[out] = 0xC0 | char >> 6;
            into[out + 1] = 0x80 | (char & 0x3F);
        }
        out += length;
    }
    return needed;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "Latin1ToUtf8: past ASCII as two bytes, whole characters only, the length counted" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var into: [32]u8 = undefined;
    const text = "Gr\xFC\xDFe \xFF";
    const length = Latin1ToUtf8(ub, text, text.len, &into, into.len);
    try testing.expectEqualStrings("Gr\xC3\xBC\xC3\x9Fe \xC3\xBF", into[0..length]);
    // Too small: whole characters as far as they go, the whole length said.
    var small: [3]u8 = @splat('#');
    try testing.expectEqual(@as(usize, 10), Latin1ToUtf8(ub, text, text.len, &small, small.len));
    try testing.expectEqualStrings("Gr#", &small);
    try testing.expectEqual(@as(usize, 10), Latin1ToUtf8(ub, text, text.len, &small, 0));
    try testing.expectEqual(@as(usize, 0), Latin1ToUtf8(ub, text, 0, &into, into.len));
}

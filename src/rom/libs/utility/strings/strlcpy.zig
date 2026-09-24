// SPDX-License-Identifier: MPL-2.0
//! Strlcpy: copies a string into a buffer of a given size, always ending
//! it with a NUL.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Copies a string into a buffer, cut to fit and always ended with a NUL.
///
/// SYNOPSIS:
/// ```zig
/// fn Strlcpy(_: *UtilityBase, dest: [*]u8, size: usize, source: [*:0]const u8) usize
/// ```
///
/// SINCE: 1.0. LVO -236.
///
/// INPUTS:
/// - `dest` - the buffer.
/// - `size` - how many bytes it has, the NUL included. 0 writes nothing.
/// - `source` - the string to copy.
///
/// RESULT:
/// The length of `source`, whatever was copied. A result of `size` or more
/// says the copy was cut short.
///
/// BEHAVIOR:
/// At most `size - 1` bytes are copied, and a NUL is put after them, so
/// the buffer always holds a string - unlike a copy that stops at the size
/// and leaves the end open. The whole of `source` is read to count it, so
/// a caller can tell a cut copy from a whole one and make room.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads its inputs and writes the caller's buffer.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The buffer is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Strlen`, `Strcmp`
///
/// EXAMPLES:
/// ```zig
/// var name: [32]u8 = undefined;
/// if (ub.Strlcpy(&name, name.len, wanted) >= name.len) return error.NameTooLong;
/// ```
pub fn Strlcpy(_: *UtilityBase, dest: [*]u8, size: usize, source: [*:0]const u8) usize {
    var length: usize = 0;
    while (source[length] != 0) : (length += 1) {
        if (length + 1 < size) dest[length] = source[length];
    }
    if (size != 0) dest[@min(length, size - 1)] = 0;
    return length;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "Strlcpy" {
    const ub: *UtilityBase = undefined; // Strlcpy never reads it
    var buf: [6]u8 = @splat('x');
    try testing.expectEqual(@as(usize, 3), Strlcpy(ub, &buf, buf.len, "abc"));
    try testing.expectEqualStrings("abc", std.mem.sliceTo(&buf, 0));
    try testing.expectEqual(@as(usize, 9), Strlcpy(ub, &buf, buf.len, "too long!"));
    try testing.expectEqualStrings("too l", std.mem.sliceTo(&buf, 0)); // cut, and ended
    try testing.expectEqual(@as(usize, 0), Strlcpy(ub, &buf, buf.len, ""));
    try testing.expectEqual(@as(u8, 0), buf[0]);
    buf[0] = 'x';
    try testing.expectEqual(@as(usize, 3), Strlcpy(ub, &buf, 0, "abc"));
    try testing.expectEqual(@as(u8, 'x'), buf[0]); // size 0 writes nothing
}

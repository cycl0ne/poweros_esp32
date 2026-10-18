// SPDX-License-Identifier: MPL-2.0
//! SetMem: fills bytes with one value, a word at a time where it can
//! (words.zig) - also every memset a program makes.

const ExecBase = @import("../exec.zig").ExecBase;
const words = @import("words.zig");

/// Fills memory with one byte value.
///
/// SYNOPSIS:
/// ```zig
/// fn SetMem(_: *ExecBase, dest: *anyopaque, value: u8, size: usize) void
/// ```
///
/// SINCE: 1.0. LVO -308.
///
/// INPUTS:
/// - `dest` - where to fill. Any alignment.
/// - `value` - the byte to write everywhere.
/// - `size` - how many bytes. 0 does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Bytes up to a word boundary, then whole words, then the bytes left.
///
/// A program's memset - what its `@memset` becomes - is this call
/// (sdk/libs/exec/libc.zig).
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Locks: none taken, none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// `MEMF_CLEAR` on an allocation does this for the zero case without a
/// second pass over the memory.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CopyMem`, `AllocMem`
///
/// EXAMPLES:
/// ```zig
/// sys.SetMem(buf, 0, len);
/// ```
pub fn SetMem(_: *ExecBase, dest: *anyopaque, value: u8, size: usize) void {
    words.fill(@ptrCast(dest), value, size);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "SetMem fills exactly the bytes asked for" {
    const base: *ExecBase = undefined; // SetMem never reads it
    var buf = [_]u8{0} ** 8;
    SetMem(base, &buf[1], 0xAA, 5);
    try testing.expectEqualSlices(u8, &.{ 0, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0, 0 }, &buf);
    SetMem(base, &buf, 0xFF, 0);
    try testing.expectEqual(@as(u8, 0), buf[0]);
}

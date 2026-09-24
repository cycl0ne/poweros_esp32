// SPDX-License-Identifier: MPL-2.0
//! SetMem: fills bytes with one value. It is `@memset`, which stores whole
//! words where the alignment allows.

const ExecBase = @import("../exec.zig").ExecBase;

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
/// Word-sized stores where the alignment allows.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe.
/// - Forbid: not needed, and not taken.
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
    if (size == 0) return;
    const to: [*]u8 = @ptrCast(dest);
    @memset(to[0..size], value);
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

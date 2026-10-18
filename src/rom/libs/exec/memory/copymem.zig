// SPDX-License-Identifier: MPL-2.0
//! CopyMem: copies bytes, overlap allowed, a word at a time where it can
//! (words.zig) - also every memcpy and memmove a program makes.

const ExecBase = @import("../exec.zig").ExecBase;
const words = @import("words.zig");

/// Copies bytes, whatever their alignment and however they overlap.
///
/// SYNOPSIS:
/// ```zig
/// fn CopyMem(_: *ExecBase, source: *const anyopaque, dest: *anyopaque,
///     size: usize) void
/// ```
///
/// SINCE: 1.0. LVO -300.
///
/// INPUTS:
/// - `source` - where the bytes come from. Any alignment.
/// - `dest` - where they go. Any alignment.
/// - `size` - how many. 0 does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// **Overlapping areas come out right**, in either direction: the copy runs
/// whichever way keeps it from overwriting what it has yet to read. That is
/// worth stating because it is the one thing a caller cannot test for
/// cheaply and the one that fails intermittently when it is wrong.
///
/// Whole words where the length allows: bytes up to a word boundary,
/// then words, shifted into place where the two areas are not as far from
/// a boundary as each other - each load and store aligned, on a CPU that
/// has no fast misaligned ones.
///
/// A program's memcpy and memmove - what its `@memcpy` and struct copies
/// become - are this call (sdk/libs/exec/libc.zig), so a program copies
/// with the loop the kernel was built with for the board.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It touches nothing but the two blocks.
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
/// `CopyMemQuick`, `SetMem`
///
/// EXAMPLES:
/// ```zig
/// sys.CopyMem(src, dst, len);
/// ```
pub fn CopyMem(_: *ExecBase, source: *const anyopaque, dest: *anyopaque, size: usize) void {
    words.move(@ptrCast(dest), @ptrCast(source), size);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "CopyMem copies, and an overlap in either direction is handled" {
    const base: *ExecBase = undefined; // CopyMem never reads it
    var buf = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    CopyMem(base, &buf, &buf[2], 4); // forward overlap
    try testing.expectEqualSlices(u8, &.{ 1, 2, 1, 2, 3, 4, 7, 8 }, &buf);
    CopyMem(base, &buf[2], &buf, 4); // backward overlap
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 3, 4, 7, 8 }, &buf);
    CopyMem(base, &buf, &buf[4], 0);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 3, 4, 7, 8 }, &buf);
}

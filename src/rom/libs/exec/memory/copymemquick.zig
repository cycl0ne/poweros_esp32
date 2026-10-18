// SPDX-License-Identifier: MPL-2.0
//! CopyMemQuick: `CopyMem` for word-aligned memory in whole words. The
//! alignment is an assertion about the arguments rather than a different
//! algorithm: it is the same loop as `CopyMem`'s, which takes aligned
//! arguments without a byte to spare at either end, and copies any other
//! right.

const ExecBase = @import("../exec.zig").ExecBase;
const words = @import("words.zig");

/// Copies whole words between word-aligned addresses.
///
/// SYNOPSIS:
/// ```zig
/// fn CopyMemQuick(base: *ExecBase, source: *const anyopaque,
///     dest: *anyopaque, size: usize) void
/// ```
///
/// SINCE: 1.0. LVO -304.
///
/// INPUTS:
/// - `source`, `dest` - 4-aligned.
/// - `size` - a multiple of 4.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The loop is `CopyMem`'s, so arguments that do not meet the conditions
/// are **copied as `CopyMem` copies them** rather than giving a wrong
/// answer: always safe, and as fast as `CopyMem` at any alignment. Overlap
/// is handled, as there.
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
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CopyMem`, `SetMem`
///
/// EXAMPLES:
/// ```zig
/// sys.CopyMemQuick(src, dst, words * 4);
/// ```
pub fn CopyMemQuick(_: *ExecBase, source: *const anyopaque, dest: *anyopaque, size: usize) void {
    words.move(@ptrCast(dest), @ptrCast(source), size);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "CopyMemQuick copies whole words, overlap included" {
    const base: *ExecBase = undefined; // CopyMemQuick never reads it
    var longs = [_]u32{ 1, 2, 3, 4 };
    CopyMemQuick(base, &longs, &longs[1], 3 * 4);
    try testing.expectEqualSlices(u32, &.{ 1, 1, 2, 3 }, &longs);
}

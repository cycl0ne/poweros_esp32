// SPDX-License-Identifier: MPL-2.0
//! CopyMem: copies bytes, overlap allowed. It is `@memmove`, which
//! compiler_rt implements with word-sized loads and stores where the
//! alignment allows (byte loops only in ReleaseSmall builds), so there is
//! no slower "safe" case to pay for.

const ExecBase = @import("../exec.zig").ExecBase;

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
/// Word-sized loads and stores are used where the alignment allows.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It touches nothing but the two blocks.
/// - Forbid: not needed, and not taken.
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
    if (size == 0) return;
    const from: [*]const u8 = @ptrCast(source);
    const to: [*]u8 = @ptrCast(dest);
    @memmove(to[0..size], from[0..size]);
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

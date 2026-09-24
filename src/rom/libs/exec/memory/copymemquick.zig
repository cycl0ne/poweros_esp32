// SPDX-License-Identifier: MPL-2.0
//! CopyMemQuick: `CopyMem` for word-aligned memory in whole words. The
//! alignment is an assertion about the arguments rather than a different
//! algorithm: arguments that do not meet it are handed to `CopyMem`, so
//! this is always safe and only sometimes faster.

const ExecBase = @import("../exec.zig").ExecBase;

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
/// Arguments that do not meet the conditions are **handed to `CopyMem`**
/// rather than giving a wrong answer, so this is always safe to call and
/// only sometimes faster. Overlap is handled, as there.
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
pub fn CopyMemQuick(base: *ExecBase, source: *const anyopaque, dest: *anyopaque, size: usize) void {
    if ((@intFromPtr(source) | @intFromPtr(dest) | size) & 3 != 0)
        return base.iface().CopyMem(source, dest, size);
    const words = size / 4;
    if (words == 0) return;
    const from: [*]const u32 = @ptrCast(@alignCast(source));
    const to: [*]u32 = @ptrCast(@alignCast(dest));
    @memmove(to[0..words], from[0..words]);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "CopyMemQuick copies whole words, overlap included" {
    const base: *ExecBase = undefined; // the aligned path never reads it
    var words = [_]u32{ 1, 2, 3, 4 };
    CopyMemQuick(base, &words, &words[1], 3 * 4);
    try testing.expectEqualSlices(u32, &.{ 1, 1, 2, 3 }, &words);
}

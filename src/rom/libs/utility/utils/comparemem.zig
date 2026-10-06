// SPDX-License-Identifier: MPL-2.0
//! CompareMem: two blocks of memory compared byte by byte.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Compares two blocks of memory.
///
/// SYNOPSIS:
/// ```zig
/// fn CompareMem(_: *UtilityBase, first: *const anyopaque,
///     second: *const anyopaque, length: usize) i32
/// ```
///
/// SINCE: 1.1. LVO -256.
///
/// INPUTS:
/// - `first`, `second` - the two blocks.
/// - `length` - how many bytes of each to compare.
///
/// RESULT:
/// 0 when the bytes are the same; otherwise the first byte that differs
/// at `first` less the one at `second`, so below 0 when `first` comes
/// first in byte order.
///
/// BEHAVIOR:
/// The bytes are compared from the start, and the first difference ends
/// it. A `length` of 0 compares nothing and answers 0.
///
/// A record compared this way is equal to another when every byte of it
/// is, padding included: the record to compare is best an extern struct
/// of whole words, which has none, or one made zero before it is filled.
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
/// The blocks may overlap; each is only read.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// exec.library `CopyMem`, `Strcmp`
///
/// EXAMPLES:
/// ```zig
/// if (ub.CompareMem(&now, &last, @sizeOf(View)) != 0) tell(now);
/// ```
pub fn CompareMem(_: *UtilityBase, first: *const anyopaque, second: *const anyopaque, length: usize) i32 {
    const ones: [*]const u8 = @ptrCast(first);
    const others: [*]const u8 = @ptrCast(second);
    var at: usize = 0;
    while (at < length) : (at += 1) {
        if (ones[at] != others[at]) return @as(i32, ones[at]) - @as(i32, others[at]);
    }
    return 0;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "CompareMem" {
    const ub: *UtilityBase = undefined; // CompareMem never reads it
    const View = extern struct { top: u32, total: u32 };
    const one = View{ .top = 3, .total = 10 };
    var other = one;
    try testing.expectEqual(@as(i32, 0), CompareMem(ub, &one, &other, @sizeOf(View)));
    other.total = 11;
    try testing.expect(CompareMem(ub, &one, &other, @sizeOf(View)) != 0);
    try testing.expect(CompareMem(ub, "abc", "abd", 3) < 0);
    try testing.expect(CompareMem(ub, "abd", "abc", 3) > 0);
    try testing.expectEqual(@as(i32, 0), CompareMem(ub, "abc", "abd", 2));
    try testing.expectEqual(@as(i32, 0), CompareMem(ub, "x", "y", 0));
}

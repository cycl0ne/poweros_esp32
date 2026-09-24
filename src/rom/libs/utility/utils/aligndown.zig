// SPDX-License-Identifier: MPL-2.0
//! AlignDown: rounds an offset or an address down to a power-of-two
//! alignment.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Rounds an offset down to a multiple of an alignment.
///
/// SYNOPSIS:
/// ```zig
/// fn AlignDown(_: *UtilityBase, offset: usize, alignment: usize) usize
/// ```
///
/// SINCE: 1.0. LVO -232.
///
/// INPUTS:
/// - `offset` - an offset, a size or an address.
/// - `alignment` - a power of two.
///
/// RESULT:
/// The largest multiple of `alignment` that is not above `offset`;
/// `offset` itself when it is aligned already.
///
/// BEHAVIOR:
/// A power of two has one bit set, so its multiples are the numbers whose
/// bits below it are clear: clearing those bits rounds down in one
/// operation, with no division. It cannot overflow.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads only its inputs and allocates nothing.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// An `alignment` that is not a power of two gives a number with no
/// meaning, and 0 gives 0. Nothing checks either.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AlignUp`
///
/// EXAMPLES:
/// ```zig
/// const line = ub.AlignDown(address, DCACHE_LINE_SIZE);
/// ```
pub fn AlignDown(_: *UtilityBase, offset: usize, alignment: usize) usize {
    return offset & ~(alignment -% 1);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "AlignDown" {
    const ub: *UtilityBase = undefined; // AlignDown never reads it
    try testing.expectEqual(@as(usize, 0), AlignDown(ub, 7, 8));
    try testing.expectEqual(@as(usize, 8), AlignDown(ub, 8, 8));
    try testing.expectEqual(@as(usize, 8), AlignDown(ub, 15, 8));
    try testing.expectEqual(@as(usize, 13), AlignDown(ub, 13, 1));
    try testing.expectEqual(@as(usize, 0x3000), AlignDown(ub, 0x3FFF, 0x1000));
}

// SPDX-License-Identifier: MPL-2.0
//! AlignUp: rounds an offset or an address up to a power-of-two
//! alignment.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Rounds an offset up to the next multiple of an alignment.
///
/// SYNOPSIS:
/// ```zig
/// fn AlignUp(_: *UtilityBase, offset: usize, alignment: usize) usize
/// ```
///
/// SINCE: 1.0. LVO -228.
///
/// INPUTS:
/// - `offset` - an offset, a size or an address.
/// - `alignment` - a power of two.
///
/// RESULT:
/// The smallest multiple of `alignment` that is not below `offset`;
/// `offset` itself when it is aligned already.
///
/// BEHAVIOR:
/// A power of two has one bit set, so its multiples are the numbers whose
/// bits below it are clear: adding `alignment - 1` and clearing those
/// bits rounds up in two operations, with no division.
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
/// An `offset` within `alignment - 1` of the top of the address space
/// wraps to 0 instead of failing.
///
/// SEE ALSO:
/// `AlignDown`
///
/// EXAMPLES:
/// ```zig
/// const user_at = ub.AlignUp(name_at + len + 1, @alignOf(usize));
/// ```
pub fn AlignUp(_: *UtilityBase, offset: usize, alignment: usize) usize {
    const below = alignment -% 1;
    return (offset +% below) & ~below;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "AlignUp" {
    const ub: *UtilityBase = undefined; // AlignUp never reads it
    try testing.expectEqual(@as(usize, 0), AlignUp(ub, 0, 8));
    try testing.expectEqual(@as(usize, 8), AlignUp(ub, 1, 8));
    try testing.expectEqual(@as(usize, 8), AlignUp(ub, 8, 8));
    try testing.expectEqual(@as(usize, 16), AlignUp(ub, 9, 8));
    try testing.expectEqual(@as(usize, 13), AlignUp(ub, 13, 1));
    try testing.expectEqual(@as(usize, 0x4000), AlignUp(ub, 0x3001, 0x1000));
}

// SPDX-License-Identifier: MPL-2.0
//! SMult64: the whole 64-bit product of two signed 32-bit numbers.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Multiplies two signed 32-bit numbers into their whole 64-bit product.
///
/// SYNOPSIS:
/// ```zig
/// fn SMult64(_: *UtilityBase, arg1: i32, arg2: i32) i64
/// ```
///
/// SINCE: 1.0. LVO -132.
///
/// INPUTS:
/// - `arg1` - the one factor.
/// - `arg2` - the other.
///
/// RESULT:
/// The product. It always fits, so nothing is lost.
///
/// BEHAVIOR:
/// A 32 by 32 bit multiplication cannot overflow 64 bits. `SMult32` is the
/// call for the low 32 bits alone.
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
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SMult32`, `SDivMod32`
///
/// EXAMPLES:
/// ```zig
/// const bytes = ub.SMult64(width, height);
/// ```
pub fn SMult64(_: *UtilityBase, arg1: i32, arg2: i32) i64 {
    return @as(i64, arg1) * arg2;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "SMult64" {
    const ub: *UtilityBase = undefined; // SMult64 never reads it
    try testing.expectEqual(@as(i64, -0x1_0000_0000), SMult64(ub, std.math.minInt(i32), 2));
}

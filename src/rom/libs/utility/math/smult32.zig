// SPDX-License-Identifier: MPL-2.0
//! SMult32: the low 32 bits of a signed 32-bit product.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Multiplies two signed 32-bit numbers and keeps the low 32 bits.
///
/// SYNOPSIS:
/// ```zig
/// fn SMult32(_: *UtilityBase, arg1: i32, arg2: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -92.
///
/// INPUTS:
/// - `arg1` - the one factor.
/// - `arg2` - the other.
///
/// RESULT:
/// The low 32 bits of the product. An overflow wraps.
///
/// BEHAVIOR:
/// The low half of the product, which is the same bits whatever the
/// signs; `SMult64` gives the whole product.
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
/// `SMult64`, `SDivMod32`
///
/// EXAMPLES:
/// ```zig
/// const area = ub.SMult32(width, height);
/// ```
pub fn SMult32(_: *UtilityBase, arg1: i32, arg2: i32) i32 {
    return arg1 *% arg2;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "SMult32" {
    const ub: *UtilityBase = undefined; // SMult32 never reads it
    try testing.expectEqual(@as(i32, -21), SMult32(ub, -3, 7));
    try testing.expectEqual(@as(i32, 0), SMult32(ub, 0x10000, 0x10000));
}

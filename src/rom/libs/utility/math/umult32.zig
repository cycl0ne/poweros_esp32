// SPDX-License-Identifier: MPL-2.0
//! UMult32: the low 32 bits of an unsigned 32-bit product.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Multiplies two unsigned 32-bit numbers and keeps the low 32 bits.
///
/// SYNOPSIS:
/// ```zig
/// fn UMult32(_: *UtilityBase, arg1: u32, arg2: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -96.
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
/// signs; `UMult64` gives the whole product.
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
/// `UMult64`, `UDivMod32`
///
/// EXAMPLES:
/// ```zig
/// const area = ub.UMult32(width, height);
/// ```
pub fn UMult32(_: *UtilityBase, arg1: u32, arg2: u32) u32 {
    return arg1 *% arg2;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "UMult32" {
    const ub: *UtilityBase = undefined; // UMult32 never reads it
    try testing.expectEqual(@as(u32, 0xFFFF_FFFE), UMult32(ub, 0xFFFF_FFFF, 2));
}

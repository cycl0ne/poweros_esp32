// SPDX-License-Identifier: MPL-2.0
//! UMult64: the whole 64-bit product of two unsigned 32-bit numbers.

const std = @import("std");

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Multiplies two unsigned 32-bit numbers into their whole 64-bit product.
///
/// SYNOPSIS:
/// ```zig
/// fn UMult64(_: *UtilityBase, arg1: u32, arg2: u32) u64
/// ```
///
/// SINCE: 1.0. LVO -136.
///
/// INPUTS:
/// - `arg1` - the one factor.
/// - `arg2` - the other.
///
/// RESULT:
/// The product. It always fits, so nothing is lost.
///
/// BEHAVIOR:
/// A 32 by 32 bit multiplication cannot overflow 64 bits. `UMult32` is the
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
/// `UMult32`, `UDivMod32`
///
/// EXAMPLES:
/// ```zig
/// const bytes = ub.UMult64(width, height);
/// ```
pub fn UMult64(_: *UtilityBase, arg1: u32, arg2: u32) u64 {
    return @as(u64, arg1) * arg2;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "UMult64" {
    const ub: *UtilityBase = undefined; // UMult64 never reads it
    try testing.expectEqual(@as(u64, 0xFFFF_FFFE_0000_0001), UMult64(ub, 0xFFFF_FFFF, 0xFFFF_FFFF));
}

// SPDX-License-Identifier: MPL-2.0
//! UDivMod32: unsigned 32-bit quotient and remainder. A zero divisor is
//! exec's dead-end alert.

const std = @import("std");
const sdk = @import("sdk");
const _math = @import("_math.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const UDivMod32Result = sdk.utility.UDivMod32Result;

/// Divides two unsigned 32-bit numbers into a quotient and a remainder.
///
/// SYNOPSIS:
/// ```zig
/// fn UDivMod32(ub: *UtilityBase, dividend: u32, divisor: u32) UDivMod32Result
/// ```
///
/// SINCE: 1.0. LVO -104.
///
/// INPUTS:
/// - `dividend` - the number divided.
/// - `divisor` - what it is divided by. Not 0.
///
/// RESULT:
/// `quotient` and `remainder`, with `dividend = quotient * divisor +
/// remainder`. A zero divisor does not return.
///
/// BEHAVIOR:
/// A zero divisor is a programming error with no answer to give, and ends
/// in exec's dead-end alert for a division by zero (`ACPU_DivZero`).
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. A zero divisor ends in `Alert`, which is safe there
///   too.
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
/// `SDivMod32`, `UMult32`
///
/// EXAMPLES:
/// ```zig
/// const r = ub.UDivMod32(17, 5); // quotient 3, remainder 2
/// ```
pub fn UDivMod32(ub: *UtilityBase, dividend: u32, divisor: u32) UDivMod32Result {
    if (divisor == 0) {
        ub.sys_base.Alert(_math.ACPU_DivZero);
        return .{ .quotient = 0, .remainder = 0 };
    }
    return .{ .quotient = dividend / divisor, .remainder = dividend % divisor };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "UDivMod32" {
    const ub: *UtilityBase = undefined; // read only for a zero divisor
    try testing.expectEqual(UDivMod32Result{ .quotient = 3, .remainder = 2 }, UDivMod32(ub, 17, 5));
    try testing.expectEqual(UDivMod32Result{ .quotient = 0x7FFF_FFFF, .remainder = 1 }, UDivMod32(ub, 0xFFFF_FFFF, 2));
}

// SPDX-License-Identifier: MPL-2.0
//! SDivMod32: signed 32-bit quotient and remainder, rounded towards zero.
//! A zero divisor is exec's dead-end alert.

const std = @import("std");
const sdk = @import("sdk");
const _math = @import("_math.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const SDivMod32Result = sdk.utility.SDivMod32Result;

/// Divides two signed 32-bit numbers into a quotient and a remainder.
///
/// SYNOPSIS:
/// ```zig
/// fn SDivMod32(ub: *UtilityBase, dividend: i32, divisor: i32) SDivMod32Result
/// ```
///
/// SINCE: 1.0. LVO -100.
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
/// The quotient is rounded towards zero, so the remainder has the
/// dividend's sign: -7 / 2 is -3 remainder -1. The smallest number divided
/// by -1 wraps to itself, remainder 0, instead of faulting.
///
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
/// `UDivMod32`, `SMult32`
///
/// EXAMPLES:
/// ```zig
/// const r = ub.SDivMod32(-7, 2); // quotient -3, remainder -1
/// ```
pub fn SDivMod32(ub: *UtilityBase, dividend: i32, divisor: i32) SDivMod32Result {
    if (divisor == 0) {
        ub.sys_base.Alert(_math.ACPU_DivZero);
        return .{ .quotient = 0, .remainder = 0 };
    }
    const quotient = if (divisor == -1) 0 -% dividend else @divTrunc(dividend, divisor);
    return .{ .quotient = quotient, .remainder = dividend -% quotient *% divisor };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "SDivMod32 rounds towards zero" {
    const ub: *UtilityBase = undefined; // read only for a zero divisor
    try testing.expectEqual(SDivMod32Result{ .quotient = -3, .remainder = -1 }, SDivMod32(ub, -7, 2));
    try testing.expectEqual(SDivMod32Result{ .quotient = -3, .remainder = 1 }, SDivMod32(ub, 7, -2));
    try testing.expectEqual(SDivMod32Result{ .quotient = 3, .remainder = -1 }, SDivMod32(ub, -7, -2));
    const min = std.math.minInt(i32);
    try testing.expectEqual(SDivMod32Result{ .quotient = min, .remainder = 0 }, SDivMod32(ub, min, -1));
}

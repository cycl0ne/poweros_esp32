// SPDX-License-Identifier: MIT
//! MediaKeys' volume steps: a percent a step up or down, onto the
//! multiples of the step, between 0 and 100. Nothing here touches the
//! system, so the host tests hold it.

/// STEP when none is given, and the most it may be.
pub const default_step = 5;
pub const most_step = 50;

/// `percent` a step of `step` up or down, onto the multiples of `step`:
/// from 52 up 55 and down 50, from 50 up 55 and down 45; never past 0 or
/// 100.
pub fn stepped(percent: u32, up: bool, step: u32) u32 {
    if (up) return @min((percent / step + 1) * step, 100);
    if (percent == 0) return 0;
    return (percent - 1) / step * step;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "a step up and down lands on the step's multiples, and stays between 0 and 100" {
    try testing.expectEqual(@as(u32, 55), stepped(52, true, 5));
    try testing.expectEqual(@as(u32, 50), stepped(52, false, 5));
    try testing.expectEqual(@as(u32, 55), stepped(50, true, 5));
    try testing.expectEqual(@as(u32, 45), stepped(50, false, 5));
    try testing.expectEqual(@as(u32, 100), stepped(98, true, 5));
    try testing.expectEqual(@as(u32, 100), stepped(100, true, 5));
    try testing.expectEqual(@as(u32, 95), stepped(100, false, 5));
    try testing.expectEqual(@as(u32, 0), stepped(3, false, 5));
    try testing.expectEqual(@as(u32, 0), stepped(0, false, 5));
    try testing.expectEqual(@as(u32, 5), stepped(0, true, 5));
    // A step that does not divide 100: its last multiple, then 100.
    try testing.expectEqual(@as(u32, 99), stepped(97, true, 3));
    try testing.expectEqual(@as(u32, 100), stepped(99, true, 3));
    try testing.expectEqual(@as(u32, 99), stepped(100, false, 3));
    try testing.expectEqual(@as(u32, 50), stepped(0, true, 50));
}

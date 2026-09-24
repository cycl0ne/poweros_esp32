// SPDX-License-Identifier: MPL-2.0
//! Amiga2Date: seconds since 1 January 1978 as a ClockData, through the
//! civil calendar counted in days since 1970.

const std = @import("std");
const sdk = @import("sdk");
const _date = @import("_date.zig");

const UtilityBase = @import("../utility.zig").UtilityBase;
const ClockData = sdk.utility.ClockData;

/// Turns seconds since 1 January 1978 into a date.
///
/// SYNOPSIS:
/// ```zig
/// fn Amiga2Date(_: *UtilityBase, seconds: u32, result: *ClockData) void
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `seconds` - since 1 January 1978, 00:00:00. The whole range is valid,
///   up to 7 February 2114, 06:28:15.
/// - `result` - filled in.
///
/// RESULT:
/// Nothing. `result` holds the second, minute, hour, day of the month,
/// month (1 to 12), year and weekday (0 is Sunday).
///
/// BEHAVIOR:
/// The Gregorian calendar: 2000 is a leap year, 2100 is not. There is no
/// time zone and there are no leap seconds - a day is 86400 seconds.
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
/// `Date2Amiga`, `CheckDate`
///
/// EXAMPLES:
/// ```zig
/// var cd: ClockData = .{};
/// ub.Amiga2Date(seconds, &cd);
/// ```
pub fn Amiga2Date(_: *UtilityBase, seconds: u32, result: *ClockData) void {
    const days = seconds / _date.secs_per_day;
    const rest = seconds % _date.secs_per_day;
    const civil = _date.civilFromDays(days + _date.amiga_epoch);
    result.* = .{
        .sec = @intCast(rest % 60),
        .min = @intCast(rest / 60 % 60),
        .hour = @intCast(rest / 3600),
        .mday = civil.day,
        .month = civil.month,
        .year = civil.year,
        .wday = @intCast(days % 7),
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "Amiga2Date: 1978, 2000, 2017 and the last second" {
    const ub: *UtilityBase = undefined; // the date calls never read it
    var cd: ClockData = .{};
    Amiga2Date(ub, 0, &cd);
    try testing.expectEqual(ClockData{ .mday = 1, .month = 1, .year = 1978, .wday = 0 }, cd);
    Amiga2Date(ub, 694_224_000, &cd);
    try testing.expectEqual(ClockData{ .mday = 1, .month = 1, .year = 2000, .wday = 6 }, cd);
    Amiga2Date(ub, 1_234_567_890, &cd);
    try testing.expectEqual(ClockData{ .sec = 30, .min = 31, .hour = 23, .mday = 13, .month = 2, .year = 2017, .wday = 1 }, cd);
    Amiga2Date(ub, 0xFFFF_FFFF, &cd);
    try testing.expectEqual(ClockData{ .sec = 15, .min = 28, .hour = 6, .mday = 7, .month = 2, .year = 2114, .wday = 3 }, cd);
}

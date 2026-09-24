// SPDX-License-Identifier: MPL-2.0
//! CheckDate: a ClockData's seconds if it is a real date in range, else
//! 0 - the date converted there and back and compared.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const ClockData = sdk.utility.ClockData;
const Date2Amiga = @import("date2amiga.zig").Date2Amiga;

/// Checks that a date is real and in range, and returns its seconds since 1
/// January 1978.
///
/// SYNOPSIS:
/// ```zig
/// fn CheckDate(ub: *UtilityBase, clock_data: *const ClockData) u32
/// ```
///
/// SINCE: 1.0. LVO -88.
///
/// INPUTS:
/// - `clock_data` - the date to check. Its weekday is ignored.
///
/// RESULT:
/// The date as seconds since 1 January 1978, or 0 if it is not a date or
/// lies outside 1 January 1978, 00:00:00 to 7 February 2114, 06:28:15.
///
/// BEHAVIOR:
/// The date is turned into seconds and back, and it is a date if every
/// field but the weekday comes back as it went in. That one comparison is
/// every range check the calendar implies: days per month, leap years,
/// hours, minutes, seconds and the ends of the range.
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
/// 1 January 1978, 00:00:00 is a valid date whose seconds are 0, and so
/// cannot be told from a refusal.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Date2Amiga`, `Amiga2Date`
///
/// EXAMPLES:
/// ```zig
/// const seconds = ub.CheckDate(&cd);
/// if (seconds == 0) return error.BadDate;
/// ```
pub fn CheckDate(ub: *UtilityBase, clock_data: *const ClockData) u32 {
    const utility = ub.iface();
    const seconds = utility.Date2Amiga(clock_data);
    var back: ClockData = undefined;
    utility.Amiga2Date(seconds, &back);
    const same = back.sec == clock_data.sec and back.min == clock_data.min and
        back.hour == clock_data.hour and back.mday == clock_data.mday and
        back.month == clock_data.month and back.year == clock_data.year;
    return if (same) seconds else 0;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "CheckDate: leap years, ranges, the u32 limit" {
    const ub = try library.setUp();
    defer kexec.deinit();
    try testing.expect(CheckDate(ub, &.{ .mday = 29, .month = 2, .year = 2000 }) != 0);
    try testing.expect(CheckDate(ub, &.{ .mday = 29, .month = 2, .year = 1980 }) != 0);
    try testing.expectEqual(@as(u32, 0), CheckDate(ub, &.{ .mday = 29, .month = 2, .year = 1979 }));
    try testing.expectEqual(@as(u32, 0), CheckDate(ub, &.{ .mday = 29, .month = 2, .year = 2100 }));
    try testing.expectEqual(@as(u32, 0), CheckDate(ub, &.{ .mday = 31, .month = 4, .year = 2000 }));
    try testing.expectEqual(@as(u32, 0), CheckDate(ub, &.{ .mday = 1, .month = 13, .year = 2000 }));
    try testing.expectEqual(@as(u32, 0), CheckDate(ub, &.{ .mday = 0, .month = 1, .year = 2000 }));
    try testing.expectEqual(@as(u32, 0), CheckDate(ub, &.{ .hour = 24, .mday = 1, .month = 1, .year = 2000 }));
    try testing.expectEqual(@as(u32, 0), CheckDate(ub, &.{ .sec = 60, .mday = 1, .month = 1, .year = 2000 }));
    try testing.expectEqual(@as(u32, 0), CheckDate(ub, &.{ .mday = 31, .month = 12, .year = 1977 }));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), CheckDate(ub, &.{ .sec = 15, .min = 28, .hour = 6, .mday = 7, .month = 2, .year = 2114 }));
    try testing.expectEqual(@as(u32, 0), CheckDate(ub, &.{ .sec = 16, .min = 28, .hour = 6, .mday = 7, .month = 2, .year = 2114 }));
    // Unchecked garbage still gives a number.
    _ = Date2Amiga(ub, &.{ .mday = 99, .month = 0, .year = 0 });
    try library.tearDown(ub);
}

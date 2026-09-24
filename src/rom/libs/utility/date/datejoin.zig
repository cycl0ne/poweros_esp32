// SPDX-License-Identifier: MPL-2.0
//! DateJoin: the day number a date on the calendar falls on.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const ClockData = sdk.utility.ClockData;
const _date = @import("_date.zig");

/// What a date that is no date answers.
pub const no_date: i32 = -1;

/// The day number a date falls on.
///
/// SYNOPSIS:
/// ```zig
/// fn DateJoin(ub: *UtilityBase, date: *const ClockData) i32
/// ```
///
/// SINCE: 1.0. LVO -252.
///
/// INPUTS:
/// - `ub` - the library's base.
/// - `date` - the date. Only `year`, `month` (1 to 12) and `mday` (1 to
///   31) are read; the time fields and `wday` are ignored.
///
/// RESULT:
/// Days since 1 January 1978, which is day 0, or -1 when `date` is no
/// date: a month outside 1 to 12, a day the month does not have, or a
/// day before the count begins.
///
/// BEHAVIOR:
/// A day that the month does not have carries into the next month, so
/// the date is converted back and compared: the 31st of February comes
/// back as the 2nd or 3rd of March and is refused. So is the 29th of
/// February in a year that is not a leap year, which on the Gregorian
/// calendar includes 2100.
///
/// **-1 is the refusal, not 0.** Day 0 is a date - the day the count
/// starts on - so a call that answered 0 for both could not tell them
/// apart. `CheckDate` answers seconds and has that ambiguity; this does
/// not.
///
/// **It counts days, not seconds.** `Date2Amiga` answers seconds in 32
/// bits and so stops in 2114; this reaches any year a `ClockData` holds.
///
/// CONTEXT:
/// Waits: no. Interrupts: yes. Forbid: yes. Process: no.
///
/// OWNERSHIP:
/// Nothing is allocated. `date` is the caller's and is not written.
///
/// NOTES:
/// `DateSplit` is the inverse, and the two round-trip exactly.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DateSplit`, `Date2Amiga`, `CheckDate`
///
/// EXAMPLES:
/// ```zig
/// const days = ub.DateJoin(&.{ .year = 2026, .month = 9, .mday = 16 });
/// if (days < 0) return error.BadDate;
/// ```
pub fn DateJoin(_: *UtilityBase, date: *const ClockData) i32 {
    if (date.month < 1 or date.month > 12) return no_date;
    if (date.mday < 1 or date.mday > 31) return no_date;
    const days = _date.daysFromCivil(date.year, date.month, date.mday) - _date.amiga_epoch;
    if (days < 0) return no_date;
    // A day the month does not have carries forward, so the only way to
    // know the date was real is to convert it back and compare.
    const back = _date.civilFromDays(@intCast(days + _date.amiga_epoch));
    if (back.year != date.year or back.month != date.month or back.day != date.mday) return no_date;
    return @intCast(days);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");
const DateSplit = @import("datesplit.zig").DateSplit;

test "DateJoin: the day the count starts on is 0, not a refusal" {
    const ub = try library.setUp();
    defer kexec.deinit();

    try testing.expectEqual(@as(i32, 0), DateJoin(ub, &.{ .year = 1978, .month = 1, .mday = 1 }));
    try testing.expectEqual(@as(i32, 1), DateJoin(ub, &.{ .year = 1978, .month = 1, .mday = 2 }));
    // Before it there is nothing.
    try testing.expectEqual(no_date, DateJoin(ub, &.{ .year = 1977, .month = 12, .mday = 31 }));
}

test "DateJoin: a day the month does not have is refused, not carried" {
    const ub = try library.setUp();
    defer kexec.deinit();

    try testing.expectEqual(no_date, DateJoin(ub, &.{ .year = 2026, .month = 2, .mday = 31 }));
    try testing.expectEqual(no_date, DateJoin(ub, &.{ .year = 2026, .month = 2, .mday = 29 }));
    try testing.expectEqual(no_date, DateJoin(ub, &.{ .year = 2026, .month = 4, .mday = 31 }));
    try testing.expectEqual(no_date, DateJoin(ub, &.{ .year = 2026, .month = 13, .mday = 1 }));
    try testing.expectEqual(no_date, DateJoin(ub, &.{ .year = 2026, .month = 0, .mday = 1 }));
    try testing.expectEqual(no_date, DateJoin(ub, &.{ .year = 2026, .month = 1, .mday = 0 }));
    // A stamp of nothing at all is no date, which is what a medium
    // written by something without a clock holds.
    try testing.expectEqual(no_date, DateJoin(ub, &.{}));
    // But the days a month does have are not refused.
    try testing.expect(DateJoin(ub, &.{ .year = 2026, .month = 2, .mday = 28 }) > 0);
    try testing.expect(DateJoin(ub, &.{ .year = 2024, .month = 2, .mday = 29 }) > 0);
}

test "DateJoin: the leap years the four-year rule gets wrong" {
    const ub = try library.setUp();
    defer kexec.deinit();

    // 2000 is divisible by 400, so it is a leap year.
    try testing.expect(DateJoin(ub, &.{ .year = 2000, .month = 2, .mday = 29 }) > 0);
    // 2100 is divisible by 100 and not by 400, so it is not - and it is
    // inside the range a date on this system reaches.
    try testing.expectEqual(no_date, DateJoin(ub, &.{ .year = 2100, .month = 2, .mday = 29 }));
    try testing.expectEqual(no_date, DateJoin(ub, &.{ .year = 1900, .month = 2, .mday = 29 }));
}

test "DateJoin and DateSplit round-trip, including past 2114" {
    const ub = try library.setUp();
    defer kexec.deinit();

    const dates = [_]ClockData{
        .{ .year = 1978, .month = 1, .mday = 1 },
        .{ .year = 2026, .month = 9, .mday = 16 },
        .{ .year = 2024, .month = 2, .mday = 29 },
        .{ .year = 2100, .month = 3, .mday = 1 },
        // Past where the seconds-based calls stop.
        .{ .year = 2200, .month = 6, .mday = 15 },
        .{ .year = 9999, .month = 12, .mday = 31 },
    };
    for (dates) |date| {
        const days = DateJoin(ub, &date);
        try testing.expect(days >= 0);
        var back: ClockData = .{};
        DateSplit(ub, @intCast(days), &back);
        try testing.expectEqual(date.year, back.year);
        try testing.expectEqual(date.month, back.month);
        try testing.expectEqual(date.mday, back.mday);
    }
}

test "DateJoin agrees with the seconds-based calls where both reach" {
    const ub = try library.setUp();
    defer kexec.deinit();

    const utility = ub.iface();
    const date: ClockData = .{ .year = 2026, .month = 9, .mday = 16 };
    const days = DateJoin(ub, &date);
    try testing.expectEqual(
        @as(u32, @intCast(days)),
        utility.Date2Amiga(&date) / _date.secs_per_day,
    );
}

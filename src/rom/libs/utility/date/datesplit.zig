// SPDX-License-Identifier: MPL-2.0
//! DateSplit: a day number as a date on the calendar.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const ClockData = sdk.utility.ClockData;
const _date = @import("_date.zig");

/// A day number as the date it falls on.
///
/// SYNOPSIS:
/// ```zig
/// fn DateSplit(ub: *UtilityBase, days: u32, result: *ClockData) void
/// ```
///
/// SINCE: 1.0. LVO -248.
///
/// INPUTS:
/// - `ub` - the library's base.
/// - `days` - days since 1 January 1978, which is day 0.
/// - `result` - filled in with the date.
///
/// RESULT:
/// Nothing. `result` is always written.
///
/// BEHAVIOR:
/// `result.year`, `result.month` (1 to 12), `result.mday` (1 to 31) and
/// `result.wday` (0 for Sunday) are the date `days` falls on. The time
/// fields are set to 0: a day number says nothing about the time of day.
///
/// The calendar is the Gregorian one, so a year divisible by 100 is a
/// leap year only when it is also divisible by 400 - 2000 is, 2100 is
/// not.
///
/// **It counts days, not seconds.** `Amiga2Date` takes seconds in 32
/// bits and so stops in 2114; this takes days and reaches the last year
/// a `ClockData` holds. A caller with a day number and no time of day
/// wants this one.
///
/// A day number past that last year answers with the last date there
/// is, rather than with a year that has wrapped.
///
/// CONTEXT:
/// Waits: no. Interrupts: yes. Forbid: yes. Process: no.
///
/// OWNERSHIP:
/// Nothing is allocated. `result` is the caller's.
///
/// NOTES:
/// `DateJoin` is the inverse, and the two round-trip exactly for every
/// day number this takes.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DateJoin`, `Amiga2Date`, `CheckDate`
///
/// EXAMPLES:
/// ```zig
/// var cd: ClockData = .{};
/// ub.DateSplit(17_790, &cd); // 16 September 2026, a Wednesday
/// ```
pub fn DateSplit(_: *UtilityBase, days: u32, result: *ClockData) void {
    // A year past what the field holds has no date to answer with, so
    // the last one there is stands in for it.
    const at = @min(days, _date.max_days);
    const civil = _date.civilFromDays(at + _date.amiga_epoch);
    result.* = .{
        .sec = 0,
        .min = 0,
        .hour = 0,
        .mday = civil.day,
        .month = civil.month,
        .year = civil.year,
        // Day 0 was a Sunday, and the weekdays have run unbroken since.
        .wday = @intCast(days % 7),
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "DateSplit: the day the count starts on, and a day in this decade" {
    const ub = try library.setUp();
    defer kexec.deinit();

    var cd: ClockData = .{};
    DateSplit(ub, 0, &cd);
    try testing.expectEqual(@as(u16, 1978), cd.year);
    try testing.expectEqual(@as(u16, 1), cd.month);
    try testing.expectEqual(@as(u16, 1), cd.mday);
    // 1 January 1978 was a Sunday.
    try testing.expectEqual(@as(u16, 0), cd.wday);
    // A day number says nothing about the time of day.
    try testing.expectEqual(@as(u16, 0), cd.hour);
    try testing.expectEqual(@as(u16, 0), cd.min);
    try testing.expectEqual(@as(u16, 0), cd.sec);

    DateSplit(ub, 17_790, &cd);
    try testing.expectEqual(@as(u16, 2026), cd.year);
    try testing.expectEqual(@as(u16, 9), cd.month);
    try testing.expectEqual(@as(u16, 16), cd.mday);
    try testing.expectEqual(@as(u16, 3), cd.wday); // a Wednesday
}

test "DateSplit: leap years, and the ones that only look like them" {
    const ub = try library.setUp();
    defer kexec.deinit();

    var cd: ClockData = .{};
    // 2000 is a leap year: divisible by 400.
    const feb29_2000 = DateJoinFor(ub, 2000, 2, 29);
    DateSplit(ub, @intCast(feb29_2000), &cd);
    try testing.expectEqual(@as(u16, 2000), cd.year);
    try testing.expectEqual(@as(u16, 2), cd.month);
    try testing.expectEqual(@as(u16, 29), cd.mday);

    // 2100 is not: the day after 28 February 2100 is 1 March.
    const feb28_2100 = DateJoinFor(ub, 2100, 2, 28);
    DateSplit(ub, @intCast(feb28_2100 + 1), &cd);
    try testing.expectEqual(@as(u16, 3), cd.month);
    try testing.expectEqual(@as(u16, 1), cd.mday);
}

test "a day number past the last year answers with the last date" {
    const ub = try library.setUp();
    defer kexec.deinit();

    var edge: ClockData = .{};
    DateSplit(ub, _date.max_days, &edge);
    try testing.expectEqual(@as(u16, 65535), edge.year);
    try testing.expectEqual(@as(u16, 12), edge.month);
    try testing.expectEqual(@as(u16, 31), edge.mday);

    var over: ClockData = .{};
    DateSplit(ub, 0xFFFF_FFFF, &over);
    try testing.expectEqual(edge.year, over.year);
    try testing.expectEqual(edge.month, over.month);
    try testing.expectEqual(edge.mday, over.mday);
}

test "DateSplit: past the year the seconds-based calls stop at" {
    const ub = try library.setUp();
    defer kexec.deinit();

    // Amiga2Date takes seconds in 32 bits and so reaches 2114. This
    // takes days, so the last year a date string writes is still a date.
    var cd: ClockData = .{};
    const last = DateJoinFor(ub, 9999, 12, 31);
    try testing.expect(last > 0);
    DateSplit(ub, @intCast(last), &cd);
    try testing.expectEqual(@as(u16, 9999), cd.year);
    try testing.expectEqual(@as(u16, 12), cd.month);
    try testing.expectEqual(@as(u16, 31), cd.mday);
}

/// The day number of a date, for the tests above.
fn DateJoinFor(ub: *UtilityBase, year: u16, month: u16, day: u16) i32 {
    const join = @import("datejoin.zig").DateJoin;
    return join(ub, &.{ .year = year, .month = month, .mday = day });
}

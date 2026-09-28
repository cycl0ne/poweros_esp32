// SPDX-License-Identifier: MIT
//! Host tests of `sdk/libs/dos/timezone.zig`, the POSIX TZ rules C:net/TimeSync
//! and fat-handler turn UTC into local time by.

const std = @import("std");
const timezone = @import("sdk").dos.timezone;
const Zone = timezone.Zone;
const parse = timezone.parse;
const civilFromDays = timezone.civilFromDays;
const daysFromCivil = timezone.daysFromCivil;
const Civil = timezone.Civil;
const testing = std.testing;

fn utcOf(year: i32, month: u8, day: u8, hour: i64, minute: i64) i64 {
    return daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60;
}

test "the calendar both ways" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 2922), daysFromCivil(1978, 1, 1));
    try testing.expectEqual(Civil{ .year = 2024, .month = 2, .day = 29 }, civilFromDays(daysFromCivil(2024, 2, 29)));
    try testing.expectEqual(Civil{ .year = 1969, .month = 12, .day = 31 }, civilFromDays(-1));
    var days: i64 = -800;
    while (days < 30000) : (days += 17) {
        const date = civilFromDays(days);
        try testing.expectEqual(days, daysFromCivil(date.year, date.month, date.day));
    }
}

test "Central Europe: summer time from the last Sunday of March to the last of October" {
    const zone = parse("CET-1CEST,M3.5.0,M10.5.0/3").?;
    try testing.expectEqual(@as(i32, 3600), zone.standard);
    try testing.expectEqual(@as(i32, 7200), zone.summer);
    // 2026: 29 March 01:00 UTC and 25 October 01:00 UTC.
    try testing.expectEqual(@as(i32, 3600), zone.offsetAt(utcOf(2026, 3, 29, 0, 59)));
    try testing.expectEqual(@as(i32, 7200), zone.offsetAt(utcOf(2026, 3, 29, 1, 0)));
    try testing.expectEqual(@as(i32, 7200), zone.offsetAt(utcOf(2026, 10, 25, 0, 59)));
    try testing.expectEqual(@as(i32, 3600), zone.offsetAt(utcOf(2026, 10, 25, 1, 0)));
    try testing.expectEqual(@as(i32, 3600), zone.offsetAt(utcOf(2026, 1, 15, 12, 0)));
}

test "the south, zones without summer time, and names in angle brackets" {
    // New Zealand: summer from the last Sunday of September to the first
    // of April, across the new year.
    const zone = parse("NZST-12NZDT,M9.5.0,M4.1.0/3").?;
    try testing.expectEqual(@as(i32, 13 * 3600), zone.offsetAt(utcOf(2026, 1, 10, 0, 0)));
    try testing.expectEqual(@as(i32, 12 * 3600), zone.offsetAt(utcOf(2026, 6, 10, 0, 0)));
    try testing.expectEqual(@as(i32, 13 * 3600), zone.offsetAt(utcOf(2026, 12, 10, 0, 0)));
    try testing.expectEqual(@as(i32, 19800), parse("<+0530>-5:30").?.offsetAt(0));
    try testing.expectEqual(@as(i32, 0), parse("UTC0").?.offsetAt(utcOf(2026, 7, 1, 0, 0)));
    try testing.expectEqual(@as(i32, -5 * 3600), parse("EST5").?.offsetAt(0));
    // A summer time and no dates: March's second Sunday to November's first.
    const us = parse("EST5EDT").?;
    try testing.expectEqual(@as(i32, -4 * 3600), us.offsetAt(utcOf(2026, 7, 1, 0, 0)));
    try testing.expectEqual(@as(i32, -5 * 3600), us.offsetAt(utcOf(2026, 3, 8, 6, 59)));
    try testing.expectEqual(@as(i32, -4 * 3600), us.offsetAt(utcOf(2026, 3, 8, 7, 0)));
    // Julian days: J60 is 1 March in every year; 59 counted from 0 is 29
    // February in a leap year.
    const julian = parse("AAA0BBB,J60/0,300").?;
    try testing.expectEqual(@as(i32, 0), julian.offsetAt(utcOf(2024, 2, 29, 23, 0)));
    try testing.expectEqual(@as(i32, 3600), julian.offsetAt(utcOf(2024, 3, 1, 0, 0)));
}

test "rules that are not ones" {
    for ([_][]const u8{ "", "CE-1", "CET", "CET-1CEST,M3.5.0", "CET-1CEST,M13.5.0,M10.5.0", "CET-1CEST,M3.6.0,M10.5.0", "CET-1CEST,M3.5.7,M10.5.0", "CET-99", "CET-1CEST,J0,J5", "<AB>1", "CET-1 ", "CET-1CEST,M3.5.0,M10.5.0/200" }) |text| {
        try testing.expectEqual(@as(?Zone, null), parse(text));
    }
}

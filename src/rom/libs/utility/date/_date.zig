// SPDX-License-Identifier: MPL-2.0
//! What the date calls share: the seconds in a day, the day the count of
//! seconds starts on (1 January 1978), and the zone the system clock
//! keeps - the rule battmem.resource holds, read for each call that turns
//! local time into UTC or back.

const sdk = @import("sdk");
const dos = sdk.dos;
const timezone = dos.timezone;
const battmem = sdk.resources.battmem;
const battmembits = sdk.resources.battmembits;
const UtilityBase = @import("../utility_base.zig").UtilityBase;

/// Seconds in a day: there are no leap seconds.
pub const secs_per_day = 24 * 60 * 60;
/// Days from 1 January 1970 to 1 January 1978, day 0 of the count (a
/// Sunday).
pub const amiga_epoch = 2922;

/// The largest day number a date can be made of: the last day of the
/// last year a `ClockData` year holds. Past it there is no date to
/// answer with.
pub const max_days: u32 = 23_214_081;

/// A date as days since 1 January 1970, the inverse of `civilFromDays`. Any
/// fields give some number, which is what lets `Date2Amiga` take an
/// unchecked date.
///
/// INPUTS:
/// - `year` - the year.
/// - `month` - the month, 1 to 12; others carry into the year.
/// - `day` - the day of the month; others carry into the month.
pub fn daysFromCivil(year: u16, month: u16, day: u16) i64 {
    const y = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

/// A date on the civil calendar: year, month (1 to 12), day (1 to 31).
pub const Civil = struct { year: u16, month: u16, day: u16 };

/// Days since 1 January 1970 as a date, counted in 400-year eras of 146097
/// days, which the Gregorian calendar repeats exactly.
///
/// INPUTS:
/// - `days` - days since 1 January 1970; 1970 and after only.
pub fn civilFromDays(days: u32) Civil {
    const z = days + 719_468;
    const era = z / 146_097;
    const doe = z - era * 146_097;
    const yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const day = doy - (153 * mp + 2) / 5 + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @intFromBool(month <= 2);
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

// --- the zone the clock keeps ------------------------------------------------

/// Ticks of a DateStamp in a second.
pub const ticks_per_second = 50;

/// The zone the system clock keeps: battmem.resource's BATTMEM_ZONE,
/// which `C:SetClock ZONE` writes from ENV:Sys/timezone at boot and Prefs
/// writes again when the zone changes. UTC while nobody wrote it, or on a
/// system without the resource.
///
/// INPUTS:
/// - `ub` - the library's base, where the resource is kept once found.
pub fn systemZone(ub: *UtilityBase) timezone.Zone {
    // The resource comes after the library at cold start, so it is looked
    // for at the first call that needs it, not at init.
    const mb = ub.batt_mem orelse found: {
        const resource = ub.sys_base.OpenResource(battmem.BATTMEMNAME) orelse return .{};
        const base: *battmem.BattMemBase = @ptrCast(resource);
        ub.batt_mem = base;
        break :found base;
    };
    var bits: u64 = 0;
    if (mb.ReadBattMem(@ptrCast(&bits), battmembits.BATTMEM_ZONE_ADDR, battmembits.BATTMEM_ZONE_LEN) != 0) return .{};
    return timezone.unpack(bits) orelse .{};
}

/// A DateStamp as seconds since 1970 on the clock it was read from - local
/// time, the same count as UTC's but for the zone's offset.
///
/// INPUTS:
/// - `date` - the stamp: days since 1978, minutes into the day, ticks into
///   the minute.
pub fn localSeconds(date: *const dos.DateStamp) i64 {
    return timezone.datestamp_epoch + @as(i64, date.days) * secs_per_day + @as(i64, date.minute) * 60 + @divFloor(@as(i64, date.tick), ticks_per_second);
}

/// The UTC a local time stands for in `zone`. The offset is the one at
/// that moment in UTC, which is what is being found: a first guess with the
/// offset at the local time read as UTC is a moment near enough to give it,
/// but within the hour summer time starts or ends.
///
/// INPUTS:
/// - `zone` - the zone the local time is kept in.
/// - `local` - seconds since 1970, local time.
pub fn utcOfLocal(zone: *const timezone.Zone, local: i64) i64 {
    const guess = local - zone.offsetAt(local);
    return local - zone.offsetAt(guess);
}

/// Seconds since 1970, local time, as a DateStamp: the stamp's start for
/// a moment before 1978, its last day for one past what its days hold.
///
/// INPUTS:
/// - `local` - seconds since 1970, local time.
pub fn stampOfLocal(local: i64) dos.DateStamp {
    const since = local - timezone.datestamp_epoch;
    if (since < 0) return .{};
    const days = @divFloor(since, secs_per_day);
    const last_day: i64 = 0x7FFF_FFFF;
    if (days > last_day) return .{ .days = 0x7FFF_FFFF, .minute = 24 * 60 - 1, .tick = 60 * ticks_per_second - 1 };
    const into_day = since - days * secs_per_day;
    return .{
        .days = @intCast(days),
        .minute = @intCast(@divFloor(into_day, 60)),
        .tick = @intCast(@mod(into_day, 60) * ticks_per_second),
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

/// Central Europe: an hour east of UTC, two in summer, from the last
/// Sunday of March at 02:00 to the last Sunday of October at 03:00.
const cet = timezone.parse("CET-1CEST,M3.5.0,M10.5.0/3").?;

/// Seconds since 1970 of a date and time, for the tests.
fn moment(year: u16, month: u16, day: u16, hour: i64, minute: i64) i64 {
    return daysFromCivil(year, month, day) * secs_per_day + hour * 3600 + minute * 60;
}

test "local time to UTC: winter, summer, and the hours the clocks change in" {
    // 9 November 2026, 12:00 in Berlin is 11:00 UTC.
    try testing.expectEqual(moment(2026, 11, 9, 11, 0), utcOfLocal(&cet, moment(2026, 11, 9, 12, 0)));
    // 1 July 2026, 12:00 there is 10:00 UTC.
    try testing.expectEqual(moment(2026, 7, 1, 10, 0), utcOfLocal(&cet, moment(2026, 7, 1, 12, 0)));
    // Summer time starts on 29 March 2026 at 02:00, the clocks going to
    // 03:00: 03:30 that morning is summer time, 01:00 UTC.
    try testing.expectEqual(moment(2026, 3, 29, 1, 30), utcOfLocal(&cet, moment(2026, 3, 29, 3, 30)));
    // 01:30 is still winter time: 00:30 UTC.
    try testing.expectEqual(moment(2026, 3, 29, 0, 30), utcOfLocal(&cet, moment(2026, 3, 29, 1, 30)));
    // It ends on 25 October at 03:00, the clocks going back to 02:00:
    // 03:30 is winter time again, 02:30 UTC.
    try testing.expectEqual(moment(2026, 10, 25, 2, 30), utcOfLocal(&cet, moment(2026, 10, 25, 3, 30)));
}

test "UTC as the system's zone keeps the count as it is" {
    const utc: timezone.Zone = .{};
    try testing.expectEqual(moment(2026, 11, 9, 12, 0), utcOfLocal(&utc, moment(2026, 11, 9, 12, 0)));
}

test "a DateStamp and its seconds, both ways" {
    // 16 September 2026 is day 17790; 13:45:07 and a fifth of a second.
    const stamp: dos.DateStamp = .{ .days = 17_790, .minute = 13 * 60 + 45, .tick = 7 * ticks_per_second + 10 };
    const seconds = localSeconds(&stamp);
    try testing.expectEqual(moment(2026, 9, 16, 13, 45) + 7, seconds);
    const back = stampOfLocal(seconds);
    try testing.expectEqual(stamp.days, back.days);
    try testing.expectEqual(stamp.minute, back.minute);
    // The fraction of a second is the caller's: the count has none.
    try testing.expectEqual(@as(i32, 7 * ticks_per_second), back.tick);
}

test "a moment a DateStamp cannot hold: its start, or its last day" {
    const before = stampOfLocal(moment(1977, 12, 31, 23, 0));
    try testing.expect(before.eql(.{}));
    const far = stampOfLocal(@as(i64, 0x7FFF_FFFF) * 3 * secs_per_day);
    try testing.expectEqual(@as(i32, 0x7FFF_FFFF), far.days);
}

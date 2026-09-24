// SPDX-License-Identifier: MPL-2.0
//! What the date calls share: the seconds in a day, and the day the
//! count of seconds starts on (1 January 1978).

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

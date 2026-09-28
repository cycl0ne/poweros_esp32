// SPDX-License-Identifier: MIT
//! A time zone as a POSIX TZ rule, and the offset from UTC it gives at a
//! moment: what turns the UTC a time server answers into the local time
//! the system clock keeps.
//!
//!   std offset [dst [offset] [,start[/time],end[/time]]]
//!
//! `CET-1CEST,M3.5.0,M10.5.0/3` is Central European Time, one hour east
//! of UTC, and summer time from the last Sunday of March at 02:00 to the
//! last Sunday of October at 03:00. An offset is the hours to add to local
//! time to get UTC - west is positive - as `[+-]hh[:mm[:ss]]`. A name is
//! three letters or more, or anything between `<` and `>` (`<+0530>`).
//! Summer time is an hour ahead of standard unless its offset is given. A
//! date is `Mm.w.d` (day d of week w of month m, week 5 the last, Sunday
//! 0), `Jn` (day n of 365, 29 February never counted) or `n` (day n from
//! 0, leap days counted); its time is 02:00 unless given, and may run
//! from -167 to 167 hours. With a summer time and no dates, the dates are
//! March's second Sunday and November's first.
//!
//! Times are seconds since 1 January 1970, UTC.

/// Where the system's rule is kept: its first line that is not a `#`
/// comment. The system clock keeps the local time this rule gives.
pub const zone_file = "ENVARC:Sys/timezone";

/// Seconds from 1 January 1970, where these times count from, to
/// 1 January 1978, where a DateStamp counts from.
pub const datestamp_epoch: i64 = 2922 * 86400;

/// A rule's date of change: which day of the year, and when in it.
pub const Change = struct {
    kind: enum { month_week_day, julian_no_leap, julian } = .month_week_day,
    month: u8 = 0,
    week: u8 = 0,
    weekday: u8 = 0,
    day: u16 = 0,
    /// Seconds after the local midnight, in the time that holds before it.
    seconds: i32 = 2 * 3600,
};

pub const Zone = struct {
    /// Seconds east of UTC, in standard time and in summer time.
    standard: i32 = 0,
    summer: i32 = 0,
    has_summer: bool = false,
    start: Change = .{ .month = 3, .week = 2 },
    end: Change = .{ .month = 11, .week = 1 },

    /// The seconds to add to `utc` to get the local time then.
    pub fn offsetAt(zone: *const Zone, utc: i64) i32 {
        if (!zone.has_summer) return zone.standard;
        const year = civilFromDays(@divFloor(utc, 86400)).year;
        // The start is given in standard time, the end in summer time.
        const starts = changeDay(year, zone.start) * 86400 + zone.start.seconds - zone.standard;
        const ends = changeDay(year, zone.end) * 86400 + zone.end.seconds - zone.summer;
        const summer = if (starts < ends) utc >= starts and utc < ends else !(utc >= ends and utc < starts);
        return if (summer) zone.summer else zone.standard;
    }
};

/// The rule in `text`, or null when it is not one.
pub fn parse(text: []const u8) ?Zone {
    var reader: Reader = .{ .text = text };
    var zone: Zone = .{};
    if (!reader.name()) return null;
    zone.standard = -(reader.offset() orelse return null);
    zone.summer = zone.standard + 3600;
    if (reader.at == text.len) return zone;
    if (!reader.name()) return null;
    zone.has_summer = true;
    if (reader.peek() != ',' and reader.at < text.len) zone.summer = -(reader.offset() orelse return null);
    if (reader.at == text.len) return zone;
    if (!reader.take(',')) return null;
    zone.start = reader.change() orelse return null;
    if (!reader.take(',')) return null;
    zone.end = reader.change() orelse return null;
    if (reader.at != text.len) return null;
    return zone;
}

const Reader = struct {
    text: []const u8,
    at: usize = 0,

    fn peek(reader: *const Reader) u8 {
        return if (reader.at < reader.text.len) reader.text[reader.at] else 0;
    }

    fn take(reader: *Reader, char: u8) bool {
        if (reader.peek() != char) return false;
        reader.at += 1;
        return true;
    }

    /// A zone's name: three letters or more, or `<...>`.
    fn name(reader: *Reader) bool {
        if (reader.take('<')) {
            const from = reader.at;
            while (reader.at < reader.text.len and reader.text[reader.at] != '>') reader.at += 1;
            if (reader.at - from < 3 or !reader.take('>')) return false;
            return true;
        }
        const from = reader.at;
        while (reader.at < reader.text.len) : (reader.at += 1) {
            const char = reader.text[reader.at] | 0x20;
            if (char < 'a' or char > 'z') break;
        }
        return reader.at - from >= 3;
    }

    fn number(reader: *Reader, most: u32) ?u32 {
        const from = reader.at;
        var value: u32 = 0;
        while (reader.at < reader.text.len and reader.text[reader.at] >= '0' and reader.text[reader.at] <= '9') : (reader.at += 1) {
            value = value * 10 + (reader.text[reader.at] - '0');
            if (value > most) return null;
        }
        if (reader.at == from) return null;
        return value;
    }

    /// `[+-]hh[:mm[:ss]]` in seconds, hours up to `hours_most`.
    fn clock(reader: *Reader, hours_most: u32) ?i32 {
        var sign: i32 = 1;
        if (reader.take('-')) {
            sign = -1;
        } else {
            _ = reader.take('+');
        }
        var seconds: i32 = @intCast((reader.number(hours_most) orelse return null) * 3600);
        if (reader.take(':')) {
            seconds += @intCast((reader.number(59) orelse return null) * 60);
            if (reader.take(':')) seconds += @intCast(reader.number(59) orelse return null);
        }
        return sign * seconds;
    }

    /// An offset, west positive.
    fn offset(reader: *Reader) ?i32 {
        return reader.clock(24);
    }

    fn change(reader: *Reader) ?Change {
        var result: Change = .{};
        if (reader.take('M')) {
            result.month = @intCast(reader.number(12) orelse return null);
            if (!reader.take('.')) return null;
            result.week = @intCast(reader.number(5) orelse return null);
            if (!reader.take('.')) return null;
            result.weekday = @intCast(reader.number(6) orelse return null);
            if (result.month == 0 or result.week == 0) return null;
        } else if (reader.take('J')) {
            result.kind = .julian_no_leap;
            result.day = @intCast(reader.number(365) orelse return null);
            if (result.day == 0) return null;
        } else {
            result.kind = .julian;
            result.day = @intCast(reader.number(365) orelse return null);
        }
        if (reader.take('/')) result.seconds = reader.clock(167) orelse return null;
        return result;
    }
};

// --- the calendar ---------------------------------------------------------------

pub const Civil = struct { year: i32, month: u8, day: u8 };

/// Days since 1 January 1970 as a date (the proleptic Gregorian calendar).
pub fn civilFromDays(days: i64) Civil {
    const shifted = days + 719468;
    const era = @divFloor(shifted, 146097);
    const day_of_era = shifted - era * 146097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36524) - @divFloor(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_index = @divFloor(5 * day_of_year + 2, 153);
    const day: u8 = @intCast(day_of_year - @divFloor(153 * month_index + 2, 5) + 1);
    const month: u8 = @intCast(if (month_index < 10) month_index + 3 else month_index - 9);
    const year: i32 = @intCast(year_of_era + era * 400 + @as(i64, if (month <= 2) 1 else 0));
    return .{ .year = year, .month = month, .day = day };
}

/// A date as days since 1 January 1970.
pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const shifted_year: i64 = if (month <= 2) year - 1 else year;
    const era = @divFloor(shifted_year, 400);
    const year_of_era = shifted_year - era * 400;
    const month_index: i64 = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divFloor(153 * month_index + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn isLeap(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn monthDays(year: i32, month: u8) u8 {
    const lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return if (month == 2 and isLeap(year)) 29 else lengths[month - 1];
}

/// The day `change` falls on in `year`, as days since 1970.
fn changeDay(year: i32, change: Change) i64 {
    const first = daysFromCivil(year, 1, 1);
    switch (change.kind) {
        .julian => return first + change.day,
        .julian_no_leap => {
            const past_february = isLeap(year) and change.day > 59;
            return first + change.day - 1 + @intFromBool(past_february);
        },
        .month_week_day => {
            const month_first = daysFromCivil(year, change.month, 1);
            // 1 January 1970 was a Thursday (4).
            const weekday: i64 = @mod(month_first + 4, 7);
            var day = @mod(@as(i64, change.weekday) - weekday, 7) + @as(i64, change.week - 1) * 7;
            if (day >= monthDays(year, change.month)) day -= 7;
            return month_first + day;
        },
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

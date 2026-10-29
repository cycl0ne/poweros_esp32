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

const std = @import("std");

/// Where the system's rule is in force: its first line that is not a `#`
/// comment. The system clock keeps the local time this rule gives. The
/// boot copies it there from `kept_zone_file`, as every setting in ENV:,
/// so a rule written to ENV: alone holds until the machine starts again.
pub const zone_file = "ENV:Sys/timezone";
/// Where the rule is kept across a boot.
pub const kept_zone_file = "ENVARC:Sys/timezone";

/// The zone file's explanation, every line a comment, which a program
/// that writes the file puts before the rule.
pub const header =
    \\# ENVARC:Sys/timezone - the local time, as a POSIX TZ rule, which the boot
    \\# copies to ENV:Sys/timezone, where the system reads it: C:net/TimeSync
    \\# sets the clock by it, dates are written in it. The zone's name and its
    \\# offset west of UTC, then the summer zone and when it starts and ends.
    \\# The first line that is not a comment is the rule; without one the clock
    \\# keeps UTC. Prefs' Region page writes the line.
    \\#
    \\#   CET-1CEST,M3.5.0,M10.5.0/3     Central Europe (Berlin, Paris, Rome)
    \\#   GMT0BST,M3.5.0/1,M10.5.0       United Kingdom
    \\#   EST5EDT,M3.2.0,M11.1.0         US Eastern
    \\#   PST8PDT,M3.2.0,M11.1.0         US Pacific
    \\#   JST-9                          Japan
    \\#   UTC0                           UTC
    \\
;

/// A zone by the places that keep it, for a program to offer them by
/// name: what it is called, and its rule.
pub const Place = struct { name: [*:0]const u8, rule: [:0]const u8 };

/// The zones offered by name, west of UTC last. Each rule's offsets and
/// changes are whole quarter hours, so `pack` keeps every one.
pub const places = [_]Place{
    .{ .name = "UTC", .rule = "UTC0" },
    .{ .name = "United Kingdom, Ireland (London, Dublin)", .rule = "GMT0BST,M3.5.0/1,M10.5.0" },
    .{ .name = "Western Europe (Lisbon)", .rule = "WET0WEST,M3.5.0/1,M10.5.0" },
    .{ .name = "Central Europe (Berlin, Paris, Rome, Madrid)", .rule = "CET-1CEST,M3.5.0,M10.5.0/3" },
    .{ .name = "Eastern Europe (Athens, Helsinki, Kyiv)", .rule = "EET-2EEST,M3.5.0/3,M10.5.0/4" },
    .{ .name = "Turkey (Istanbul)", .rule = "<+03>-3" },
    .{ .name = "Moscow", .rule = "MSK-3" },
    .{ .name = "Gulf (Dubai)", .rule = "<+04>-4" },
    .{ .name = "India (Delhi, Mumbai)", .rule = "IST-5:30" },
    .{ .name = "China (Beijing, Shanghai)", .rule = "CST-8" },
    .{ .name = "Australia West (Perth)", .rule = "AWST-8" },
    .{ .name = "Japan (Tokyo)", .rule = "JST-9" },
    .{ .name = "Korea (Seoul)", .rule = "KST-9" },
    .{ .name = "Australia South (Adelaide)", .rule = "ACST-9:30ACDT,M10.1.0,M4.1.0/3" },
    .{ .name = "Australia North (Darwin)", .rule = "ACST-9:30" },
    .{ .name = "Australia East (Sydney, Melbourne)", .rule = "AEST-10AEDT,M10.1.0,M4.1.0/3" },
    .{ .name = "Australia Queensland (Brisbane)", .rule = "AEST-10" },
    .{ .name = "New Zealand (Auckland)", .rule = "NZST-12NZDT,M9.5.0,M4.1.0/3" },
    .{ .name = "Brazil (Sao Paulo)", .rule = "<-03>3" },
    .{ .name = "Canada Newfoundland (St. John's)", .rule = "NST3:30NDT,M3.2.0,M11.1.0" },
    .{ .name = "Canada Atlantic (Halifax)", .rule = "AST4ADT,M3.2.0,M11.1.0" },
    .{ .name = "US, Canada Eastern (New York, Toronto)", .rule = "EST5EDT,M3.2.0,M11.1.0" },
    .{ .name = "US, Canada Central (Chicago, Winnipeg)", .rule = "CST6CDT,M3.2.0,M11.1.0" },
    .{ .name = "US, Canada Mountain (Denver, Calgary)", .rule = "MST7MDT,M3.2.0,M11.1.0" },
    .{ .name = "US Arizona (Phoenix)", .rule = "MST7" },
    .{ .name = "US, Canada Pacific (Los Angeles, Vancouver)", .rule = "PST8PDT,M3.2.0,M11.1.0" },
    .{ .name = "Alaska (Anchorage)", .rule = "AKST9AKDT,M3.2.0,M11.1.0" },
    .{ .name = "Hawaii (Honolulu)", .rule = "HST10" },
};

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

// --- in 64 bits ----------------------------------------------------------------

/// A zone in 64 bits, as battmem.resource keeps it (BATTMEM_ZONE): its
/// offsets and its times of change in quarter hours, so a rule with one
/// that is not a whole quarter hour is not kept, and null is answered.
/// UTC is 0.
///
///   bits 0-7    the standard offset east of UTC, signed
///   bit  8      whether there is summer time
///   bits 9-16   the summer offset, signed
///   bits 17-39  the change to summer time
///   bits 40-62  the change back
///
/// A change is its kind (bits 0-1: 0 `Mm.w.d`, 1 `Jn`, 2 `n`), its date
/// (bits 2-11: the month, the week << 4 and the weekday << 7, or the day)
/// and its time (bits 12-22, signed). Without summer time, only the
/// standard offset is kept.
pub fn pack(zone: *const Zone) ?u64 {
    var bits = quarters(zone.standard, i8) orelse return null;
    if (!zone.has_summer) return bits;
    bits |= 1 << 8;
    bits |= (quarters(zone.summer, i8) orelse return null) << 9;
    bits |= (packChange(zone.start) orelse return null) << 17;
    bits |= (packChange(zone.end) orelse return null) << 40;
    return bits;
}

/// The zone `pack` kept in `bits`, as `parse` gives it from its rule;
/// null when they hold none.
pub fn unpack(bits: u64) ?Zone {
    if (bits >> 63 != 0) return null;
    var zone: Zone = .{ .standard = secondsIn(bits, i8) };
    zone.summer = zone.standard + 3600;
    if (bits & 1 << 8 == 0) return if (bits >> 9 == 0) zone else null;
    zone.has_summer = true;
    zone.summer = secondsIn(bits >> 9, i8);
    zone.start = unpackChange(bits >> 17) orelse return null;
    zone.end = unpackChange(bits >> 40) orelse return null;
    return zone;
}

/// `whole` seconds as a count of quarter hours in a `T`, its bits; null
/// when they are not whole quarter hours or do not fit.
fn quarters(whole: i32, comptime T: type) ?u64 {
    if (@rem(whole, 900) != 0) return null;
    const count = @divExact(whole, 900);
    if (count < std.math.minInt(T) or count > std.math.maxInt(T)) return null;
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
    return @as(Bits, @bitCast(@as(T, @intCast(count))));
}

/// The quarter hours in the low bits of `bits`, as a `T`, in seconds.
fn secondsIn(bits: u64, comptime T: type) i32 {
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
    const count: T = @bitCast(@as(Bits, @truncate(bits)));
    return @as(i32, count) * 900;
}

fn packChange(change: Change) ?u64 {
    const date: u64 = switch (change.kind) {
        .month_week_day => change.month | @as(u64, change.week) << 4 | @as(u64, change.weekday) << 7,
        .julian_no_leap, .julian => change.day,
    };
    return @intFromEnum(change.kind) | date << 2 | (quarters(change.seconds, i11) orelse return null) << 12;
}

fn unpackChange(bits: u64) ?Change {
    const date: u16 = @truncate(bits >> 2 & 0x3FF);
    var change: Change = .{ .seconds = secondsIn(bits >> 12, i11) };
    switch (bits & 3) {
        0 => {
            change.month = @truncate(date & 0xF);
            change.week = @truncate(date >> 4 & 7);
            change.weekday = @truncate(date >> 7);
            if (change.month == 0 or change.month > 12 or change.week == 0 or change.week > 5 or change.weekday > 6) return null;
        },
        1 => {
            change.kind = .julian_no_leap;
            change.day = date;
            if (change.day == 0 or change.day > 365) return null;
        },
        2 => {
            change.kind = .julian;
            change.day = date;
            if (change.day > 365) return null;
        },
        else => return null,
    }
    return change;
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

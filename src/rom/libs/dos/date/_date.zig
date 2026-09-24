// SPDX-License-Identifier: MPL-2.0
//! The date calls: DateStamp, CompareDates, DateToStr, StrToDate and Delay,
//! and what they share.
//!
//! A DateStamp is days since 1 Jan 1978, minutes past midnight and ticks
//! of 1/50 s past the minute. The time comes from timer.device, which dos
//! opens once at its init and keeps: one request in the base, whose reply
//! port ignores replies because only GetSysTime is called on it and that
//! never replies. Delay copies the request rather than share it, so any
//! number of processes can wait at once. Without timer.device (the host
//! tests) the time is all zero and Delay returns at once.
//!
//! The rest of the file turns a day number into a calendar date and back,
//! and a date into text and back, for DateToStr and StrToDate. The
//! calendar itself is utility.library's: `Amiga2Date` and `CheckDate`
//! keep it, and `split` and `join` are the two lines that put a day
//! number on either side of those calls.

const sdk = @import("sdk");
const DosBase = @import("../dos_base.zig").DosBase;
const dos = sdk.dos;
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ClockData = sdk.utility.ClockData;

/// Opens timer.device into the base for good: the request and the device's
/// base, for GetSysTime. Both stay null when there is no timer.device.
///
/// INPUTS:
/// - `db` - dos.library's base, whose timer fields are set.
pub fn openTimer(db: *DosBase) void {
    db.timer_io = null;
    db.timer_base = null;
    db.timer_port = .{ .flags = exec.PA_IGNORE };
    db.timer_port.msg_list.init(.message);
    const io = db.sys_base.CreateIORequest(&db.timer_port, @sizeOf(timer.TimeRequest)) orelse return;
    if (db.sys_base.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, io, 0) != 0) {
        db.sys_base.DeleteIORequest(io);
        return;
    }
    db.timer_io = io;
    db.timer_base = @ptrCast(io.device.?);
}

/// Seconds and microseconds since 1 Jan 1978 as a DateStamp.
///
/// INPUTS:
/// - `secs` - whole seconds since 1 Jan 1978.
/// - `micro` - microseconds into the second.
pub fn fromSysTime(secs: u32, micro: u32) dos.DateStamp {
    return .{
        .days = @intCast(secs / 86400),
        .minute = @intCast(secs % 86400 / 60),
        .tick = @intCast(secs % 60 * 50 + micro / 20000),
    };
}

// --- dates as strings -----------------------------------------------------
//
// The year is written with all four digits, so a date string goes on
// naming one date whatever the century. A year typed with two digits is
// read as 1978-1999 for 78-99 and 2000-2077 below that, which is the only
// reading that keeps such a string meaning what it did when it was
// written. "Today" is DateStamp(): the one clock dos keeps.

/// The weekday names, Sunday first: 1 Jan 1978 was a Sunday, so a day
/// number modulo 7 indexes this.
pub const week_days = [_][:0]const u8{
    "Sunday",   "Monday", "Tuesday",  "Wednesday",
    "Thursday", "Friday", "Saturday",
};
/// The names for a day relative to today: today, yesterday, tomorrow.
pub const rel_days = [_][:0]const u8{ "Today", "Yesterday", "Tomorrow" };

/// The months' three-letter names, January first.
pub const months = [_][:0]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};
/// The last year `join` takes: four digits are what DateToStr writes,
/// and the day count stays far inside an i32.
const last_year: u32 = 9999;

/// A date as the calendar has it, with the month counted from 0.
pub const Civil = struct { year: u32, month: u32, day: u32 };

/// A day number as its year, month (0-11) and day of the month (1-31).
///
/// INPUTS:
/// - `db` - the library's base, for utility.library's calendar.
/// - `days` - days since 1 Jan 1978.
pub fn split(db: *DosBase, days: u32) Civil {
    var clock: ClockData = .{};
    db.utility_base.DateSplit(days, &clock);
    return .{ .year = clock.year, .month = clock.month - 1, .day = clock.mday };
}

/// The day number a date comes to; null when it is no date (before 1978,
/// after 9999 - the most a date string writes back - a month past 11, a
/// day the month doesn't have).
///
/// INPUTS:
/// - `db` - the library's base, for utility.library's calendar.
/// - `year` - the year, with its century.
/// - `month` - the month, 0-11.
/// - `day` - the day of the month, from 1.
pub fn join(db: *DosBase, year: u32, month: u32, day: u32) ?i32 {
    if (year < 1978 or year > last_year or month > 11) return null;
    if (day == 0 or day > 31) return null;
    const days = db.utility_base.DateJoin(&.{
        .year = @intCast(year),
        .month = @intCast(month + 1),
        .mday = @intCast(day),
    });
    return if (days < 0) null else days;
}

/// The last two decimal digits of `value` into `into`.
///
/// INPUTS:
/// - `into` - two bytes at least.
/// - `value` - the number; only its last two digits are written.
pub fn two(into: []u8, value: u32) void {
    into[0] = '0' + @as(u8, @intCast(value / 10 % 10));
    into[1] = '0' + @as(u8, @intCast(value % 10));
}

/// The last four decimal digits of `value` into `into`, for a year.
///
/// INPUTS:
/// - `into` - four bytes at least.
/// - `value` - the number; only its last four digits are written.
pub fn four(into: []u8, value: u32) void {
    two(into[0..2], value / 100);
    two(into[2..4], value);
}

/// `text` into a DateTime string buffer: cut to LEN_DATSTRING - 1 bytes
/// and ended with a NUL.
///
/// INPUTS:
/// - `into` - a buffer of LEN_DATSTRING bytes.
/// - `text` - the string to copy.
pub fn put(into: [*:0]u8, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len and i + 1 < dos.LEN_DATSTRING) : (i += 1) into[i] = text[i];
    into[i] = 0;
}

/// One component read from a date or time string: its value, and where
/// the string goes on after it.
const Component = struct { value: u32, next: usize };

/// The decimal number at `at`, up to `sep` or the end of the string; null
/// when there is no digit or anything else is in the way, or it has more
/// than nine digits.
///
/// INPUTS:
/// - `text` - the string.
/// - `at` - where the number starts.
/// - `sep` - the byte that ends it.
pub fn getNumber(text: [*:0]const u8, at: usize, sep: u8) ?Component {
    var i = at;
    var value: u32 = 0;
    var digits: u32 = 0;
    while (text[i] != 0 and text[i] != sep) : (i += 1) {
        if (text[i] < '0' or text[i] > '9') return null;
        value = value * 10 + (text[i] - '0');
        digits += 1;
        if (digits > 9) return null;
    }
    if (digits == 0) return null;
    return .{ .value = value, .next = i };
}

/// A month at `at`: a name whose first three letters are a month's (the
/// rest of the word up to `sep` is taken with it, so "September" reads as
/// well as "Sep"), else a number. Its value is 1-12 for a name.
///
/// INPUTS:
/// - `text` - the string.
/// - `at` - where the month starts.
/// - `sep` - the byte that ends it.
pub fn getMonth(text: [*:0]const u8, at: usize, sep: u8) ?Component {
    for (months, 0..) |name, i| {
        if (!sameFold(text, at, name)) continue;
        // The rest of the word goes with it: "September" as well as "Sep".
        var j = at;
        while (text[j] != 0 and text[j] != sep) j += 1;
        return .{ .value = @intCast(i + 1), .next = j };
    }
    return getNumber(text, at, sep);
}

/// Whether the string at `at` begins with `with`, ASCII case ignored.
///
/// INPUTS:
/// - `text` - the string.
/// - `at` - where to compare from.
/// - `with` - the word, in any case.
fn sameFold(text: [*:0]const u8, at: usize, with: []const u8) bool {
    for (with, 0..) |c, i| {
        const got = text[at + i];
        if (got == 0) return false;
        if (fold(got) != fold(c)) return false;
    }
    return true;
}

/// Whether the whole of `text` is `with`, ASCII case ignored.
///
/// INPUTS:
/// - `text` - the string.
/// - `with` - the word.
pub fn sameWord(text: [*:0]const u8, with: []const u8) bool {
    if (!sameFold(text, 0, with)) return false;
    return text[with.len] == 0;
}

/// `c` in lower case, for ASCII letters.
///
/// INPUTS:
/// - `c` - the byte.
fn fold(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// The year a date string means: more than two digits stand for
/// themselves; two digits are 1978-1999 for 78-99 and the 2000s below.
///
/// INPUTS:
/// - `value` - the number as read.
/// - `digits_written` - how many digits it was written with.
pub fn fullYear(value: u32, digits_written: usize) u32 {
    if (digits_written > 2) return value;
    return if (value >= 78) 1900 + value else 2000 + value;
}

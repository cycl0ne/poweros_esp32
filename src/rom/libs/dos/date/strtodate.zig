// SPDX-License-Identifier: MPL-2.0
//! StrToDate: a date and time read from text.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _date = @import("_date.zig");
const fullYear = _date.fullYear;
const join = _date.join;
const getNumber = _date.getNumber;
const getMonth = _date.getMonth;
const week_days = _date.week_days;
const rel_days = _date.rel_days;
const sameWord = _date.sameWord;

/// Reads a date and a time from text into a DateStamp.
///
/// SYNOPSIS:
/// ```zig
/// fn StrToDate(db: *DosBase, datetime: *dos.DateTime) bool
/// ```
///
/// SINCE: 1.0. LVO -188.
///
/// INPUTS:
/// - `datetime` - dat_StrDate and dat_StrTime the text to read (a null
///   one leaves its part of dat_Stamp as it is), dat_Format the order of
///   a date's parts, dat_Flags DTF_FUTURE; dat_Stamp gets the result.
///
/// RESULT:
/// True with dat_Stamp set; false when a string is no date or time. The
/// parts read before the failing one may already be set.
///
/// BEHAVIOR:
/// dat_StrDate is "Today", "Yesterday", "Tomorrow" or a weekday's name,
/// case ignored, or a date with its parts in dat_Format's order, separated
/// by '-': the month as a number or as a name (its first three letters
/// count). A two-digit year is 1978-1999 for 78-99 and 2000-2077 below
/// that; more digits stand for themselves. A weekday is the one just gone,
/// or with DTF_FUTURE the one coming; today's own name is a week away
/// either way. dat_StrTime is "hh:mm" or "hh:mm:ss". The date sets
/// ds_Days, the time ds_Minute and ds_Tick.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The strings stay the caller's.
///
/// BUGS:
/// The calendar is right only up to the end of February 2100.
///
/// SEE ALSO:
/// `DateToStr`, `DateStamp`
///
/// EXAMPLES:
/// ```zig
/// var dt: dos.DateTime = .{ .format = dos.FORMAT_DOS, .str_date = @constCast("21-Sep-2026"), .str_time = @constCast("12:30") };
/// if (!dos_lib.StrToDate(&dt)) return false;
/// ```
pub fn StrToDate(db: *DosBase, datetime: *dos.DateTime) bool {
    const dos_lib = db.iface();
    if (datetime.str_date) |text| {
        var today: dos.DateStamp = .{};
        _ = dos_lib.DateStamp(&today);
        var done = false;

        // "Today", "Yesterday", "Tomorrow" and the weekday names, read
        // relative to today.
        if (sameWord(text, rel_days[0])) {
            datetime.stamp.days = today.days;
            done = true;
        } else if (sameWord(text, rel_days[1])) {
            datetime.stamp.days = today.days - 1;
            done = true;
        } else if (sameWord(text, rel_days[2])) {
            datetime.stamp.days = today.days + 1;
            done = true;
        } else for (week_days, 0..) |name, i| {
            if (!sameWord(text, name)) continue;
            const want: i32 = @intCast(i);
            const now: i32 = @mod(today.days, 7);
            var delta = want - now;
            // Without DTF_FUTURE a weekday is the one just gone, with it
            // the one coming; today's own name is a week away either way.
            if (datetime.flags & dos.DTF_FUTURE != 0) {
                if (delta <= 0) delta += 7;
            } else {
                if (delta >= 0) delta -= 7;
            }
            datetime.stamp.days = today.days + delta;
            done = true;
            break;
        }

        if (!done) {
            // The components in the order dat_Format puts them, then the
            // day number they come to.
            const format = if (datetime.format > dos.FORMAT_MAX) dos.FORMAT_DOS else datetime.format;
            var year: u32 = 0;
            var year_digits: usize = 0;
            var month: u32 = 0;
            var day: u32 = 0;
            const order: [3]u8 = switch (format) {
                dos.FORMAT_INT => .{ 'y', 'm', 'd' },
                dos.FORMAT_USA => .{ 'm', 'd', 'y' },
                else => .{ 'd', 'm', 'y' }, // FORMAT_DOS and FORMAT_CDN
            };
            var at: usize = 0;
            for (order) |what| {
                const got = (if (what == 'm')
                    getMonth(text, at, '-')
                else
                    getNumber(text, at, '-')) orelse return false;
                switch (what) {
                    'y' => {
                        year = got.value;
                        year_digits = got.next - at;
                    },
                    'm' => month = got.value,
                    else => day = got.value,
                }
                at = got.next;
                if (text[at] == '-') at += 1;
            }
            if (text[at] != 0) return false;
            if (month == 0) return false;
            const days = join(db, fullYear(year, year_digits), month - 1, day) orelse return false;
            datetime.stamp.days = days;
        }
    }

    if (datetime.str_time) |text| {
        // hh:mm:ss, or hh:mm alone.
        var at: usize = 0;
        const hour = getNumber(text, at, ':') orelse return false;
        at = hour.next;
        if (text[at] != ':') return false;
        at += 1;
        const minute = getNumber(text, at, ':') orelse return false;
        at = minute.next;
        var second: u32 = 0;
        if (text[at] == ':') {
            at += 1;
            const got = getNumber(text, at, ':') orelse return false;
            second = got.value;
            at = got.next;
        }
        if (text[at] != 0) return false;
        if (hour.value > 23 or minute.value > 59 or second > 59) return false;
        datetime.stamp.minute = @intCast(hour.value * 60 + minute.value);
        datetime.stamp.tick = @intCast(second * 50);
    }
    return true;
}

// SPDX-License-Identifier: MPL-2.0
//! DateToStr: a DateStamp written out as text.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _date = @import("_date.zig");
const months = _date.months;
const two = _date.two;
const four = _date.four;
const split = _date.split;
const week_days = _date.week_days;
/// What DateToStr writes, with DTF_SUBST, for a date past tomorrow.
const future = "Future";
const rel_days = _date.rel_days;
const put = _date.put;

/// Writes a DateStamp out as text.
///
/// SYNOPSIS:
/// ```zig
/// fn DateToStr(db: *DosBase, datetime: *dos.DateTime) bool
/// ```
///
/// SINCE: 1.0. LVO -184.
///
/// INPUTS:
/// - `datetime` - dat_Stamp the date to write, dat_Format and dat_Flags
///   how, and the three string buffers (dat_StrDay, dat_StrDate,
///   dat_StrTime) it is written to. A null buffer is skipped; each other
///   one holds LEN_DATSTRING bytes.
///
/// RESULT:
/// True with the strings written; false, and nothing written, when the
/// stamp is no date (a negative field, a minute past the day, a tick past
/// the minute).
///
/// BEHAVIOR:
/// dat_StrDay gets the weekday's name. dat_StrTime gets "hh:mm:ss".
/// dat_StrDate gets the date in dat_Format (an unknown one is FORMAT_DOS):
/// "dd-Mmm-yyyy", "yyyy-mm-dd", "mm-dd-yyyy" or "dd-mm-yyyy". With
/// FORMAT_DOS and DTF_SUBST a date near today is a word instead: "Today",
/// "Yesterday", "Tomorrow", "Future" for anything later, and the weekday's
/// name for the week before yesterday.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The buffers are the caller's.
///
/// NOTES:
/// Without timer.device today is day 0, so DTF_SUBST calls every date
/// from 1978 on "Future".
///
/// BUGS:
/// A year past 9999 is written with only its last four digits.
///
/// SEE ALSO:
/// `StrToDate`, `DateStamp`
///
/// EXAMPLES:
/// ```zig
/// var date: [dos.LEN_DATSTRING]u8 = undefined;
/// var dt: dos.DateTime = .{ .stamp = fib.date, .format = dos.FORMAT_INT, .str_date = @ptrCast(&date) };
/// if (dos_lib.DateToStr(&dt)) {
///     // date holds "2026-09-21"
/// }
/// ```
pub fn DateToStr(db: *DosBase, datetime: *dos.DateTime) bool {
    const dos_lib = db.iface();
    const stamp = datetime.stamp;
    if (stamp.days < 0 or stamp.minute < 0 or stamp.tick < 0) return false;
    if (stamp.minute >= 24 * 60 or stamp.tick >= 50 * 60) return false;
    const days: u32 = @intCast(stamp.days);
    const format = if (datetime.format > dos.FORMAT_MAX) dos.FORMAT_DOS else datetime.format;

    if (datetime.str_date) |into| {
        // With FORMAT_DOS and DTF_SUBST a date close to today is a word,
        // not a date: the week just gone, and anything ahead.
        var wrote = false;
        if (format == dos.FORMAT_DOS and datetime.flags & dos.DTF_SUBST != 0) {
            var today: dos.DateStamp = .{};
            _ = dos_lib.DateStamp(&today);
            const delta = stamp.days - today.days;
            wrote = true;
            if (delta == 0) {
                put(into, rel_days[0]);
            } else if (delta == 1) {
                put(into, rel_days[2]);
            } else if (delta > 1) {
                put(into, future);
            } else if (delta == -1) {
                put(into, rel_days[1]);
            } else if (delta >= -7) {
                put(into, week_days[days % 7]);
            } else {
                wrote = false;
            }
        }
        if (!wrote) {
            const ymd = split(db, days);
            var text: [12]u8 = undefined;
            switch (format) {
                dos.FORMAT_INT => {
                    four(text[0..4], ymd.year);
                    two(text[5..7], ymd.month + 1);
                    two(text[8..10], ymd.day);
                    text[4] = '-';
                    text[7] = '-';
                    put(into, text[0..10]);
                },
                dos.FORMAT_USA => {
                    two(text[0..2], ymd.month + 1);
                    two(text[3..5], ymd.day);
                    four(text[6..10], ymd.year);
                    text[2] = '-';
                    text[5] = '-';
                    put(into, text[0..10]);
                },
                dos.FORMAT_CDN => {
                    two(text[0..2], ymd.day);
                    two(text[3..5], ymd.month + 1);
                    four(text[6..10], ymd.year);
                    text[2] = '-';
                    text[5] = '-';
                    put(into, text[0..10]);
                },
                // FORMAT_DOS: dd-mmm-yyyy, the month in letters.
                else => {
                    two(text[0..2], ymd.day);
                    const name = months[ymd.month];
                    text[3] = name[0];
                    text[4] = name[1];
                    text[5] = name[2];
                    four(text[7..11], ymd.year);
                    text[2] = '-';
                    text[6] = '-';
                    put(into, text[0..11]);
                },
            }
        }
    }

    if (datetime.str_time) |into| {
        var text: [8]u8 = undefined;
        const minute: u32 = @intCast(stamp.minute);
        two(text[0..2], minute / 60);
        two(text[3..5], minute % 60);
        two(text[6..8], @as(u32, @intCast(stamp.tick)) / 50);
        text[2] = ':';
        text[5] = ':';
        put(into, &text);
    }

    if (datetime.str_day) |into| put(into, week_days[days % 7]);
    return true;
}

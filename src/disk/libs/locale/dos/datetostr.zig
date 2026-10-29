// SPDX-License-Identifier: MIT
//! dos's DateToStr, in the default locale: the same strings in the
//! locale's words, and FORMAT_DEF in its own short date and time.
//!
//! The date is written by FormatDate: dd-Mmm-yyyy, yyyy-mm-dd, mm-dd-yyyy
//! or dd-mm-yyyy by dat_Format, the month's short name the language's;
//! FORMAT_DEF in the locale's short_date_format. With DTF_SUBST and
//! FORMAT_DOS or FORMAT_DEF a date near today is the language's word for
//! it, as dos picks it: today, yesterday, tomorrow, the future, and the
//! weekday for the week before yesterday. The time is hh:mm:ss, with
//! FORMAT_DEF the locale's short_time_format; the day is the weekday's
//! name. Each string is cut to LEN_DATSTRING bytes with its NUL.

const sdk = @import("sdk");
const dos = sdk.dos;
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const _dos = @import("_dos.zig");
const LocaleBase = _base.LocaleBase;
const DosBase = sdk.interface.dos.DosBase;

/// What stands in dos's jump table: the library found, the call made.
pub fn dosDateToStr(_: *DosBase, datetime: *dos.DateTime) callconv(.c) bool {
    const lb = _dos.enter() orelse return false;
    defer _dos.leave(lb);
    return dateToStr(lb, datetime);
}

/// The date template of `format`; FORMAT_DOS's for one dos does not know.
pub fn dateTemplate(loc: *const locale.Locale, format: u8) [*:0]const u8 {
    return switch (format) {
        dos.FORMAT_INT => "%Y-%m-%d",
        dos.FORMAT_USA => "%m-%d-%Y",
        dos.FORMAT_CDN => "%d-%m-%Y",
        dos.FORMAT_DEF => loc.short_date_format,
        else => "%d-%b-%Y",
    };
}

/// The time template of `format`.
pub fn timeTemplate(loc: *const locale.Locale, format: u8) [*:0]const u8 {
    return if (format == dos.FORMAT_DEF) loc.short_time_format else "%H:%M:%S";
}

/// DateToStr in the default locale: false, and nothing written, when the
/// stamp is no date.
pub fn dateToStr(lb: *LocaleBase, datetime: *dos.DateTime) bool {
    const library = lb.iface();
    const stamp = datetime.stamp;
    if (stamp.days < 0 or stamp.minute < 0 or stamp.tick < 0) return false;
    if (stamp.minute >= 24 * 60 or stamp.tick >= 50 * 60) return false;
    const loc = library.OpenLocale(null) orelse return false;
    defer library.CloseLocale(loc);
    const format = datetime.format;

    if (datetime.str_date) |into| {
        // Words for FORMAT_DOS and FORMAT_DEF, and for a format dos does
        // not know, which is FORMAT_DOS.
        const numbers_only = switch (format) {
            dos.FORMAT_INT, dos.FORMAT_USA, dos.FORMAT_CDN => true,
            else => false,
        };
        const subst = datetime.flags & dos.DTF_SUBST != 0 and !numbers_only;
        const word = if (subst) nearWord(lb, stamp.days) else null;
        if (word) |string_num| {
            put(into, library.GetLocaleStr(loc, string_num) orelse "");
        } else {
            write(lb, loc, into, dateTemplate(loc, format), &stamp);
        }
    }
    if (datetime.str_time) |into| write(lb, loc, into, timeTemplate(loc, format), &stamp);
    if (datetime.str_day) |into| write(lb, loc, into, "%A", &stamp);
    return true;
}

/// The word for a day near today, by its number: the week just gone, and
/// anything ahead; null for a day further back.
fn nearWord(lb: *LocaleBase, days: i32) ?u32 {
    var today: dos.DateStamp = .{};
    _ = lb.dos_base.DateStamp(&today);
    const delta = days - today.days;
    if (delta == 0) return locale.TODAYSTR;
    if (delta == 1) return locale.TOMORROWSTR;
    if (delta > 1) return locale.FUTURESTR;
    if (delta == -1) return locale.YESTERDAYSTR;
    // Day 0, 1 January 1978, was a Sunday.
    if (delta >= -7) return locale.DAY_1 + @as(u32, @intCast(@mod(days, 7)));
    return null;
}

/// `stamp` written by `template` into a LEN_DATSTRING buffer.
fn write(lb: *LocaleBase, loc: *const locale.Locale, into: [*:0]u8, template: [*:0]const u8, stamp: *const dos.DateStamp) void {
    var out = locale.BufferHook.init(into[0..dos.LEN_DATSTRING]);
    lb.iface().FormatDate(loc, template, stamp, &out.hook);
}

/// A word into a LEN_DATSTRING buffer, cut to it.
fn put(into: [*:0]u8, text: [*:0]const u8) void {
    var at: usize = 0;
    while (text[at] != 0 and at < dos.LEN_DATSTRING - 1) : (at += 1) into[at] = text[at];
    into[at] = 0;
}

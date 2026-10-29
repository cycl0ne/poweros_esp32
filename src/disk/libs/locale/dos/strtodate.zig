// SPDX-License-Identifier: MIT
//! dos's StrToDate, in the default locale: the language's words and the
//! locale's formats first, then dos's own.
//!
//! dat_StrDate is the language's word for today, yesterday or tomorrow,
//! or a weekday's name, long or short, read as dos reads them (the one
//! just gone, with DTF_FUTURE the one coming); or a date by ParseDate, in
//! dat_Format's order with the month's name the language's or its number
//! and the year in four digits or two, FORMAT_DEF in the locale's
//! short_date_format. dat_StrTime is hh:mm:ss or hh:mm, with FORMAT_DEF
//! the locale's short_time_format first.
//!
//! What the locale does not read goes to dos's own StrToDate, whole, so a
//! script's "Today" and "29-Oct-2026" mean what they meant whatever the
//! language. Nothing is changed until both strings are read.

const sdk = @import("sdk");
const dos = sdk.dos;
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const _chars = @import("../chars/_chars.zig");
const _dos = @import("_dos.zig");
const _datetostr = @import("datetostr.zig");
const LocaleBase = _base.LocaleBase;
const DosBase = sdk.interface.dos.DosBase;
const DosFn = sdk.interface.dos.Fn;

/// What stands in dos's jump table: the library found, the call made.
pub fn dosStrToDate(db: *DosBase, datetime: *dos.DateTime) callconv(.c) bool {
    const lb = _dos.enter() orelse return false;
    defer _dos.leave(lb);
    if (strToDate(lb, datetime)) return true;
    const own = _dos.original(lb, DosFn.StrToDate, "dos_str_to_date");
    return own(db, datetime);
}

/// StrToDate in the default locale; false, and nothing changed, when it
/// does not read the strings.
pub fn strToDate(lb: *LocaleBase, datetime: *dos.DateTime) bool {
    const library = lb.iface();
    const loc = library.OpenLocale(null) orelse return false;
    defer library.CloseLocale(loc);
    var stamp = datetime.stamp;

    if (datetime.str_time) |text| {
        const own = _datetostr.timeTemplate(loc, datetime.format);
        const read = for ([_][*:0]const u8{ own, "%H:%M:%S", "%H:%M" }) |template| {
            if (parse(lb, loc, text, template)) |time| break time;
        } else return false;
        stamp.minute = read.minute;
        stamp.tick = read.tick;
    }

    if (datetime.str_date) |text| {
        if (nearDay(lb, loc, text, datetime.flags)) |days| {
            stamp.days = days;
        } else {
            const four = _datetostr.dateTemplate(loc, datetime.format);
            const read = for ([_][*:0]const u8{ four, twoDigitYear(datetime.format) }) |template| {
                if (parse(lb, loc, text, template)) |date| break date;
            } else return false;
            stamp.days = read.days;
        }
    }
    datetime.stamp = stamp;
    return true;
}

/// dat_Format's date with a year of two digits; FORMAT_DEF has its own
/// template only.
fn twoDigitYear(format: u8) [*:0]const u8 {
    return switch (format) {
        dos.FORMAT_INT => "%y-%m-%d",
        dos.FORMAT_USA => "%m-%d-%y",
        dos.FORMAT_CDN => "%d-%m-%y",
        dos.FORMAT_DEF => "",
        else => "%d-%b-%y",
    };
}

fn parse(lb: *LocaleBase, loc: *const locale.Locale, text: [*:0]const u8, template: [*:0]const u8) ?dos.DateStamp {
    if (template[0] == 0) return null;
    var in = locale.StringHook.init(text);
    var date: dos.DateStamp = undefined;
    if (!lb.iface().ParseDate(loc, &date, template, &in.hook)) return null;
    return date;
}

/// The day a word names: today, yesterday, tomorrow, or a weekday's name,
/// counted from today; null for no such word.
fn nearDay(lb: *LocaleBase, loc: *const locale.Locale, text: [*:0]const u8, flags: u8) ?i32 {
    const library = lb.iface();
    var today: dos.DateStamp = .{};
    _ = lb.dos_base.DateStamp(&today);
    const relative = [_]struct { word: u32, delta: i32 }{
        .{ .word = locale.TODAYSTR, .delta = 0 },
        .{ .word = locale.YESTERDAYSTR, .delta = -1 },
        .{ .word = locale.TOMORROWSTR, .delta = 1 },
    };
    for (relative) |near| {
        if (same(text, library.GetLocaleStr(loc, near.word))) return today.days + near.delta;
    }
    var string_num = locale.DAY_1;
    while (string_num <= locale.ABDAY_7) : (string_num += 1) {
        if (!same(text, library.GetLocaleStr(loc, string_num))) continue;
        const want: i32 = @intCast((string_num - locale.DAY_1) % 7);
        var delta = want - @mod(today.days, 7);
        // The one just gone, or with DTF_FUTURE the one coming; today's
        // own name is a week away either way.
        if (flags & dos.DTF_FUTURE != 0) {
            if (delta <= 0) delta += 7;
        } else {
            if (delta >= 0) delta -= 7;
        }
        return today.days + delta;
    }
    return null;
}

/// Whether `text` is `word`, whatever the case of its letters; an empty
/// word is none.
fn same(text: [*:0]const u8, word: ?[*:0]const u8) bool {
    const with = word orelse return false;
    if (with[0] == 0) return false;
    var at: usize = 0;
    while (with[at] != 0) : (at += 1) {
        if (_chars.toLower(text[at]) != _chars.toLower(with[at])) return false;
    }
    return text[at] == 0;
}

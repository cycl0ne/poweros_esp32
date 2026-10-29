// SPDX-License-Identifier: MIT
//! FormatDate: a date written out by a template.

const sdk = @import("sdk");
const dos = sdk.dos;
const utility = sdk.utility;
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const _format = @import("_format.zig");
const LocaleBase = _base.LocaleBase;
const Out = _format.Out;
const Clock = _format.Clock;

/// Writes a date out by a template, in the locale's words.
///
/// SYNOPSIS:
/// ```zig
/// fn FormatDate(lb: *LocaleBase, loc: *const locale.Locale, template: [*:0]const u8, date: *const dos.DateStamp, put_char_func: *utility.Hook) void
/// ```
///
/// SINCE: 1.0. LVO -96.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale: its words for the days, the
///   months, before and after noon, and its time zone.
/// - `template` - the text to write, with a conversion after each `%`
///   (below); a locale's formats (`loc.date_format`, ...) are templates.
/// - `date` - the moment, in local time.
/// - `put_char_func` - called through utility's CallHookPkt with the
///   locale as the object and each byte as the message, then with 0.
///
/// RESULT:
/// None: the text went to the hook.
///
/// BEHAVIOR:
/// The conversions:
///
/// - `%a` `%A` - the weekday, short and long (ABDAY_*, DAY_*).
/// - `%b` `%h` `%B` - the month, short, short and long.
/// - `%d` `%e` - the day of the month, `01` to `31`, and ` 1` to `31`.
/// - `%m` `%y` `%Y` - the month `01` to `12`, the year's last two digits,
///   the year.
/// - `%H` `%q` - the hour of 24, `00` to `23` and `0` to `23`.
/// - `%I` `%Q` - the hour of 12, `01` to `12` and `1` to `12`; `%p` the
///   locale's AM_STR or PM_STR.
/// - `%M` `%S` - the minute and the second, `00` to `59`.
/// - `%j` - the day of the year, `001` to `366`; `%w` the weekday, `0`
///   (Sunday) to `6`; `%U` `%W` the week of the year, `00` to `53`, a week
///   from Sunday and from Monday, the days before the first such day in
///   week 0.
/// - `%Z` - the time zone's name then (`CET`, `CEST`), from the locale's
///   rule; nothing when it has none.
/// - `%D` `%x` - `%m/%d/%y`; `%T` `%X` - `%H:%M:%S`; `%R` - `%H:%M`;
///   `%r` - `%I:%M:%S %p`; `%c` - `%a %b %d %H:%M:%S %Y`; `%C` -
///   `%a %b %e %T %Z %Y`.
/// - `%n` `%t` - a line feed and a tab. Any other character after a `%`
///   is written as it is, so `%%` is one `%`.
///
/// CONTEXT:
/// - Waits: no, but the hook may.
/// - Interrupts: no; the hook is called through utility.library.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; what the hook does with the bytes is its own.
///
/// NOTES:
/// The forms `%x`, `%c` and the rest are fixed; a program that wants the
/// country's way passes the country's format - `loc.short_date_format`.
/// sdk.locale's `BufferHook` writes into a buffer.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParseDate`, `FormatString`, dos.library `DateToStr`
///
/// EXAMPLES:
/// ```zig
/// var text: [64]u8 = undefined;
/// var out = locale.BufferHook.init(&text);
/// var now: dos.DateStamp = undefined;
/// _ = dl.DateStamp(&now);
/// lb.FormatDate(loc, loc.date_format, &now, &out.hook);
/// ```
pub fn FormatDate(lb: *LocaleBase, loc: *const locale.Locale, template: [*:0]const u8, date: *const dos.DateStamp, put_char_func: *utility.Hook) void {
    const out = Out{ .lb = lb, .loc = loc, .hook = put_char_func };
    const clock = Clock.of(lb, date);
    write(lb, &out, template, &clock);
    out.put(0);
}

/// The template written for `clock`, without the 0 at the end.
fn write(lb: *LocaleBase, out: *const Out, template: [*:0]const u8, clock: *const Clock) void {
    const loc = out.loc;
    var at: usize = 0;
    while (template[at] != 0) {
        const c = template[at];
        at += 1;
        if (c != '%') {
            out.put(c);
            continue;
        }
        const conversion = template[at];
        if (conversion == 0) return;
        at += 1;
        var digits: [6]u8 = undefined;
        switch (conversion) {
            'a' => out.string(word(lb, loc, locale.ABDAY_1 + clock.wday)),
            'A' => out.string(word(lb, loc, locale.DAY_1 + clock.wday)),
            'b', 'h' => out.string(word(lb, loc, locale.ABMON_1 + clock.month - 1)),
            'B' => out.string(word(lb, loc, locale.MON_1 + clock.month - 1)),
            'c' => write(lb, out, "%a %b %d %H:%M:%S %Y", clock),
            'C' => write(lb, out, "%a %b %e %T %Z %Y", clock),
            'd' => out.text(_format.decimal(&digits, clock.mday, 2)),
            'e' => {
                if (clock.mday < 10) out.put(' ');
                out.text(_format.decimal(&digits, clock.mday, 1));
            },
            'D', 'x' => write(lb, out, "%m/%d/%y", clock),
            'H' => out.text(_format.decimal(&digits, clock.hour, 2)),
            'q' => out.text(_format.decimal(&digits, clock.hour, 1)),
            'I' => out.text(_format.decimal(&digits, twelve(clock.hour), 2)),
            'Q' => out.text(_format.decimal(&digits, twelve(clock.hour), 1)),
            'j' => out.text(_format.decimal(&digits, clock.yday + 1, 3)),
            'm' => out.text(_format.decimal(&digits, clock.month, 2)),
            'M' => out.text(_format.decimal(&digits, clock.min, 2)),
            'n' => out.put('\n'),
            'p' => out.string(word(lb, loc, if (clock.hour >= 12) locale.PM_STR else locale.AM_STR)),
            'r' => write(lb, out, "%I:%M:%S %p", clock),
            'R' => write(lb, out, "%H:%M", clock),
            'S' => out.text(_format.decimal(&digits, clock.sec, 2)),
            't' => out.put('\t'),
            'T', 'X' => write(lb, out, "%H:%M:%S", clock),
            'U' => out.text(_format.decimal(&digits, (clock.yday + 7 - clock.wday) / 7, 2)),
            'w' => out.text(_format.decimal(&digits, clock.wday, 1)),
            'W' => out.text(_format.decimal(&digits, (clock.yday + 7 - (clock.wday + 6) % 7) / 7, 2)),
            'y' => out.text(_format.decimal(&digits, clock.year % 100, 2)),
            'Y' => out.text(_format.decimal(&digits, clock.year, 4)),
            'Z' => out.text(_format.zoneName(loc.time_zone, clock.seconds)),
            else => out.put(conversion),
        }
    }
}

/// An hour of the day as one of twelve, 12 for noon and midnight.
fn twelve(hour: u32) u32 {
    const of_twelve = hour % 12;
    return if (of_twelve == 0) 12 else of_twelve;
}

/// A word of the locale's language, through the library's own call.
fn word(lb: *LocaleBase, loc: *const locale.Locale, string_num: u32) ?[*:0]const u8 {
    return lb.iface().GetLocaleStr(loc, string_num);
}

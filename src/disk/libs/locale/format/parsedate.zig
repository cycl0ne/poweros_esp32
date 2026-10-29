// SPDX-License-Identifier: MIT
//! ParseDate: a date read by a template.

const sdk = @import("sdk");
const dos = sdk.dos;
const utility = sdk.utility;
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const _chars = @import("../chars/_chars.zig");
const _format = @import("_format.zig");
const LocaleBase = _base.LocaleBase;

/// Reads a date by a template, in the locale's words.
///
/// SYNOPSIS:
/// ```zig
/// fn ParseDate(lb: *LocaleBase, loc: *const locale.Locale, date: *dos.DateStamp, template: [*:0]const u8, get_char_func: *utility.Hook) bool
/// ```
///
/// SINCE: 1.0. LVO -100.
///
/// INPUTS:
/// - `loc` - a locale, from OpenLocale: its words for the days, the
///   months, and before and after noon.
/// - `date` - where the moment goes.
/// - `template` - what the text holds, with a conversion after each `%`
///   (below); a locale's formats (`loc.short_date_format`, ...) are
///   templates.
/// - `get_char_func` - called through utility's CallHookPkt with the
///   locale as the object, for the text's next byte each time; 0 ends the
///   text.
///
/// RESULT:
/// True with `date` set when the whole text is a date by the template;
/// false, and `date` as it was, when it is not, names a day the month
/// does not have, or is longer than 127 bytes.
///
/// BEHAVIOR:
/// The conversions, each reading what FormatDate writes for it:
///
/// - `%a` `%A` - a weekday's name, long or short; it is read and not
///   used.
/// - `%b` `%B` `%h` `%m` - a month, by its name, long or short, or its
///   number.
/// - `%d` `%e` - the day of the month, 1 to 31.
/// - `%H` `%I` `%q` `%Q` - the hour, 0 to 23; `%p` after it the locale's
///   AM_STR or PM_STR, which makes it an hour of twelve.
/// - `%M` `%S` - the minute and the second, 0 to 59.
/// - `%y` - the year's last two digits, 78 to 99 for 1978 to 1999 and
///   below 78 for 2000 to 2077; `%Y` the year, 1978 to 9999.
/// - `%D` `%x`, `%T` `%X`, `%R`, `%r`, `%c` - their forms in FormatDate.
/// - `%Z` - a time zone's name, read and not used.
/// - `%n` `%t` and a blank - any blanks, or none; `%%` a `%`.
///
/// Any other character must be in the text where the template has it.
/// Names and letters are matched whatever their case, the longest name
/// that fits first; a number may have blanks before it. What the template
/// leaves out is 1 January 1978, 00:00:00: a template of a time alone
/// reads a moment on that day.
///
/// CONTEXT:
/// - Waits: no, but the hook may.
/// - Interrupts: no; the hook is called through utility.library.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// sdk.locale's `StringHook` reads a string. Any other conversion in the
/// template makes the text no date.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FormatDate`, dos.library `StrToDate`
///
/// EXAMPLES:
/// ```zig
/// var in = locale.StringHook.init("29.10.2026");
/// var date: dos.DateStamp = undefined;
/// if (!lb.ParseDate(loc, &date, loc.short_date_format, &in.hook)) return error.NoDate;
/// ```
pub fn ParseDate(lb: *LocaleBase, loc: *const locale.Locale, date: *dos.DateStamp, template: [*:0]const u8, get_char_func: *utility.Hook) bool {
    var input: [128]u8 = undefined;
    var count: usize = 0;
    while (true) {
        const byte: u8 = @truncate(lb.utility_base.CallHookPkt(get_char_func, @constCast(loc), null));
        if (byte == 0) break;
        if (count == input.len - 1) return false;
        input[count] = byte;
        count += 1;
    }
    var reading = Reading{ .lb = lb, .loc = loc, .text = input[0..count] };
    if (!reading.match(template)) return false;
    reading.skipBlanks();
    if (reading.at != count) return false;
    const days = lb.utility_base.DateJoin(&.{
        .year = @intCast(reading.year),
        .month = @intCast(reading.month),
        .mday = @intCast(reading.mday),
    });
    if (days < 0) return false;
    date.* = .{
        .days = days,
        .minute = @intCast(reading.hour * 60 + reading.min),
        .tick = @intCast(reading.sec * _format.ticks_per_second),
    };
    return true;
}

/// The text being read, where it has got to, and the fields read so far.
const Reading = struct {
    lb: *LocaleBase,
    loc: *const locale.Locale,
    text: []const u8,
    at: usize = 0,
    year: u32 = 1978,
    month: u32 = 1,
    mday: u32 = 1,
    hour: u32 = 0,
    min: u32 = 0,
    sec: u32 = 0,

    /// The text from `at` read by `template`.
    fn match(reading: *Reading, template: [*:0]const u8) bool {
        var t: usize = 0;
        while (template[t] != 0) {
            const c = template[t];
            t += 1;
            if (c == ' ' or c == '\t') {
                reading.skipBlanks();
                continue;
            }
            if (c != '%') {
                if (!reading.literal(c)) return false;
                continue;
            }
            const conversion = template[t];
            if (conversion == 0) return true;
            t += 1;
            const ok = switch (conversion) {
                'a', 'A' => reading.name(locale.DAY_1, locale.ABDAY_7) != null,
                'b', 'B', 'h', 'm' => reading.readMonth(),
                'd', 'e' => reading.field(&reading.mday, 1, 31),
                'H', 'I', 'q', 'Q' => reading.field(&reading.hour, 0, 23),
                'p' => reading.noon(),
                'M' => reading.field(&reading.min, 0, 59),
                'S' => reading.field(&reading.sec, 0, 59),
                'y' => reading.shortYear(),
                'Y' => reading.field(&reading.year, 1978, 9999),
                'D', 'x' => reading.match("%m/%d/%y"),
                'T', 'X' => reading.match("%H:%M:%S"),
                'R' => reading.match("%H:%M"),
                'r' => reading.match("%I:%M:%S %p"),
                'c' => reading.match("%a %b %d %H:%M:%S %Y"),
                'Z' => reading.zone(),
                'n', 't' => blk: {
                    reading.skipBlanks();
                    break :blk true;
                },
                '%' => reading.literal('%'),
                else => false,
            };
            if (!ok) return false;
        }
        return true;
    }

    fn skipBlanks(reading: *Reading) void {
        while (reading.at < reading.text.len and (reading.text[reading.at] == ' ' or reading.text[reading.at] == '\t')) reading.at += 1;
    }

    fn literal(reading: *Reading, c: u8) bool {
        if (reading.at >= reading.text.len) return false;
        if (_chars.toLower(reading.text[reading.at]) != _chars.toLower(c)) return false;
        reading.at += 1;
        return true;
    }

    /// A number, blanks before it passed over, from `least` to `most`.
    fn number(reading: *Reading, least: u32, most: u32) ?u32 {
        reading.skipBlanks();
        var value: u32 = 0;
        var digits: usize = 0;
        while (reading.at < reading.text.len and digits < 9) : (digits += 1) {
            const c = reading.text[reading.at];
            if (c < '0' or c > '9') break;
            value = value * 10 + (c - '0');
            reading.at += 1;
        }
        if (digits == 0 or value < least or value > most) return null;
        return value;
    }

    fn field(reading: *Reading, into: *u32, least: u32, most: u32) bool {
        into.* = reading.number(least, most) orelse return false;
        return true;
    }

    /// The longest of the locale's words `first` to `last` the text has
    /// at `at`, whatever its case, by its number.
    fn name(reading: *Reading, first: u32, last: u32) ?u32 {
        var best: ?u32 = null;
        var best_length: usize = 0;
        var string_num = first;
        while (string_num <= last) : (string_num += 1) {
            const text = reading.lb.iface().GetLocaleStr(reading.loc, string_num) orelse continue;
            const word_length = _format.length(text);
            if (word_length <= best_length or reading.at + word_length > reading.text.len) continue;
            const here = reading.text[reading.at..][0..word_length];
            var same = true;
            for (here, text[0..word_length]) |one, two| {
                if (_chars.toLower(one) != _chars.toLower(two)) same = false;
            }
            if (!same) continue;
            best = string_num;
            best_length = word_length;
        }
        reading.at += best_length;
        return best;
    }

    fn readMonth(reading: *Reading) bool {
        if (reading.name(locale.MON_1, locale.ABMON_12)) |string_num| {
            reading.month = (string_num - locale.MON_1) % 12 + 1;
            return true;
        }
        return reading.field(&reading.month, 1, 12);
    }

    fn noon(reading: *Reading) bool {
        const which = reading.name(locale.AM_STR, locale.PM_STR) orelse return false;
        reading.hour = reading.hour % 12 + if (which == locale.PM_STR) @as(u32, 12) else 0;
        return true;
    }

    fn shortYear(reading: *Reading) bool {
        const value = reading.number(0, 99) orelse return false;
        reading.year = if (value < 78) 2000 + value else 1900 + value;
        return true;
    }

    fn zone(reading: *Reading) bool {
        reading.skipBlanks();
        const start = reading.at;
        while (reading.at < reading.text.len and _chars.is(reading.text[reading.at], _chars.alpha)) reading.at += 1;
        return reading.at > start;
    }
};

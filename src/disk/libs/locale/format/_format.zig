// SPDX-License-Identifier: MIT
//! What FormatDate, ParseDate and FormatString share: the caller's hook
//! as a stream of bytes, a DateStamp as its calendar fields, the time
//! zone's name at a moment, numbers as digits, and a text's width.

const sdk = @import("sdk");
const dos = sdk.dos;
const utility = sdk.utility;
const locale = sdk.locale;
const _base = @import("../locale_base.zig");
const LocaleBase = _base.LocaleBase;

/// The ticks of a second in a DateStamp.
pub const ticks_per_second = 50;

/// The caller's hook as the place bytes go: each handed over with the
/// locale as the object and the byte as the message, through utility's
/// CallHookPkt.
pub const Out = struct {
    lb: *LocaleBase,
    loc: *const locale.Locale,
    hook: *utility.Hook,

    pub fn put(out: *const Out, byte: u8) void {
        _ = out.lb.utility_base.CallHookPkt(out.hook, @constCast(out.loc), @ptrFromInt(byte));
    }

    pub fn text(out: *const Out, bytes: []const u8) void {
        for (bytes) |byte| out.put(byte);
    }

    pub fn string(out: *const Out, bytes: ?[*:0]const u8) void {
        const from = bytes orelse return;
        var at: usize = 0;
        while (from[at] != 0) : (at += 1) out.put(from[at]);
    }

    /// `count` copies of `byte`.
    pub fn repeat(out: *const Out, byte: u8, count: usize) void {
        var left = count;
        while (left > 0) : (left -= 1) out.put(byte);
    }
};

/// A DateStamp as the calendar has it: the date, the time, the weekday and
/// the day of the year.
pub const Clock = struct {
    year: u32,
    /// 1 to 12.
    month: u32,
    /// 1 to 31.
    mday: u32,
    /// 0 (Sunday) to 6.
    wday: u32,
    /// 0 for 1 January.
    yday: u32,
    hour: u32,
    min: u32,
    sec: u32,
    /// Seconds since 1 January 1978, for the time zone.
    seconds: i64,

    pub fn of(lb: *LocaleBase, date: *const dos.DateStamp) Clock {
        const days: u32 = @intCast(@max(date.days, 0));
        const minute: u32 = @intCast(@max(date.minute, 0));
        const tick: u32 = @intCast(@max(date.tick, 0));
        var calendar: utility.ClockData = .{};
        lb.utility_base.DateSplit(days, &calendar);
        const first = lb.utility_base.DateJoin(&.{ .year = calendar.year, .month = 1, .mday = 1 });
        const second: u32 = tick / ticks_per_second;
        return .{
            .year = calendar.year,
            .month = calendar.month,
            .mday = calendar.mday,
            .wday = calendar.wday,
            .yday = days -| @as(u32, @intCast(@max(first, 0))),
            .hour = (minute / 60) % 24,
            .min = minute % 60,
            .sec = second % 60,
            .seconds = @as(i64, days) * 86400 + @as(i64, minute) * 60 + second,
        };
    }
};

/// The name the time zone `rule` gives the local time `seconds` (since
/// 1 January 1978): its summer name in summer time, its standard name
/// else, without the `<>` a name with digits is written in. Empty when
/// the rule is none.
pub fn zoneName(rule: ?[*:0]const u8, seconds: i64) []const u8 {
    const text = rule orelse return "";
    const all = text[0..length(text)];
    const zone = dos.timezone.parse(all) orelse return "";
    var at: usize = 0;
    const standard = nameAt(all, &at);
    while (at < all.len and (all[at] == '+' or all[at] == '-' or all[at] == ':' or (all[at] >= '0' and all[at] <= '9'))) at += 1;
    const summer = nameAt(all, &at);
    if (!zone.has_summer or summer.len == 0) return standard;
    // The rule's dates are in UTC; the local time is a standard hour off
    // at most, which only matters in the hour the clock changes.
    const utc = seconds + dos.timezone.datestamp_epoch - zone.standard;
    return if (zone.offsetAt(utc) == zone.summer) summer else standard;
}

/// The zone name at `at.*` in a rule, `at` moved past it.
fn nameAt(rule: []const u8, at: *usize) []const u8 {
    if (at.* < rule.len and rule[at.*] == '<') {
        const start = at.* + 1;
        var end = start;
        while (end < rule.len and rule[end] != '>') end += 1;
        at.* = if (end < rule.len) end + 1 else end;
        return rule[start..end];
    }
    const start = at.*;
    while (at.* < rule.len and ((rule[at.*] >= 'A' and rule[at.*] <= 'Z') or (rule[at.*] >= 'a' and rule[at.*] <= 'z'))) at.* += 1;
    return rule[start..at.*];
}

/// `value` in decimal into the end of `into`, at least `least` digits
/// with zeros before; what was written.
pub fn decimal(into: []u8, value: u64, least: usize) []const u8 {
    var at = into.len;
    var left = value;
    while (at > 0 and (left != 0 or into.len - at < least or at == into.len)) {
        at -= 1;
        into[at] = @intCast('0' + left % 10);
        left /= 10;
    }
    return into[at..];
}

/// `value` in hexadecimal, its letters capitals, into the end of `into`.
pub fn hexadecimal(into: []u8, value: u64) []const u8 {
    var at = into.len;
    var left = value;
    while (at > 0 and (left != 0 or at == into.len)) {
        at -= 1;
        const digit: u8 = @intCast(left % 16);
        into[at] = if (digit < 10) '0' + digit else 'A' + digit - 10;
        left /= 16;
    }
    return into[at..];
}

/// How many characters `bytes` are in the locale's code set: one a byte
/// in Latin-1, one a byte that does not go on a character in UTF-8.
pub fn width(loc: *const locale.Locale, bytes: []const u8) usize {
    if (loc.code_set != locale.CODESET_UTF8) return bytes.len;
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    return count;
}

/// The first `count` characters of `bytes` in the locale's code set.
pub fn cut(loc: *const locale.Locale, bytes: []const u8, count: usize) []const u8 {
    if (loc.code_set != locale.CODESET_UTF8) return bytes[0..@min(bytes.len, count)];
    var seen: usize = 0;
    for (bytes, 0..) |byte, at| {
        if (byte & 0xC0 != 0x80) {
            if (seen == count) return bytes[0..at];
            seen += 1;
        }
    }
    return bytes;
}

/// The length of a NUL-ended string.
pub fn length(text: [*:0]const u8) usize {
    var count: usize = 0;
    while (text[count] != 0) count += 1;
    return count;
}

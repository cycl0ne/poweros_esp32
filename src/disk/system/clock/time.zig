// SPDX-License-Identifier: MIT
//! What the clock works out from a moment before it draws: the hour, the
//! minute and the second; where the hands point; which of a figure's seven
//! segments are lit; how long until the next thing shown changes; and the
//! sizes and words its settings are kept in. Nothing here draws or asks
//! the system, so all of it is tried on the host.

const sdk = @import("sdk");
const dos = sdk.dos;

/// A DateStamp's ticks in a second.
const ticks_per_second = 50;

/// A moment as the clock shows it.
pub const Shown = struct {
    /// Days since 1 Jan 1978, which says when the date changes.
    days: i32 = 0,
    /// 0 to 23.
    hour: u32 = 0,
    minute: u32 = 0,
    second: u32 = 0,
    /// The first or the second half of the second: what the colon of the
    /// figures blinks by.
    late: bool = false,

    pub fn of(stamp: dos.DateStamp) Shown {
        const minutes: u32 = @intCast(@mod(stamp.minute, 24 * 60));
        const ticks: u32 = @intCast(@mod(stamp.tick, ticks_per_second * 60));
        return .{
            .days = stamp.days,
            .hour = minutes / 60,
            .minute = minutes % 60,
            .second = ticks / ticks_per_second,
            .late = ticks % ticks_per_second >= ticks_per_second / 2,
        };
    }

    /// The hour on a twelve-hour clock: 12, 1, ... 11.
    pub fn twelve(shown: Shown) u32 {
        const hour = shown.hour % 12;
        return if (hour == 0) 12 else hour;
    }

    /// Past noon.
    pub fn afternoon(shown: Shown) bool {
        return shown.hour >= 12;
    }
};

/// Where the hands point, in degrees clockwise from twelve. The hour hand
/// goes on with the minutes; the minute hand moves on at each minute, as a
/// clock's that steps does.
pub const Hands = struct {
    hour: f32,
    minute: f32,
    second: f32,

    pub fn of(shown: Shown) Hands {
        const hour: f32 = @floatFromInt(shown.hour % 12);
        const minute: f32 = @floatFromInt(shown.minute);
        return .{
            .hour = hour * 30 + minute / 2,
            .minute = minute * 6,
            .second = @as(f32, @floatFromInt(shown.second)) * 6,
        };
    }
};

/// How often the picture can change: each half second for the colon's
/// blink, each second for the seconds, each minute for the hands alone.
pub const Step = enum(u32) {
    half_second = ticks_per_second / 2,
    second = ticks_per_second,
    minute = ticks_per_second * 60,
};

/// What the time is past the moment just before the next step, so that a
/// wake comes after the time has changed rather than just before it.
const late_by_us = 2_000;

/// Microseconds from `stamp` until the next `step` begins.
pub fn untilNext(stamp: dos.DateStamp, step: Step) u64 {
    const every = @intFromEnum(step);
    const ticks: u32 = @intCast(@mod(stamp.tick, ticks_per_second * 60));
    const left = every - ticks % every;
    return @as(u64, left) * (1_000_000 / ticks_per_second) + late_by_us;
}

/// The segments of a figure lit, a bit each: the top first (bit 0), then
/// clockwise round - top right, bottom right, bottom, bottom left, top
/// left - and the middle last (bit 6).
pub fn segments(figure: u32) u7 {
    const lit = [10]u7{ 0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F };
    return lit[figure % 10];
}

/// Whether a locale's way of writing the time is on a 24-hour clock: an
/// hour of `%H`, `%k`, `%R` or `%T` is, one of `%I`, `%l`, `%r` or with
/// `%p` is not. A form naming neither is taken as 24 hours.
pub fn twentyFour(form: [*:0]const u8) bool {
    var at: usize = 0;
    while (form[at] != 0) : (at += 1) {
        if (form[at] != '%' or form[at + 1] == 0) continue;
        at += 1;
        switch (form[at]) {
            'H', 'k', 'R', 'T' => return true,
            'I', 'l', 'r', 'p' => return false,
            else => {},
        }
    }
    return true;
}

/// Whether two words are the same, big and small letters alike: how a
/// setting's YES or NO and a tool type's name are read.
pub fn sameWord(a: [*:0]const u8, b: [*:0]const u8) bool {
    var at: usize = 0;
    while (true) : (at += 1) {
        if (lower(a[at]) != lower(b[at])) return false;
        if (a[at] == 0) return true;
    }
}

/// Whether the tool type `entry` - `NAME=value`, or a bare `NAME` - is
/// called `name`.
pub fn namedAs(entry: [*:0]const u8, name: [*:0]const u8) bool {
    var at: usize = 0;
    while (name[at] != 0) : (at += 1) {
        if (lower(entry[at]) != lower(name[at])) return false;
    }
    return entry[at] == 0 or entry[at] == '=';
}

fn lower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

/// A window's inside, as a setting holds it.
pub const Size = struct {
    width: i32,
    height: i32,

    /// "200x220": a width and a height, an x between them. Null for
    /// anything else, or either under 1.
    pub fn parse(text: [*:0]const u8) ?Size {
        var at: usize = 0;
        const width = number(text, &at) orelse return null;
        if (text[at] != 'x' and text[at] != 'X') return null;
        at += 1;
        const height = number(text, &at) orelse return null;
        if (text[at] != 0) return null;
        return .{ .width = width, .height = height };
    }

    /// It as `parse` reads it, into `into`, cut to fit and ended by a NUL.
    pub fn write(size: Size, into: []u8) [:0]const u8 {
        var length: usize = 0;
        length = put(into, length, size.width);
        if (length + 1 < into.len) {
            into[length] = 'x';
            length += 1;
        }
        length = put(into, length, size.height);
        into[length] = 0;
        return into[0..length :0];
    }
};

/// A whole number from `text` at `at`, `at` moved past it; null without a
/// digit there, or 0.
fn number(text: [*:0]const u8, at: *usize) ?i32 {
    var value: i32 = 0;
    const from = at.*;
    while (text[at.*] >= '0' and text[at.*] <= '9' and at.* - from < 6) : (at.* += 1) {
        value = value * 10 + (text[at.*] - '0');
    }
    if (at.* == from or value < 1) return null;
    return value;
}

/// `value`, 0 or more, written at `length` while there is room before the
/// NUL. The length after it.
fn put(into: []u8, length: usize, value: i32) usize {
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var left: u32 = @intCast(@max(value, 0));
    while (true) {
        digits[count] = @intCast('0' + left % 10);
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    var at = length;
    while (count > 0 and at + 1 < into.len) : (at += 1) {
        count -= 1;
        into[at] = digits[count];
    }
    return at;
}

const testing = @import("std").testing;

test "clock: a moment as hours, minutes, seconds and the half of the second" {
    const shown = Shown.of(.{ .days = 17844, .minute = 14 * 60 + 5, .tick = 37 * 50 + 30 });
    try testing.expectEqual(@as(u32, 14), shown.hour);
    try testing.expectEqual(@as(u32, 5), shown.minute);
    try testing.expectEqual(@as(u32, 37), shown.second);
    try testing.expect(shown.late);
    try testing.expectEqual(@as(u32, 2), shown.twelve());
    try testing.expect(shown.afternoon());
    const midnight = Shown.of(.{ .minute = 0, .tick = 10 });
    try testing.expectEqual(@as(u32, 12), midnight.twelve());
    try testing.expect(!midnight.afternoon());
    try testing.expect(!midnight.late);
}

test "clock: the hands, clockwise from twelve" {
    const hands = Hands.of(.{ .hour = 15, .minute = 30, .second = 45 });
    try testing.expectEqual(@as(f32, 105), hands.hour);
    try testing.expectEqual(@as(f32, 180), hands.minute);
    try testing.expectEqual(@as(f32, 270), hands.second);
}

test "clock: the wait until the next half second, second and minute" {
    // 12.4 s into the minute: 0.1 s to the half, 0.6 s to the second,
    // 47.6 s to the minute; each a little later.
    const stamp = dos.DateStamp{ .minute = 600, .tick = 620 };
    try testing.expectEqual(@as(u64, 100_000 + late_by_us), untilNext(stamp, .half_second));
    try testing.expectEqual(@as(u64, 600_000 + late_by_us), untilNext(stamp, .second));
    try testing.expectEqual(@as(u64, 47_600_000 + late_by_us), untilNext(stamp, .minute));
    // On the step itself, the whole of the next one.
    try testing.expectEqual(@as(u64, 1_000_000 + late_by_us), untilNext(.{ .tick = 50 }, .second));
}

test "clock: the segments of each figure" {
    try testing.expectEqual(@as(u7, 0b0111111), segments(0));
    try testing.expectEqual(@as(u7, 0b0000110), segments(1));
    try testing.expectEqual(@as(u7, 0b1111111), segments(8));
    // A middle bar for every figure but 0, 1 and 7.
    for (0..10) |figure| {
        const middle = segments(@intCast(figure)) & 0x40 != 0;
        try testing.expectEqual(figure != 0 and figure != 1 and figure != 7, middle);
    }
}

test "clock: 24 hours or 12 by the locale's form" {
    try testing.expect(twentyFour("%H:%M:%S"));
    try testing.expect(twentyFour("%T"));
    try testing.expect(!twentyFour("%I:%M %p"));
    try testing.expect(!twentyFour("%r"));
    try testing.expect(twentyFour("%%I"));
    try testing.expect(twentyFour(""));
}

test "clock: words and tool types' names, big and small letters alike" {
    try testing.expect(sameWord("no", "NO"));
    try testing.expect(!sameWord("NOT", "NO"));
    try testing.expect(!sameWord("N", "NO"));
    try testing.expect(namedAs("MODE=DIGITAL", "MODE"));
    try testing.expect(namedAs("seconds", "SECONDS"));
    try testing.expect(!namedAs("MODES=1", "MODE"));
    try testing.expect(!namedAs("MOD", "MODE"));
}

test "clock: a size read and written as WIDTHxHEIGHT" {
    const size = Size.parse("200x220").?;
    try testing.expectEqual(@as(i32, 200), size.width);
    try testing.expectEqual(@as(i32, 220), size.height);
    try testing.expectEqual(@as(?Size, null), Size.parse("200"));
    try testing.expectEqual(@as(?Size, null), Size.parse("0x10"));
    try testing.expectEqual(@as(?Size, null), Size.parse("20x10 "));
    var into: [16]u8 = undefined;
    try testing.expectEqualStrings("320x112", (Size{ .width = 320, .height = 112 }).write(&into));
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("320", (Size{ .width = 320, .height = 112 }).write(&small));
}

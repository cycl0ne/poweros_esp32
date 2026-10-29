// SPDX-License-Identifier: MPL-2.0
//! battclock.resource: the clock that keeps the date while the system is
//! off or restarting, in seconds since 1 January 1978.
//!
//! The clock is the board's clock when its system list names one
//! (PARTKIND_RTC): a PCF8563 on I2C (`source/pcf8563.zig`), which keeps
//! the date on its own cell while the board is off; the JH7110's own
//! RTC (`source/jh7110rtc.zig`), which a reset stops but keeps the date
//! in, and a power cut loses it; or the Raspberry Pi's
//! (`source/rpirtc.zig`), which its firmware keeps for the ARM, counting
//! through a reset and - on a cell - a power cut. Otherwise it is the
//! ESP32s' RTC timer (`source/rtctimer.zig`), which counts through a
//! reset but not through a power cut. At its start the resource sets the
//! system time from the clock; `C:SetClock` loads, saves and resets it.
//!
//! Each call is a file of its own under `clock/`. The jump table is
//! battclock_lvo.zig, the ROM tag and init battclock_init.zig, the base
//! battclock_base.zig. This file holds the names the rest of the kernel
//! reaches the resource by, and the tests of the clocks' arithmetic.

const std = @import("std");
const sdk = @import("sdk");
const utility = sdk.utility;

const battclock_base = @import("battclock_base.zig");
const battclock_init = @import("battclock_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from battclock.resource.
comptime {
    _ = &battclock_init.battclock_resource_tag;
}

/// The resource's base.
pub const BattClockBase = battclock_base.BattClockBase;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = battclock_init.RESOURCE_NAME;

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const rtctimer = @import("source/rtctimer.zig");
const pcf8563 = @import("source/pcf8563.zig");
const jh7110rtc = @import("source/jh7110rtc.zig");
const rpirtc = @import("source/rpirtc.zig");

test {
    _ = @import("battclock_lvo.zig");
}

/// About the RC slow clock's period: 7.35 µs.
const period: u32 = 7 << rtctimer.period_shift | 1 << (rtctimer.period_shift - 2) | 1 << (rtctimer.period_shift - 3);

test "the RTC timer's count in microseconds, past 64 bits of product" {
    try testing.expectEqual(@as(u64, 0), rtctimer.microsOf(0, period));
    try testing.expectEqual(@as(u64, 7), rtctimer.microsOf(1, period));
    try testing.expectEqual(@as(u64, 7_375_000), rtctimer.microsOf(1_000_000, period));
    // Forty years of cycles: the product would pass 64 bits.
    const cycles: u64 = 40 * 365 * 24 * 3600 * 136_000;
    const expected = cycles / 8 * 59;
    try testing.expectEqual(expected, rtctimer.microsOf(cycles, period));
}

test "a reckoning gives the date it was set to, and moves on with the count" {
    const at: u64 = 5_000_000;
    const reckoning = rtctimer.setTo(period, at, 1_000_000_000);
    try testing.expect(rtctimer.holdsDate(&reckoning, at));
    try testing.expectEqual(@as(i64, 1_000_000_000), rtctimer.dateAt(&reckoning, at));
    try testing.expectEqual(@as(i64, 1_000_000_000 + 7_375_000), rtctimer.dateAt(&reckoning, at + 1_000_000));
}

test "a reckoning whose count went back, or whose bytes do not add up, holds no date" {
    const reckoning = rtctimer.setTo(period, 5_000_000, 1_000_000_000);
    // A power-on started the count over.
    try testing.expect(!rtctimer.holdsDate(&reckoning, 4_999_999));
    var spoiled = reckoning;
    spoiled.known_date += 1;
    try testing.expect(!rtctimer.holdsDate(&spoiled, 5_000_000));
    var no_magic = reckoning;
    no_magic.magic = 0;
    no_magic = rtctimer.sealed(no_magic);
    try testing.expect(!rtctimer.holdsDate(&no_magic, 5_000_000));
    const empty: rtctimer.Reckoning = std.mem.zeroes(rtctimer.Reckoning);
    try testing.expect(!rtctimer.holdsDate(&empty, 0));
}

test "a new period keeps the date at the count it is taken at" {
    const reckoning = rtctimer.setTo(period, 5_000_000, 1_000_000_000);
    const later: u64 = 9_000_000;
    const before = rtctimer.dateAt(&reckoning, later);
    const faster = rtctimer.carriedOver(&reckoning, period - 1000, later);
    try testing.expectEqual(before, rtctimer.dateAt(&faster, later));
    try testing.expectEqual(period - 1000, faster.period);
    try testing.expect(rtctimer.holdsDate(&faster, later));
}

test "the period timed between two edges of the slow clock" {
    // 1024 cycles in 7.5 ms of the system timer's 16 MHz: 7.32421875 µs.
    const first: rtctimer.Edge = .{ .count = 100, .ticks = 1_000_000 };
    const last: rtctimer.Edge = .{ .count = 1124, .ticks = 1_000_000 + 120_000 };
    try testing.expectEqual(@as(u32, 3_840_000), rtctimer.periodBetween(first, last));
}

test "the PCF8563's registers: a date both ways, across the century bit" {
    const dates = [_]utility.ClockData{
        .{ .sec = 0, .min = 0, .hour = 0, .mday = 1, .month = 1, .year = 1978, .wday = 0 },
        .{ .sec = 59, .min = 59, .hour = 23, .mday = 31, .month = 12, .year = 1999, .wday = 5 },
        .{ .sec = 7, .min = 42, .hour = 13, .mday = 12, .month = 10, .year = 2026, .wday = 1 },
        .{ .sec = 59, .min = 59, .hour = 23, .mday = 31, .month = 12, .year = 2099, .wday = 4 },
    };
    for (dates) |date| {
        const regs = pcf8563.registersOf(date);
        try testing.expectEqual(date, pcf8563.dateOf(regs).?);
    }
    const regs = pcf8563.registersOf(dates[2]);
    try testing.expectEqual([7]u8{ 0x07, 0x42, 0x13, 0x12, 1, 0x80 | 0x10, 0x26 }, regs);
}

test "the PCF8563's registers: a low cell, a non-BCD digit and an early year are no date" {
    var regs = pcf8563.registersOf(.{ .sec = 7, .min = 42, .hour = 13, .mday = 12, .month = 10, .year = 2026, .wday = 1 });
    var low = regs;
    low[0] |= 0x80;
    try testing.expectEqual(@as(?utility.ClockData, null), pcf8563.dateOf(low));
    var bad = regs;
    bad[1] = 0x5A;
    try testing.expectEqual(@as(?utility.ClockData, null), pcf8563.dateOf(bad));
    // A chip from the factory: 1900, and month 0.
    regs = .{ 0, 0, 0, 1, 0, 1, 0 };
    try testing.expectEqual(@as(?utility.ClockData, null), pcf8563.dateOf(regs));
    var month_zero = pcf8563.registersOf(.{ .sec = 0, .min = 0, .hour = 0, .mday = 1, .month = 1, .year = 2026, .wday = 4 });
    month_zero[5] = 0x80;
    try testing.expectEqual(@as(?utility.ClockData, null), pcf8563.dateOf(month_zero));
}

test "the JH7110 RTC's registers for a date, and the date back" {
    const date: utility.ClockData = .{ .sec = 18, .min = 55, .hour = 21, .mday = 25, .month = 10, .year = 2026 };
    const regs = jh7110rtc.registersOf(date);
    // As the VisionFive 2's RTC read at that moment.
    try testing.expectEqual(@as(u32, 0x0008_6A98), regs.time);
    try testing.expectEqual(@as(u32, 0x0001_3425), regs.date);
    const back = jh7110rtc.dateOf(regs).?;
    try testing.expectEqual(date.sec, back.sec);
    try testing.expectEqual(date.min, back.min);
    try testing.expectEqual(date.hour, back.hour);
    try testing.expectEqual(date.mday, back.mday);
    try testing.expectEqual(date.month, back.month);
    try testing.expectEqual(date.year, back.year);
    const last = jh7110rtc.dateOf(jh7110rtc.registersOf(.{ .sec = 59, .min = 59, .hour = 23, .mday = 31, .month = 12, .year = 2099 })).?;
    try testing.expectEqual(@as(u16, 2099), last.year);
    try testing.expectEqual(@as(u16, 23), last.hour);
}

test "what a power-on leaves in the JH7110 RTC, and day 0, are no date" {
    // As the VisionFive 2's RTC read after a power-on: no minute 5B, no
    // day 32.
    try testing.expect(jh7110rtc.dateOf(.{ .time = 0x0013_ED88, .date = 0x0002_3C32 }) == null);
    try testing.expect(jh7110rtc.dateOf(.{ .time = 0x0008_6A98, .date = 0x0002_3C32 }) == null);
    // How the resource keeps no date.
    try testing.expect(jh7110rtc.dateOf(.{ .time = 0, .date = 0 }) == null);
    // A month 13, and an hour 24.
    try testing.expect(jh7110rtc.dateOf(.{ .time = 0x0008_6A98, .date = 0x0001_34E5 }) == null);
    try testing.expect(jh7110rtc.dateOf(.{ .time = 0x0009_0000, .date = 0x0001_3425 }) == null);
}

test "the Raspberry Pi's RTC: its messages, and its count since 1970 as seconds since 1978" {
    const videocore = sdk.hardware.videocore;
    var asked: videocore.Buffer = undefined;
    const words = videocore.message(&asked, rpirtc.TAG_SET_RTC_REG, &.{ 0, 1_700_000_000 });
    try testing.expectEqualSlices(u32, &.{ 32, 0, 0x0003_8087, 8, 0, 0, 1_700_000_000, 0 }, asked[0..words]);
    // Not answered: the codes as they were sent.
    var value = [2]u32{ 0, 0 };
    try testing.expect(!videocore.answer(&asked, &value));
    var answered = asked;
    answered[1] = 0x8000_0000;
    answered[4] = 0x8000_0008;
    try testing.expect(videocore.answer(&answered, &value));
    try testing.expectEqual(@as(u32, 1_700_000_000), value[1]);
    answered[1] = 0x8000_0001;
    try testing.expect(!videocore.answer(&answered, &value));
    // 1 January 1978 is the first date; a count from a power-on without a
    // cell is none.
    try testing.expectEqual(@as(?u32, 0), rpirtc.secondsOf(252_460_800));
    try testing.expectEqual(@as(?u32, null), rpirtc.secondsOf(12));
    try testing.expectEqual(@as(?u32, 1_700_000_000 - 252_460_800), rpirtc.secondsOf(1_700_000_000));
    try testing.expectEqual(@as(u32, 1_700_000_000), rpirtc.countOf(1_700_000_000 - 252_460_800));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), rpirtc.countOf(0xFFFF_0000));
}

test "the Raspberry Pi's RTC: its buffer on a cache line of its own, below 4 GiB" {
    try testing.expectEqual(@as(usize, 0x3000_0040), @intFromPtr(rpirtc.bufferIn(@ptrFromInt(0x3000_0010)).?));
    try testing.expectEqual(@as(usize, 0x3000_0040), @intFromPtr(rpirtc.bufferIn(@ptrFromInt(0x3000_0040)).?));
    try testing.expect(rpirtc.bufferIn(@ptrFromInt(0x1_0000_0000)) == null);
}

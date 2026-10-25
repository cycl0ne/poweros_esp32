// SPDX-License-Identifier: MPL-2.0
//! What the three calls share: the date read from, and set on, whichever
//! clock the resource keeps it in, in seconds since 1 January 1978.

const sdk = @import("sdk");
const utility = sdk.utility;
const _base = @import("../battclock_base.zig");
const BattClockBase = _base.BattClockBase;
const rtctimer = @import("../source/rtctimer.zig");
const pcf8563 = @import("../source/pcf8563.zig");
const jh7110rtc = @import("../source/jh7110rtc.zig");

/// The ESP32s' RTC timer and the JH7110's RTC, each on its own chip.
const has_rtc_timer = sdk.hardware.chip == .esp32s3 or sdk.hardware.chip == .esp32p4;
const has_jh7110_rtc = sdk.hardware.chip == .rv64sbi;

/// The RTC timer's period timed again, over the whole time since the
/// start.
fn refinePeriod(cb: *BattClockBase) void {
    cb.period = rtctimer.refine(cb.sys_base, .{ .count = cb.start_count, .ticks = cb.start_ticks }, cb.period);
}

/// The date the clock says, in seconds since 1 January 1978; null when
/// it holds none, or there is no clock.
pub fn secondsNow(cb: *BattClockBase) ?u32 {
    switch (cb.clock) {
        _base.CLOCK_RTC_TIMER => if (comptime has_rtc_timer) {
            refinePeriod(cb);
            const micros = rtctimer.read(cb.period) orelse return null;
            if (micros < 0) return null;
            const seconds = @divTrunc(micros, 1_000_000);
            return if (seconds > 0xFFFF_FFFF) null else @intCast(seconds);
        } else return null,
        _base.CLOCK_PCF8563 => {
            const regs = pcf8563.read(cb) orelse return null;
            const date = pcf8563.dateOf(regs) orelse return null;
            const ub = cb.utility_base orelse return null;
            return ub.Date2Amiga(&date);
        },
        _base.CLOCK_JH7110_RTC => if (comptime has_jh7110_rtc) {
            if (!jh7110rtc.counting(cb.rtc_address)) return null;
            const date = jh7110rtc.dateOf(jh7110rtc.read(cb.rtc_address)) orelse return null;
            const ub = cb.utility_base orelse return null;
            return ub.Date2Amiga(&date);
        } else return null,
        else => return null,
    }
}

/// The clock set to `seconds` since 1 January 1978. A PCF8563 and the
/// JH7110's RTC keep the years to 2099: a later date is kept as the last
/// second of 2099. The JH7110's RTC starts in 2000: an earlier date is
/// no date there, and it stops.
pub fn setSeconds(cb: *BattClockBase, seconds: u32) void {
    switch (cb.clock) {
        _base.CLOCK_RTC_TIMER => if (comptime has_rtc_timer) {
            refinePeriod(cb);
            rtctimer.write(cb.period, @as(i64, seconds) * 1_000_000);
        },
        _base.CLOCK_PCF8563 => {
            const ub = cb.utility_base orelse return;
            var date: utility.ClockData = .{};
            ub.Amiga2Date(seconds, &date);
            if (date.year > 2099) date = .{ .sec = 59, .min = 59, .hour = 23, .mday = 31, .month = 12, .year = 2099, .wday = 4 };
            pcf8563.write(cb, pcf8563.registersOf(date));
        },
        _base.CLOCK_JH7110_RTC => if (comptime has_jh7110_rtc) {
            const ub = cb.utility_base orelse return;
            jh7110rtc.write(cb.rtc_address, jh7110rtc.registersAt(ub, seconds));
        },
        else => {},
    }
}

/// The clock put in working order: a PCF8563's control registers
/// cleared, so that it runs with no test mode and no interrupt. The RTC
/// timer and the JH7110's RTC need nothing.
pub fn restart(cb: *BattClockBase) void {
    if (cb.clock == _base.CLOCK_PCF8563) pcf8563.restart(cb);
}

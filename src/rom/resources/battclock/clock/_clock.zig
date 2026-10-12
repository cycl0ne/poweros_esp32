// SPDX-License-Identifier: MPL-2.0
//! What the three calls share: the date read from, and set on, whichever
//! clock the resource keeps it in, in seconds since 1 January 1978.

const sdk = @import("sdk");
const utility = sdk.utility;
const _base = @import("../battclock_base.zig");
const BattClockBase = _base.BattClockBase;
const rtctimer = @import("../source/rtctimer.zig");
const pcf8563 = @import("../source/pcf8563.zig");

/// The RTC timer's period timed again, over the whole time since the
/// start.
fn refinePeriod(cb: *BattClockBase) void {
    cb.period = rtctimer.refine(cb.sys_base, .{ .count = cb.start_count, .ticks = cb.start_ticks }, cb.period);
}

/// The date the clock says, in seconds since 1 January 1978; null when
/// it holds none, or there is no clock.
pub fn secondsNow(cb: *BattClockBase) ?u32 {
    switch (cb.clock) {
        _base.CLOCK_RTC_TIMER => {
            refinePeriod(cb);
            const micros = rtctimer.read(cb.period) orelse return null;
            if (micros < 0) return null;
            const seconds = @divTrunc(micros, 1_000_000);
            return if (seconds > 0xFFFF_FFFF) null else @intCast(seconds);
        },
        _base.CLOCK_PCF8563 => {
            const regs = pcf8563.read(cb) orelse return null;
            const date = pcf8563.dateOf(regs) orelse return null;
            const ub = cb.utility_base orelse return null;
            return ub.Date2Amiga(&date);
        },
        else => return null,
    }
}

/// The clock set to `seconds` since 1 January 1978. A PCF8563 keeps the
/// years to 2099: a later date is kept as the last second of 2099.
pub fn setSeconds(cb: *BattClockBase, seconds: u32) void {
    switch (cb.clock) {
        _base.CLOCK_RTC_TIMER => {
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
        else => {},
    }
}

/// The clock put in working order: a PCF8563's control registers
/// cleared, so that it runs with no test mode and no interrupt. The RTC
/// timer needs nothing.
pub fn restart(cb: *BattClockBase) void {
    if (cb.clock == _base.CLOCK_PCF8563) pcf8563.restart(cb);
}

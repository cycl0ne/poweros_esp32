// SPDX-License-Identifier: MPL-2.0
//! battclock.resource's base: which clock it keeps the date in, and what
//! that clock needs.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// No clock: the board lists no clock chip that answers, and the RTC
/// timer does not count.
pub const CLOCK_NONE: u32 = 0;
/// The chip's own RTC timer (source/rtctimer.zig).
pub const CLOCK_RTC_TIMER: u32 = 1;
/// A PCF8563 on I2C (source/pcf8563.zig).
pub const CLOCK_PCF8563: u32 = 2;

pub const BattClockBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// utility.library, for Amiga2Date and Date2Amiga: opened at init
    /// and kept.
    utility_base: ?*UtilityBase,
    /// CLOCK_*.
    clock: u32,
    /// The PCF8563's bus - i2c.device's unit - and its address.
    i2c_unit: u32,
    i2c_address: u32,
    /// The RTC timer's slow clock: microseconds per cycle, 19 bits of them
    /// fraction - measured at this start, then over the time since.
    period: u32,
    /// The edge of the slow clock this start's measurement began at: its
    /// count, and the system timer's then.
    start_count: u64,
    start_ticks: u64,
    /// Held for each call: one caller at a time at the clock, since
    /// setting one is several steps.
    lock: exec.SignalSemaphore,
};

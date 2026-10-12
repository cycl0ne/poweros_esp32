// SPDX-License-Identifier: MPL-2.0
//! WriteBattClock: the clock set.

const _clock = @import("_clock.zig");
const BattClockBase = @import("../battclock_base.zig").BattClockBase;

/// The clock set to a date.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteBattClock(cb: *BattClockBase, seconds: u32) void
/// ```
///
/// SINCE: 1.0. LVO -12.
///
/// INPUTS:
/// - `seconds` - the date, in seconds since 1 January 1978, 00:00:00.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Writes the date to the board's clock chip, or makes the chip's RTC
/// timer's reckoning give it from now on. Without a clock nothing
/// happens.
///
/// CONTEXT:
/// - Waits: yes, for the resource's semaphore and for i2c.device.
/// - Interrupts: no.
/// - Locks: the resource's semaphore, for the call.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// The system time is not changed. `C:SetClock SAVE` writes the system
/// time here.
///
/// BUGS:
/// A PCF8563 keeps the years to 2099; a later date is kept as the last
/// second of 2099.
///
/// SEE ALSO:
/// `ReadBattClock`, `ResetBattClock`, utility.library/Date2Amiga,
/// C:SetClock
///
/// EXAMPLES:
/// ```zig
/// var now: timer.TimeVal = .{};
/// timer_base.GetSysTime(&now);
/// cb.WriteBattClock(now.secs);
/// ```
pub fn WriteBattClock(cb: *BattClockBase, seconds: u32) void {
    const sys = cb.sys_base;
    sys.ObtainSemaphore(&cb.lock);
    defer sys.ReleaseSemaphore(&cb.lock);
    _clock.setSeconds(cb, seconds);
}

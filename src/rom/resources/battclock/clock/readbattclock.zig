// SPDX-License-Identifier: MPL-2.0
//! ReadBattClock: the date the clock says.

const _clock = @import("_clock.zig");
const BattClockBase = @import("../battclock_base.zig").BattClockBase;

/// The date the clock says, in seconds since 1 January 1978.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadBattClock(cb: *BattClockBase) u32
/// ```
///
/// SINCE: 1.0. LVO -8.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The seconds since 1 January 1978, 00:00:00; 0 when the clock held no
/// date, or there is no clock.
///
/// BEHAVIOR:
/// Reads the board's clock chip, asks the Raspberry Pi's firmware for
/// its RTC, or works the date out from the chip's RTC timer. A clock that
/// holds no date - a chip whose cell ran low or whose registers hold no
/// date, a Raspberry Pi's RTC before 1978 after a power-on without a
/// cell, an RTC timer after a power-on - is put in working order and set
/// to 1 January 1978, as ResetBattClock does, and the answer is 0.
///
/// CONTEXT:
/// - Waits: yes, for the resource's semaphore and for i2c.device; for
///   the Raspberry Pi's firmware it spins, a millisecond or so.
/// - Interrupts: no.
/// - Locks: the resource's semaphore, for the call.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// The resource sets the system time from this at its start; afterwards
/// the system time is timer.device's, and the two part ways as the
/// clocks drift. `C:SetClock SAVE` brings the clock back to the system
/// time. The date is whatever the system time was when it was written:
/// local time, where a zone is set.
///
/// BUGS:
/// The RTC timer's slow clock is an RC oscillator, measured at each start:
/// over a long run without a write the date it gives after a reset can
/// be off by some seconds a day.
///
/// SEE ALSO:
/// `WriteBattClock`, `ResetBattClock`, utility.library/Amiga2Date,
/// C:SetClock
///
/// EXAMPLES:
/// ```zig
/// var date: utility.ClockData = .{};
/// ub.Amiga2Date(cb.ReadBattClock(), &date);
/// ```
pub fn ReadBattClock(cb: *BattClockBase) u32 {
    const sys = cb.sys_base;
    sys.ObtainSemaphore(&cb.lock);
    defer sys.ReleaseSemaphore(&cb.lock);
    if (_clock.secondsNow(cb)) |seconds| return seconds;
    _clock.restart(cb);
    _clock.setSeconds(cb, 0);
    return 0;
}

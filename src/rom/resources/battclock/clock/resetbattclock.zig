// SPDX-License-Identifier: MPL-2.0
//! ResetBattClock: the clock put in working order and set to 1 January
//! 1978.

const _clock = @import("_clock.zig");
const BattClockBase = @import("../battclock_base.zig").BattClockBase;

/// The clock put in working order, its date 1 January 1978, 00:00:00.
///
/// SYNOPSIS:
/// ```zig
/// fn ResetBattClock(cb: *BattClockBase) void
/// ```
///
/// SINCE: 1.0. LVO -4.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A clock chip has its control registers cleared - running, no test
/// mode, no alarm or timer interrupt - and its date set; the Raspberry
/// Pi's RTC has its date set. The chip's RTC timer has its reckoning
/// set, so that it holds a date again. Without a clock nothing happens.
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
/// The system time is not changed: `C:SetClock LOAD` sets it from the
/// clock.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadBattClock`, `WriteBattClock`, C:SetClock
///
/// EXAMPLES:
/// ```zig
/// const cb: *BattClockBase = @ptrCast(sys.OpenResource(battclock.BATTCLOCKNAME) orelse return);
/// cb.ResetBattClock();
/// ```
pub fn ResetBattClock(cb: *BattClockBase) void {
    const sys = cb.sys_base;
    sys.ObtainSemaphore(&cb.lock);
    defer sys.ReleaseSemaphore(&cb.lock);
    _clock.restart(cb);
    _clock.setSeconds(cb, 0);
}

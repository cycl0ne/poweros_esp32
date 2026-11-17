// SPDX-License-Identifier: MPL-2.0
//! SpinUs: a wait of microseconds that does not give the CPU away.

const _time = @import("_time.zig");
const ExecBase = @import("../exec.zig").ExecBase;

/// Waits a number of microseconds without giving the CPU away.
///
/// SYNOPSIS:
/// ```zig
/// fn SpinUs(base: *ExecBase, us: u64) void
/// ```
///
/// SINCE: 1.42. LVO -604.
///
/// INPUTS:
/// - `us` - how long, in microseconds. 0 returns at once.
///
/// RESULT:
/// None. It returns when at least that long has passed.
///
/// BEHAVIOR:
/// The machine's counter is read until it has moved on by that many
/// microseconds: the caller's core does nothing else meanwhile, and no
/// other task gets it. It is the wait for where no other is possible -
/// with a spinlock held, in an interrupt, before timer.device is there -
/// and for the few microseconds a part's datasheet asks between two
/// writes, which are over before a task switch would be.
///
/// Anything longer belongs to timer.device, in a task: a millisecond
/// spun is a millisecond no task of that core runs, and with interrupts
/// off it is one no interrupt is taken.
///
/// CONTEXT:
/// - Waits: no - it spins.
/// - Interrupts: yes.
/// - Locks: none; a spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing.
///
/// NOTES:
/// An interrupt taken meanwhile is served, and its time counts: the wait
/// is never shorter than asked and may be longer.
///
/// On the ESP32-S3 this call's code is in the flash: code that runs
/// with the flash's cache off spins on the counter itself
/// (`sdk.hardware.systimer`).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UptimeUs`, `GetTimeBase`
///
/// EXAMPLES:
/// ```zig
/// // Reset held for ten microseconds, as the part asks.
/// setReset(part, true);
/// sys.SpinUs(10);
/// setReset(part, false);
/// ```
pub fn SpinUs(_: *ExecBase, us: u64) void {
    _time.clock.spinUs(us);
}

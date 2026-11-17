// SPDX-License-Identifier: MPL-2.0
//! UptimeUs: the time since the machine came up, in microseconds.

const _time = @import("_time.zig");
const ExecBase = @import("../exec.zig").ExecBase;

/// Tells how long the machine has been up, in microseconds.
///
/// SYNOPSIS:
/// ```zig
/// fn UptimeUs(base: *ExecBase) u64
/// ```
///
/// SINCE: 1.42. LVO -600.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Microseconds since the machine came up. It only ever grows, and does
/// not wrap while a machine can run.
///
/// BEHAVIOR:
/// The machine's counter is read and divided by its rate, which the
/// kernel knows (`GetTimeBase`). It is the clock a driver times a wait
/// by: read once for a deadline, and again in the loop that waits for
/// the hardware.
///
/// It is not the time of day - timer.device keeps that, and its
/// `GetSysTime` answers it - and it does not stop while the machine
/// sleeps a core.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Locks: none; a spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing.
///
/// NOTES:
/// On the ESP32-S3 this call's code is in the flash, like every call of
/// exec's: code that runs with the flash's cache off reads the counter
/// itself (`sdk.hardware.systimer`).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SpinUs`, `GetTimeBase`, timer.device's `ReadEClock` and `GetSysTime`
///
/// EXAMPLES:
/// ```zig
/// // Wait for the part to say it is ready, a tenth of a second at most.
/// const until = sys.UptimeUs() + 100_000;
/// while (!ready(part)) {
///     if (sys.UptimeUs() > until) return false;
/// }
/// ```
pub fn UptimeUs(_: *ExecBase) u64 {
    return _time.clock.uptimeUs();
}

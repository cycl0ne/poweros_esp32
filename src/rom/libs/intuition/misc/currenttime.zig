// SPDX-License-Identifier: MPL-2.0
//! CurrentTime: the time of the latest input event.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Answers the time of the latest input event.
///
/// SYNOPSIS:
/// ```zig
/// fn CurrentTime(ib: *IntuitionBase, seconds: *u32, micros: *u32) void
/// ```
///
/// SINCE: 0.14. LVO -412.
///
/// INPUTS:
/// - `seconds`, `micros` - where the time goes.
///
/// RESULT:
/// Nothing; the time is where the two point.
///
/// BEHAVIOR:
/// The time stamp of the input event intuition handled last, in the
/// system time's seconds and microseconds - the clock `DoubleClick` and
/// IDCMP messages are measured on. With input.device running a timer
/// event comes ten times a second, so it is never more than a tenth of a
/// second behind; before any event it is 0.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// For a precise time, timer.device's `GetSysTime`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DoubleClick`
///
/// EXAMPLES:
/// ```zig
/// var seconds: u32 = 0;
/// var micros: u32 = 0;
/// ib.CurrentTime(&seconds, &micros);
/// ```
pub fn CurrentTime(ib: *IntuitionBase, seconds: *u32, micros: *u32) void {
    const time = ib.input.time;
    seconds.* = @truncate(time.secs);
    micros.* = @truncate(time.micro);
}

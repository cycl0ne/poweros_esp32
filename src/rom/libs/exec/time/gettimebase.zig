// SPDX-License-Identifier: MPL-2.0
//! GetTimeBase: how fast the machine's counter counts, for a module that
//! reads the counter itself.

const sdk = @import("sdk");
const ExecBase = @import("../exec.zig").ExecBase;

/// Tells how many times a second the machine's counter counts.
///
/// SYNOPSIS:
/// ```zig
/// fn GetTimeBase(base: *ExecBase) u64
/// ```
///
/// SINCE: 1.41. LVO -596.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The counter's rate in Hertz. Never 0.
///
/// BEHAVIOR:
/// Every machine has one counter that runs from its start at a fixed
/// rate, which `sdk.hardware.systimer` reads: the core's timestamp
/// counter on an x86-64 machine, the time register on a RISC-V one, the
/// generic timer's count on an AArch64 one (`systimer.read`), unit 0 of
/// SYSTIMER on the ESP32s (`systimer.readUnit0`). This is that counter's
/// rate: a count divided by it is seconds since the machine came up.
///
/// The rate is the kernel's to know. On the ESP32s it is the chip's own
/// and never other. On the 64-bit machines the kernel learns it as it
/// starts - from the board's list, from the timer itself, or by timing
/// the counter against another clock where the core does not say - and
/// only its own modules share what it learned. A module loaded from the
/// disk is built on its own, and what `sdk.hardware.systimer` keeps of
/// the rate is not set in it: it asks here, once, and counts with the
/// answer.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing.
///
/// NOTES:
/// It does not change while the machine runs.
///
/// timer.device's `ReadEClock` answers a count and its rate in one, for
/// whoever has the device open; this needs nothing opened and is there
/// before timer.device is.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CoreCount`, timer.device's `ReadEClock`
///
/// EXAMPLES:
/// ```zig
/// // Microseconds since the machine came up, in a driver on the disk of
/// // a 64-bit machine.
/// const rate = sys.GetTimeBase();
/// const micros = sdk.hardware.systimer.read() / (rate / 1_000_000);
/// ```
pub fn GetTimeBase(_: *ExecBase) u64 {
    const systimer = sdk.hardware.systimer;
    return if (@hasDecl(systimer, "timebase_hz")) systimer.timebase_hz else systimer.SYSTIMER_HZ;
}

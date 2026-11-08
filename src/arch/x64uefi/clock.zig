// SPDX-License-Identifier: MPL-2.0
//! The CPU's clock: the firmware's to set, and not a thing the core tells
//! anyone. What the shell and platform.resource show is the rate of the
//! core's timestamp counter, measured against the machine's
//! power-management timer as the kernel starts (timer.zig) - which on every
//! core this runs on is the core's own base clock, since that is what an
//! invariant counter counts at, whatever clock the core is running at this
//! moment. The "crystal" is that same counter's rate: it is the one clock
//! on this machine whose figure is known.

const timer = @import("timer.zig");
const systimer = @import("sdk").hardware.systimer;

/// The clock the CPU runs at, as measured: 0 until the tick starts.
pub var cpu_hz: u32 = 0;
/// The counter's rate, the one clock that is known.
pub var xtal_hz: u32 = 0;
/// No PLL of the kernel's own.
pub const pll_calibrated = true;

/// The figures read once the tick has been set up.
pub fn init() void {
    cpu_hz = timer.measured_cpu_hz;
    xtal_hz = systimer.timebase_hz;
}

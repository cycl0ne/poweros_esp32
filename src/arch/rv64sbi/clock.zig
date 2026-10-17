// SPDX-License-Identifier: MPL-2.0
//! The CPU's clock: the firmware's to set, and nothing supervisor mode can
//! read. What the shell and platform.resource show is the clock measured
//! against `time` (timer.zig); the "crystal" is the timebase.

const timer = @import("timer.zig");
const systimer = @import("sdk").hardware.systimer;

/// The clock the CPU runs at, as measured: 0 until the tick starts.
pub var cpu_hz: u32 = 0;
/// The timebase, the one clock that is known.
pub var xtal_hz: u32 = 0;
/// No PLL of the kernel's own.
pub const pll_calibrated = true;

/// The figures read once the tick has measured the CPU.
pub fn init() void {
    cpu_hz = timer.measured_cpu_hz;
    xtal_hz = systimer.timebase_hz;
}

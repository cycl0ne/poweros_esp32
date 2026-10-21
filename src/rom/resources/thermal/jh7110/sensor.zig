// SPDX-License-Identifier: MPL-2.0
//! The JH7110's own temperature sensor: one register. Its low three bits
//! run it - out of power-down, out of its own reset, converting - and
//! bits 16 to 27 hold its last conversion, which it makes again by itself
//! for as long as it runs. A conversion is DOUT * 237.5 / 4094 - 81.1
//! degrees Celsius.
//!
//! Its two clocks and two resets are the system generator's: the bus's
//! (TEMP_APB) and the sensor's own (TEMP_CORE, the 24 MHz oscillator
//! divided by 24 - its value from reset, which Linux leaves). U-Boot
//! leaves both clocks off and both resets held.
//!
//! Its limits are Linux's for the JH7110 (jh7110.dtsi's cpu-thermal
//! zone): hot at 85 degrees, the passive trip, where Linux slows the
//! cores; critical at 100, where it shuts down.
//!
//! The bits, their order, the waits and the conversion's constants as
//! Linux's driver has them (sfctemp.c).

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const system = sdk.hardware.system;
const systimer = sdk.hardware.systimer;
const ExecBase = sdk.interface.exec.ExecBase;

/// The register's bits: out of its reset (low: held), powered down,
/// converting; and where the conversion is.
const SENSE_RSTN: u32 = 1 << 0;
const SENSE_PD: u32 = 1 << 1;
const SENSE_RUN: u32 = 1 << 2;
const DOUT_SHIFT = 16;
const DOUT_MASK: u32 = 0xFFF << DOUT_SHIFT;

/// The sensor's own clock: the oscillator divided by this.
const core_divider: u32 = 24;
/// How long the first conversion is waited for at the most.
const first_conversion_us: u32 = 50_000;

/// The limits, in thousandths of a degree.
pub const hot: i32 = 85_000;
pub const critical: i32 = 100_000;

const resets = [_]u32{ system.SYSRST_TEMP_APB, system.SYSRST_TEMP_CORE };

/// The sensor at `base` clocked, out of reset, powered up and converting:
/// false if it did not come out of reset. The reset words are shared, so
/// they change under Disable.
pub fn start(sys: *ExecBase, base: usize) bool {
    sys.Disable();
    system.clockOn(.sys, system.SYSCLK_TEMP_APB);
    system.setClock(.sys, system.SYSCLK_TEMP_CORE, system.CLK_ENABLE | system.CLK_DIVIDER, system.CLK_ENABLE | core_divider);
    for (resets) |reset| system.releaseReset(.sys, reset);
    sys.Enable();
    for (resets) |reset| {
        if (!system.waitOutOfReset(.sys, reset)) return false;
    }
    const register = reg(base);
    // Powered down first, then up: the analogue part takes 50
    // microseconds, its reset held 100 nanoseconds after that.
    register.* = SENSE_PD;
    systimer.spinUs(1);
    register.* = 0;
    systimer.spinUs(100);
    register.* = SENSE_RSTN;
    systimer.spinUs(1);
    register.* = SENSE_RSTN | SENSE_RUN;
    // Its first conversion, so there is a reading from the start; Linux
    // reads without waiting, and gets none at first.
    var waited: u32 = 0;
    while (read(base) == null and waited < first_conversion_us) : (waited += 100) systimer.spinUs(100);
    return true;
}

/// The last conversion in thousandths of a degree; null before the first.
pub fn read(base: usize) ?i32 {
    const dout = (reg(base).* & DOUT_MASK) >> DOUT_SHIFT;
    if (dout == 0) return null;
    return millicelsius(dout);
}

/// A conversion in thousandths of a degree.
pub fn millicelsius(dout: u32) i32 {
    const scaled: i32 = @intCast(dout * 237_500 / 4094);
    return scaled - 81_100;
}

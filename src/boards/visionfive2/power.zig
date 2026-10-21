// SPDX-License-Identifier: MPL-2.0
//! The VisionFive 2's power controller: an X-Powers AXP15060 on I2C5 at
//! address 0x36, which every supply on the board comes from - its DCDC2
//! the cores' (vdd_cpu), 0.9 V as the firmware leaves it - and through
//! which OpenSBI resets the board (`reset.zig`).
//!
//! DCDC2's voltage is the low seven bits of its register, 0x14: 0.5 V to
//! 1.2 V in 10 mV steps (0x00 to 0x46), then 1.22 V to 1.54 V in 20 mV
//! steps (0x47 to 0x57). A voltage between two steps gets the higher one.
//! The bit above is left as the firmware set it. Linux's driver gives
//! DCDC2 no ramp time and waits for none; the kernel waits 2 ms after a
//! change, which it makes once, as it starts.
//!
//! The registers as Linux's driver has them (axp20x.h,
//! axp20x-regulator.c).

const hardware = @import("sdk").hardware;
const system = hardware.system;
const systimer = hardware.systimer;
const dwi2c = hardware.dwi2c;

/// I2C5, a DesignWare I2C controller, and the AXP15060's address on it.
const I2C5: usize = 0x1205_0000;
const AXP15060: u7 = 0x36;

const DCDC2_V_CTRL: u8 = 0x14;
const DCDC2_V_MASK: u8 = 0x7F;

/// How long DCDC2 is given to reach a new voltage.
const settle_us = 2000;

/// I2C5 running and set up as U-Boot had it: its clock on, its reset
/// released, the controller a master at 100 kHz. False if it did not come
/// out of reset or would not stop. Interrupts off: the reset word is
/// shared.
pub fn bringUp() bool {
    system.clockOn(.sys, system.SYSCLK_I2C5_APB);
    system.releaseReset(.sys, system.SYSRST_I2C5_APB);
    if (!system.waitOutOfReset(.sys, system.SYSRST_I2C5_APB)) return false;
    return dwi2c.setUp(I2C5);
}

/// The cores' supply at `microvolts` (`boards.cpu_supply`): written,
/// read back and given time to get there. False if the controller did
/// not answer, or DCDC2 has no such voltage.
pub fn setCpuSupply(microvolts: u32) bool {
    const code = dcdc2Code(microvolts) orelse return false;
    if (!bringUp()) return false;
    const now = dwi2c.readRegister(I2C5, AXP15060, DCDC2_V_CTRL) orelse return false;
    const wanted = (now & ~DCDC2_V_MASK) | code;
    if (wanted == now) return true;
    if (!dwi2c.writeRegister(I2C5, AXP15060, DCDC2_V_CTRL, wanted)) return false;
    const written = dwi2c.readRegister(I2C5, AXP15060, DCDC2_V_CTRL) orelse return false;
    if (written != wanted) return false;
    systimer.spinUs(settle_us);
    return true;
}

/// DCDC2's code for `microvolts`, the next step up; null outside its
/// range.
fn dcdc2Code(microvolts: u32) ?u8 {
    const mv = (microvolts + 999) / 1000;
    if (mv < 500 or mv > 1540) return null;
    if (mv <= 1200) return @intCast((mv - 500 + 9) / 10);
    return @intCast(0x47 + (@max(mv, 1220) - 1220 + 19) / 20);
}

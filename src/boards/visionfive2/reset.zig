// SPDX-License-Identifier: MPL-2.0
//! What the VisionFive 2 needs before its firmware can reset it.
//!
//! OpenSBI resets the board through the AXP15060 power controller, on
//! I2C5 at address 0x36: it reads the controller's register 0x32 and sets
//! its reset bit. Its I2C driver only sets the target address and sends,
//! so the controller has to be set up as U-Boot left it. U-Boot does
//! not leave it so: it holds I2C5 in reset as it starts the kernel, and
//! out of reset the DesignWare controller is in its power-on mode - high
//! speed and 10-bit addresses (IC_CON 0x7F) - which the AXP15060 does not
//! answer. OpenSBI then prints "pmic_ops: cannot read pmic power
//! register" and hangs. Linux sets I2C5 up again for its own driver; the
//! kernel does here, just before the reset: the clock on, the reset
//! released and the controller set up as U-Boot had it (its registers as
//! read on the board): standard mode, 100 kHz.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const system = hardware.system;

/// I2C5, a DesignWare I2C controller.
const I2C5: usize = 0x1205_0000;
const IC_CON = I2C5 + 0x00;
const IC_SS_SCL_HCNT = I2C5 + 0x14;
const IC_SS_SCL_LCNT = I2C5 + 0x18;
const IC_ENABLE = I2C5 + 0x6C;
const IC_SDA_HOLD = I2C5 + 0x7C;

/// Master, standard mode, 7-bit addresses, restarts on, slave off.
const CON_U_BOOT: u32 = 0x63;

/// I2C5 made ready for OpenSBI's reset. Run with interrupts off, as the
/// last thing before the SBI call.
pub fn prepare() void {
    system.clockOn(.sys, system.SYSCLK_I2C5_APB);
    system.releaseReset(.sys, system.SYSRST_I2C5_APB);
    _ = system.waitOutOfReset(.sys, system.SYSRST_I2C5_APB);
    // The controller takes its settings only while it is off.
    reg(IC_ENABLE).* = 0;
    reg(IC_CON).* = CON_U_BOOT;
    reg(IC_SS_SCL_HCNT).* = 0x4A;
    reg(IC_SS_SCL_LCNT).* = 0x16B;
    reg(IC_SDA_HOLD).* = 0x0F;
}

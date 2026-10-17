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

const reg = @import("sdk").hardware.mmio.reg;

/// The system clock and reset generator (SYS CRG).
const SYS_CRG: usize = 0x1302_0000;
/// I2C5's bus clock (clock 143): bit 31 lets it through.
const CLK_I2C5_APB = SYS_CRG + 0x23C;
const CLK_ENABLE: u32 = 1 << 31;
/// The third of the reset words, which holds I2C5's bus reset (reset 81):
/// set in ASSERT holds it, set in STATUS it is released.
const RESET_ASSERT2 = SYS_CRG + 0x300;
const RESET_STATUS2 = SYS_CRG + 0x310;
const RESET_I2C5_APB: u32 = 1 << (81 - 64);

/// I2C5, a DesignWare I2C controller.
const I2C5: usize = 0x1205_0000;
const IC_CON = I2C5 + 0x00;
const IC_SS_SCL_HCNT = I2C5 + 0x14;
const IC_SS_SCL_LCNT = I2C5 + 0x18;
const IC_ENABLE = I2C5 + 0x6C;
const IC_SDA_HOLD = I2C5 + 0x7C;

/// Master, standard mode, 7-bit addresses, restarts on, slave off.
const CON_U_BOOT: u32 = 0x63;

/// How long the reset is waited on to come off: far more than it takes.
const release_spins: u32 = 100_000;

/// I2C5 made ready for OpenSBI's reset. Run with interrupts off, as the
/// last thing before the SBI call.
pub fn prepare() void {
    reg(CLK_I2C5_APB).* |= CLK_ENABLE;
    reg(RESET_ASSERT2).* &= ~RESET_I2C5_APB;
    var spins: u32 = 0;
    while (reg(RESET_STATUS2).* & RESET_I2C5_APB == 0 and spins < release_spins) : (spins += 1) {}
    // The controller takes its settings only while it is off.
    reg(IC_ENABLE).* = 0;
    reg(IC_CON).* = CON_U_BOOT;
    reg(IC_SS_SCL_HCNT).* = 0x4A;
    reg(IC_SS_SCL_LCNT).* = 0x16B;
    reg(IC_SDA_HOLD).* = 0x0F;
}

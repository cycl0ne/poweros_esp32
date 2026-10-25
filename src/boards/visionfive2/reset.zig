// SPDX-License-Identifier: MPL-2.0
//! How the VisionFive 2 resets itself: through the chip's watchdog, and
//! should that not do it, through its firmware.
//!
//! **The watchdog** resets the JH7110 alone, and the board's supplies
//! stay on. OpenSBI's reset turns them all off and on again through the
//! AXP15060 power controller, and on some power supplies the board does
//! not come back from that: "rebooting..." and then nothing, not even the
//! SPL, until the power is off for some seconds - as after a quick press
//! of the power button. The watchdog is StarFive's, at 0x1307_0000: it
//! counts LOAD down at the oscillator's 24 MHz, raises its interrupt at
//! nought and loads the count again, and the second time it reaches
//! nought with the interrupt not cleared it resets the chip. Its registers
//! take writes only once LOCK has the key. The kernel lets its clocks
//! through, releases its resets, loads it with a millisecond and starts
//! it with its reset on (the registers as Linux's starfive-wdt.c has
//! them).
//!
//! **OpenSBI's reset** follows if the chip still runs after a while.
//! OpenSBI resets the board through the AXP15060 on I2C5 at address 0x36:
//! it reads the controller's register 0x32 and sets its reset bit. Its
//! I2C driver only sets the target address and sends, so the controller
//! has to be set up as U-Boot left it. U-Boot does not leave it so: it
//! holds I2C5 in reset as it starts the kernel, and out of reset the
//! DesignWare controller is in its power-on mode - high speed and 10-bit
//! addresses (IC_CON 0x7F) - which the AXP15060 does not answer. OpenSBI
//! then prints "pmic_ops: cannot read pmic power register" and hangs.
//! Linux sets I2C5 up again for its own driver; the kernel does here,
//! just before the reset: the clock on, the reset released and the
//! controller set up as U-Boot had it (its registers as read on the
//! board): standard mode, 100 kHz (`power.bringUp`).

const hardware = @import("sdk").hardware;
const system = hardware.system;
const systimer = hardware.systimer;
const reg = hardware.mmio.reg;
const power = @import("power.zig");

const WDT: usize = 0x1307_0000;
const WDT_LOAD = 0x000;
const WDT_CONTROL = 0x008;
const WDT_INTCLR = 0x00C;
const WDT_LOCK = 0xC00;

/// CONTROL: the count running, its interrupt raised at nought; and the
/// chip reset the second time.
const WDT_ENABLE: u32 = 1 << 0;
const WDT_RESET_ENABLE: u32 = 1 << 1;

/// What LOCK takes before the other registers take writes.
const WDT_UNLOCK_KEY: u32 = 0x1ACC_E551;

/// A millisecond at the oscillator's 24 MHz: the chip reset after two.
const wdt_count: u32 = 24_000;

/// How long the watchdog is given before OpenSBI's reset is tried.
const wdt_patience_us = 100_000;

/// The chip reset through its watchdog; if it still runs after that,
/// I2C5 made ready for OpenSBI's reset. Run with interrupts off, as the
/// last thing before the SBI call.
pub fn reset() void {
    watchdogReset();
    _ = power.bringUp();
}

/// The watchdog started with a millisecond's count and its reset on. It
/// returns only if the chip did not reset in time.
fn watchdogReset() void {
    system.clockOn(.sys, system.SYSCLK_WDT_APB);
    system.clockOn(.sys, system.SYSCLK_WDT_CORE);
    system.releaseReset(.sys, system.SYSRST_WDT_APB);
    system.releaseReset(.sys, system.SYSRST_WDT_CORE);
    if (!system.waitOutOfReset(.sys, system.SYSRST_WDT_APB)) return;
    if (!system.waitOutOfReset(.sys, system.SYSRST_WDT_CORE)) return;
    reg(WDT + WDT_LOCK).* = WDT_UNLOCK_KEY;
    reg(WDT + WDT_CONTROL).* = 0;
    reg(WDT + WDT_INTCLR).* = 1;
    reg(WDT + WDT_LOAD).* = wdt_count;
    reg(WDT + WDT_CONTROL).* = WDT_RESET_ENABLE | WDT_ENABLE;
    systimer.spinUs(wdt_patience_us);
}

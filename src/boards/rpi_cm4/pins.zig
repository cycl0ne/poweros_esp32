// SPDX-License-Identifier: MPL-2.0
//! The console's pins on the Compute Module 4 (`boards.console_pins`):
//! GPIO 14 and 15 - pins 8 and 10 of the IO board's header - given to
//! the PL011, the kernel's raw port.
//!
//! On a module with the wireless chip the firmware gives the PL011 to its
//! Bluetooth (GPIO 30 to 33) and GPIO 14 and 15 to the mini UART, and
//! start4.elf does so after config.txt's `gpio=` lines have been carried
//! out, so the kernel takes the pins back itself, before its first line.
//! The PL011 is on both pairs then; nothing here drives the Bluetooth.
//! Where the module has no wireless chip the pins are the PL011's
//! already, and this changes nothing. The CM4-NANO-B brings out neither.
//!
//! The BCM2711's GPIO block: three bits a pin for its function in
//! GPFSEL0 to GPFSEL5 (ALT0 is 4), and two bits a pin for its pull in
//! GPIO_PUP_PDN_CNTRL_REG0 to 3 (0 none, 1 up, 2 down).

const reg = @import("sdk").hardware.mmio.reg;

const GPIO: usize = 0xFE20_0000;
/// GPIO 10 to 19's functions.
const GPFSEL1: usize = 0x04;
/// GPIO 0 to 15's pulls.
const PUP_PDN_CNTRL_REG0: usize = 0xE4;
const FSEL_ALT0: u32 = 4;
const PULL_NONE: u32 = 0;
const PULL_UP: u32 = 1;

const TXD: u5 = 14;
const RXD: u5 = 15;

/// GPIO 14 sending and 15 receiving for the PL011, the receiving line
/// pulled up as Linux pulls it.
pub fn consolePins() void {
    const fsel = reg(GPIO + GPFSEL1);
    const fsel_shift_tx: u5 = (TXD - 10) * 3;
    const fsel_shift_rx: u5 = (RXD - 10) * 3;
    fsel.* = (fsel.* & ~(@as(u32, 7) << fsel_shift_tx) & ~(@as(u32, 7) << fsel_shift_rx)) |
        (FSEL_ALT0 << fsel_shift_tx) | (FSEL_ALT0 << fsel_shift_rx);
    const pulls = reg(GPIO + PUP_PDN_CNTRL_REG0);
    const pull_shift_tx: u5 = TXD * 2;
    const pull_shift_rx: u5 = RXD * 2;
    pulls.* = (pulls.* & ~(@as(u32, 3) << pull_shift_tx) & ~(@as(u32, 3) << pull_shift_rx)) |
        (PULL_NONE << pull_shift_tx) | (PULL_UP << pull_shift_rx);
}

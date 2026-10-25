// SPDX-License-Identifier: MIT
//! The interrupt sources: the PLIC's, by number, and after them the
//! kernel's alarms on the SBI timer (systimer.zig). Source 0 is none; the
//! JH7110 has 136 after it, QEMU's virt 95. Which device is which source
//! is the board's (its UART's is `uart.console.irq`).

/// One past the highest PLIC source on any of the machines; how many one
/// machine has is its board's to say (`plic.sources`).
pub const INTB_PLIC_COUNT = 137;
/// The alarms: timer.device's micro timer, and its VBLANK.
pub const INTB_ALARM0 = INTB_PLIC_COUNT;
pub const INTB_ALARM1 = INTB_PLIC_COUNT + 1;
pub const INTB_COUNT = INTB_PLIC_COUNT + 2;

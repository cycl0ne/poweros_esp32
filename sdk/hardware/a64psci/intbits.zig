// SPDX-License-Identifier: MIT
//! The interrupt sources: the GIC's interrupt IDs, by number, and after
//! them the kernel's alarms on the generic timer (systimer.zig). IDs 0 to
//! 15 are the software-generated interrupts and 16 to 31 each core's own
//! (the timers'), which the kernel keeps; a device's is a shared one, 32
//! up. The BCM2712's GIC-400 has them up to 319, QEMU's virt up to 287.
//! Which device is which ID is the board's (its UART's is
//! `uart.console.irq`).

/// The first shared interrupt: a device's.
pub const INTB_SPI_FIRST = 32;
/// One past the highest interrupt ID on any of the machines.
pub const INTB_GIC_COUNT = 320;
/// The alarms: timer.device's micro timer, and its VBLANK.
pub const INTB_ALARM0 = INTB_GIC_COUNT;
pub const INTB_ALARM1 = INTB_GIC_COUNT + 1;
pub const INTB_COUNT = INTB_GIC_COUNT + 2;

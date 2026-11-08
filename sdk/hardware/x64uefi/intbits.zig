// SPDX-License-Identifier: MIT
//! The interrupt sources: the machine's interrupt lines, as the firmware's
//! tables number them, and after them the alarms on the kernel's timer
//! (systimer.zig).
//!
//! **A source is not a vector.** The architecture has 256 interrupt
//! vectors, of which the first 32 are the core's own exceptions, and the
//! kernel hands the rest out: a source's vector is where the kernel told
//! the I/O controller to send it (`src/arch/x64uefi/apic.zig`). What a
//! driver asks exec for is the source - the controller's input the line is
//! wired to, which the firmware's tables number from 0 and PCI's interrupt
//! routing names, the "global system interrupt" - so that a driver says
//! what the machine says and not what this kernel happened to choose.
//!
//! The old parts of a PC are on the first sixteen of those inputs, and
//! those sixteen are the ones with fixed meanings: the console's is 4.
//! Which line a device is on is the board's or the tables' (its UART's is
//! `uart.console.irq`).

/// One past the highest interrupt line: the inputs of the machine's I/O
/// controllers, with room for a machine that has more than one. How many
/// one machine has is its own to say, from the firmware's tables.
pub const INTB_GSI_COUNT = 64;
/// The first source a PCI function's message is given, and how many of
/// them the kernel hands out: a message carries a vector rather than a
/// line, so these are the kernel's numbering alone.
pub const INTB_MSI_FIRST = INTB_GSI_COUNT;
pub const INTB_MSI_COUNT = 64;
/// One past the highest source an interrupt controller routes.
pub const INTB_SOURCE_COUNT = INTB_MSI_FIRST + INTB_MSI_COUNT;
/// The alarms: timer.device's micro timer, and its VBLANK.
pub const INTB_ALARM0 = INTB_SOURCE_COUNT;
pub const INTB_ALARM1 = INTB_SOURCE_COUNT + 1;
pub const INTB_COUNT = INTB_SOURCE_COUNT + 2;

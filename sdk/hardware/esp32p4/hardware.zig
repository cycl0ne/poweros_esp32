// SPDX-License-Identifier: MIT
//! The ESP32-P4's hardware, by name: what `sdk.hardware` is on this chip.
//! What the first kernel needs - its console on UART0 and the chip's own
//! USB port; the rest of the chip follows as the drivers come.

pub const intbits = @import("intbits.zig");
/// A register by its address.
pub const mmio = @import("mmio.zig");
/// The peripherals' base addresses.
pub const map = @import("map.zig");
/// The chip's reset.
pub const system = @import("system.zig");
/// Each peripheral's registers and their bits, by the manual's names.
pub const uart = @import("uart.zig");
pub const usb_serial_jtag = @import("usb_serial_jtag.zig");
pub const wdt = @import("wdt.zig");

/// The crystal: the clock the chip starts on.
pub const XTAL_HZ: u32 = 40_000_000;
/// The clock the CPU runs at: the crystal's, as the ROM leaves it, until
/// the kernel sets its PLL up.
pub const CPU_HZ: u32 = XTAL_HZ;
/// A line of the L1 data cache, in bytes.
pub const DCACHE_LINE_SIZE = 64;

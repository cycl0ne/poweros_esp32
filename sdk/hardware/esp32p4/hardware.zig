// SPDX-License-Identifier: MIT
//! The ESP32-P4's hardware, by name: what `sdk.hardware` is on this chip.

pub const intbits = @import("intbits.zig");
/// The pads and the GPIO matrix: which signal is on which pad. Here so a
/// driver on the disk routes its pads the same way the kernel's do.
pub const gpio = @import("gpio.zig");
/// A register by its address.
pub const mmio = @import("mmio.zig");
/// The peripherals' base addresses.
pub const map = @import("map.zig");
/// The peripherals' clocks and resets, and the chip's reset.
pub const system = @import("system.zig");
/// The GPIO matrix's peripheral signal numbers.
pub const signals = @import("signals.zig");
/// Each peripheral's registers and their bits, by the manual's names.
pub const uart = @import("uart.zig");
pub const usb_serial_jtag = @import("usb_serial_jtag.zig");
pub const i2c = @import("i2c.zig");
pub const systimer = @import("systimer.zig");
/// The two general DMA engines' channels (AHB and AXI), for
/// dma.resource and the drivers that drive a channel directly.
pub const gdma = @import("gdma.zig");
/// The general-purpose SPI controllers (SPI2, SPI3) as bus masters.
pub const gpspi = @import("gpspi.zig");
pub const wdt = @import("wdt.zig");
/// The core's cycle counter.
pub const cpu = @import("cpu.zig");
/// The random number generator.
pub const rng = @import("rng.zig");
/// The caches, and the controller's entry points in the ROM.
pub const cache = @import("cache.zig");
/// The four adjustable LDO regulators a board feeds its parts from.
pub const ldo = @import("ldo.zig");

/// The crystal: the clock the chip starts on.
pub const XTAL_HZ: u32 = 40_000_000;
/// The clock the CPU runs at: the crystal's, as the ROM leaves it, until
/// the kernel sets its PLL up.
pub const CPU_HZ: u32 = XTAL_HZ;
/// A line of the L1 data cache, in bytes.
pub const DCACHE_LINE_SIZE = 64;

// SPDX-License-Identifier: MIT
//! The chip's hardware, by name (include/hardware).

pub const intbits = @import("intbits.zig");
/// The pads and the GPIO matrix: which signal is on which pad. Here so a
/// driver on the disk routes its pads the same way the kernel's do.
pub const gpio = @import("gpio.zig");
/// A register by its address.
pub const mmio = @import("mmio.zig");
/// The peripherals' base addresses.
pub const map = @import("map.zig");
/// The peripherals' bus clocks and resets.
pub const system = @import("system.zig");
/// The GPIO matrix's peripheral signal numbers.
pub const signals = @import("signals.zig");
/// Each peripheral's registers and their bits, by the manual's names.
pub const uart = @import("uart.zig");
pub const usb_serial_jtag = @import("usb_serial_jtag.zig");
pub const i2c = @import("i2c.zig");
pub const systimer = @import("systimer.zig");
pub const rtc_cntl = @import("rtc_cntl.zig");
/// The general DMA engine's channels, for dma.resource and the drivers
/// that drive a channel directly.
pub const gdma = @import("gdma.zig");
pub const wdt = @import("wdt.zig");
/// The core's cycle counter.
pub const cpu = @import("cpu.zig");
/// The emulator's virtual display, with its window's pointer and keys.
pub const qemu_rgb = @import("qemu_rgb.zig");

/// The crystal: the clock the chip starts on, and the UARTs' clock.
pub const XTAL_HZ: u32 = 40_000_000;
/// The clock the boot sets the CPU to, and so what CCOUNT counts at.
pub const CPU_HZ: u32 = 240_000_000;

/// A data cache line, in bytes: the unit the cache moves external memory
/// in, and so what a buffer a DMA engine reaches through the cache should
/// start and end on. Anything else sharing its first or last line and
/// written during the transfer wins over the transfer's data.
pub const DCACHE_LINE_SIZE = 64;

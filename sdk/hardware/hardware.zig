// SPDX-License-Identifier: MIT
//! The chip's hardware, by name (include/hardware): a folder per chip -
//! `esp32s3/`, `esp32p4/` - each with its peripherals' base addresses,
//! registers and bits by the manual's names, picked by what the code is
//! built for: RISC-V is the ESP32-P4, Xtensa the ESP32-S3, and the host
//! tests see the S3's. The names below are the same on every chip; one a
//! chip does not have yet is an error only where it is used.

const builtin = @import("builtin");

/// The chips there are.
pub const Chip = enum { esp32s3, esp32p4 };

/// The chip this code is built for.
pub const chip: Chip = if (builtin.cpu.arch == .riscv32) .esp32p4 else .esp32s3;

/// The chip's own folder.
const own = switch (chip) {
    .esp32s3 => @import("esp32s3/hardware.zig"),
    .esp32p4 => @import("esp32p4/hardware.zig"),
};

/// The interrupt sources, by number.
pub const intbits = own.intbits;
/// The pads and the GPIO matrix: which signal is on which pad. Here so a
/// driver on the disk routes its pads the same way the kernel's do.
pub const gpio = own.gpio;
/// A register by its address.
pub const mmio = own.mmio;
/// The peripherals' base addresses.
pub const map = own.map;
/// The peripherals' bus clocks and resets.
pub const system = own.system;
/// The GPIO matrix's peripheral signal numbers.
pub const signals = own.signals;
/// Each peripheral's registers and their bits, by the manual's names.
pub const uart = own.uart;
pub const usb_serial_jtag = own.usb_serial_jtag;
pub const i2c = own.i2c;
pub const systimer = own.systimer;
pub const rtc_cntl = own.rtc_cntl;
/// The general DMA engine's channels, for dma.resource and the drivers
/// that drive a channel directly. The ESP32-P4 has two engines, AHB and
/// AXI, so its calls name the engine as well as the channel.
pub const gdma = own.gdma;
/// The 2D-DMA's channels, for their owners once dma.resource has handed
/// them out: the ESP32-P4's. The ESP32-S3 has none, so there it is empty.
pub const dma2d = if (chip == .esp32p4) own.dma2d else struct {};
/// The general-purpose SPI controllers (SPI2, SPI3) as bus masters.
pub const gpspi = own.gpspi;
pub const wdt = own.wdt;
/// The core's cycle counter.
pub const cpu = own.cpu;
/// The random number generator.
pub const rng = own.rng;
/// The caches, and the controller's entry points in the ROM: the
/// ESP32-P4's. exec drives the ESP32-S3's itself, so there it is empty.
pub const cache = if (chip == .esp32p4) own.cache else struct {};
/// The emulator's virtual display, with its window's pointer and keys.
pub const qemu_rgb = own.qemu_rgb;
/// The adjustable LDO regulators a board feeds its parts from: the
/// ESP32-P4's. The ESP32-S3 has none, so there it is empty.
pub const ldo = if (chip == .esp32p4) own.ldo else struct {};

/// The crystal: the clock the chip starts on, and the UARTs' clock.
pub const XTAL_HZ = own.XTAL_HZ;
/// The clock the boot sets the CPU to, and so what the cycle counter
/// counts at.
pub const CPU_HZ = own.CPU_HZ;
/// A data cache line, in bytes: the unit the cache moves external memory
/// in, and so what a buffer a DMA engine reaches through the cache should
/// start and end on. Anything else sharing its first or last line and
/// written during the transfer wins over the transfer's data.
pub const DCACHE_LINE_SIZE = own.DCACHE_LINE_SIZE;

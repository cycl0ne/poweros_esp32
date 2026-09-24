// SPDX-License-Identifier: MIT
//! Where the ESP32-S3's peripherals are: each block's base address on the
//! data bus, by the name the chip's manual gives it. A driver adds its
//! register offsets to these; nothing else in the system writes one of
//! these numbers down.
//!
//! Only addresses. Which driver may use a block is not decided here - a
//! block belongs to the device, library or resource that drives it.

pub const UART0: usize = 0x6000_0000;
pub const SPI1: usize = 0x6000_2000;
pub const SPI0: usize = 0x6000_3000;
pub const GPIO: usize = 0x6000_4000;
pub const RTC_CNTL: usize = 0x6000_8000;
pub const IO_MUX: usize = 0x6000_9000;
pub const I2S0: usize = 0x6000_F000;
pub const UART1: usize = 0x6001_0000;
pub const I2C0: usize = 0x6001_3000;
pub const TIMG0: usize = 0x6001_F000;
pub const TIMG1: usize = 0x6002_0000;
pub const SYSTIMER: usize = 0x6002_3000;
pub const SPI2: usize = 0x6002_4000;
pub const I2C1: usize = 0x6002_7000;
pub const SDMMC: usize = 0x6002_8000;
pub const UART2: usize = 0x6002_E000;
pub const USB_SERIAL_JTAG: usize = 0x6003_8000;
pub const GDMA: usize = 0x6003_F000;
pub const LCD_CAM: usize = 0x6004_1000;
/// SYSTEM: the peripherals' bus clocks and resets (`system.zig`).
pub const SYSTEM: usize = 0x600C_0000;
pub const INTERRUPT_MATRIX: usize = 0x600C_2000;
/// The flash and PSRAM caches.
pub const EXTMEM: usize = 0x600C_4000;
/// The MMU table that maps flash and PSRAM into the address space.
pub const MMU_TABLE: usize = 0x600C_5000;

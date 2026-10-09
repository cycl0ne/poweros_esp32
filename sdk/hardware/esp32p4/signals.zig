// SPDX-License-Identifier: MIT
//! The GPIO matrix's peripheral signals: the numbers `gpio.connectOut`
//! and `gpio.connectIn` put a peripheral's line onto a pad by. Names and
//! numbers are ESP-IDF's (soc/esp32p4/include/soc/gpio_sig_map.h),
//! without its `_PAD_IN_IDX` / `_PAD_OUT_IDX`; where the same number is an
//! input and an output, one name serves both.

// UART0 and UART1: a pair per number, input first.
pub const UART0_RXD: u32 = 10;
pub const UART0_TXD: u32 = 10;
pub const UART0_CTS: u32 = 11;
pub const UART0_RTS: u32 = 11;
pub const UART1_RXD: u32 = 13;
pub const UART1_TXD: u32 = 13;
pub const UART1_CTS: u32 = 14;
pub const UART1_RTS: u32 = 14;

// I2S0, as a transmitter.
pub const I2S0_O_BCK: u32 = 25;
pub const I2S0_MCLK: u32 = 26;
pub const I2S0_O_WS: u32 = 27;
pub const I2S0_O_SD: u32 = 28;

// SPI3, which has no more data lines than these.
pub const SPI3_CK: u32 = 47;
pub const SPI3_Q: u32 = 48;
pub const SPI3_D: u32 = 49;
pub const SPI3_HOLD: u32 = 50;
pub const SPI3_WP: u32 = 51;
pub const SPI3_CS: u32 = 52;

// SPI2, with eight data lines: SPI2_D, SPI2_Q, SPI2_WP, SPI2_HOLD, then
// SPI2_IO4 to SPI2_IO7.
pub const SPI2_CK: u32 = 53;
pub const SPI2_Q: u32 = 54;
pub const SPI2_D: u32 = 55;
pub const SPI2_HOLD: u32 = 56;
pub const SPI2_WP: u32 = 57;
pub const SPI2_IO4: u32 = 58;
pub const SPI2_CS: u32 = 62;

// The two HP I2C controllers.
pub const I2C0_SCL: u32 = 68;
pub const I2C0_SDA: u32 = 69;
pub const I2C1_SCL: u32 = 70;
pub const I2C1_SDA: u32 = 71;

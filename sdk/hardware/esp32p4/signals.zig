// SPDX-License-Identifier: MIT
//! The GPIO matrix's peripheral signals: the numbers `gpio.connectOut`
//! and `gpio.connectIn` put a peripheral's line onto a pad by. Names and
//! numbers are ESP-IDF's (soc/esp32p4/include/soc/gpio_sig_map.h),
//! without its `_PAD_IN_IDX` / `_PAD_OUT_IDX`; where the same number is an
//! input and an output, one name serves both.

// The five UARTs: a pair per number, input first.
pub const UART0_RXD: u32 = 10;
pub const UART0_TXD: u32 = 10;
pub const UART0_CTS: u32 = 11;
pub const UART0_RTS: u32 = 11;
pub const UART1_RXD: u32 = 13;
pub const UART1_TXD: u32 = 13;
pub const UART1_CTS: u32 = 14;
pub const UART1_RTS: u32 = 14;
pub const UART2_RXD: u32 = 16;
pub const UART2_TXD: u32 = 16;
pub const UART2_CTS: u32 = 17;
pub const UART2_RTS: u32 = 17;
pub const UART3_RXD: u32 = 19;
pub const UART3_TXD: u32 = 19;
pub const UART3_CTS: u32 = 20;
pub const UART3_RTS: u32 = 20;
pub const UART4_RXD: u32 = 22;
pub const UART4_TXD: u32 = 22;
pub const UART4_CTS: u32 = 23;
pub const UART4_RTS: u32 = 23;

// I2S0, as a transmitter.
pub const I2S0_O_BCK: u32 = 25;
pub const I2S0_MCLK: u32 = 26;
pub const I2S0_O_WS: u32 = 27;
pub const I2S0_O_SD: u32 = 28;

// I2S1, as a transmitter, and the receiver's data in.
pub const I2S1_O_BCK: u32 = 31;
pub const I2S1_MCLK: u32 = 32;
pub const I2S1_O_WS: u32 = 33;
pub const I2S1_O_SD: u32 = 34;
pub const I2S1_I_SD: u32 = 34;

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

// The SD/MMC host's first slot, whose lines are the IO_MUX's own on
// GPIO39 to 44; only its card-detect and write-protect inputs come
// through the matrix.
pub const SD_CARD_DETECT_N_1: u32 = 126;
pub const SD_CARD_WRITE_PRT_1: u32 = 130;

// The full-speed USB OTG controller's session inputs, which say which end
// of a cable it is: as a host, the A end with a valid VBUS.
pub const USB_OTG11_IDDIG: u32 = 110;
pub const USB_OTG11_AVALID: u32 = 111;
pub const USB_SRP_BVALID: u32 = 112;
pub const USB_OTG11_VBUSVALID: u32 = 113;

// SPDX-License-Identifier: MIT
//! The GPIO matrix's peripheral signals: the numbers `gpio.connectOut`
//! and `gpio.connectIn` put a peripheral's line onto a pad by. The chip
//! has no fixed pads for these peripherals, so the matrix is the only
//! way to them. Names and numbers are ESP-IDF's (`gpio_sig_map.h`),
//! without its `_IDX`; where the same number is an input and an output,
//! one name serves both.

// The three UARTs: a pair per number, input first.
pub const U0RXD_IN: u32 = 12;
pub const U0TXD_OUT: u32 = 12;
pub const U1RXD_IN: u32 = 15;
pub const U1TXD_OUT: u32 = 15;
pub const U2RXD_IN: u32 = 18;
pub const U2TXD_OUT: u32 = 18;

// I2S0, as a transmitter.
pub const I2S0O_BCK: u32 = 22;
pub const I2S0_MCLK: u32 = 23;
pub const I2S0O_WS: u32 = 24;
pub const I2S0O_SD: u32 = 25;

// The two I2C controllers.
pub const I2CEXT0_SCL: u32 = 89;
pub const I2CEXT0_SDA: u32 = 90;
pub const I2CEXT1_SCL: u32 = 91;
pub const I2CEXT1_SDA: u32 = 92;

// SPI2 (FSPI).
pub const FSPICLK: u32 = 101;
pub const FSPIQ: u32 = 102;
pub const FSPID: u32 = 103;
pub const FSPIHD: u32 = 104;
pub const FSPIWP: u32 = 105;
pub const FSPICS0: u32 = 110;

// SPI3, which has no more lines than these.
pub const SPI3_CLK: u32 = 66;
pub const SPI3_Q: u32 = 67;
pub const SPI3_D: u32 = 68;
pub const SPI3_HD: u32 = 69;
pub const SPI3_WP: u32 = 70;
pub const SPI3_CS0: u32 = 71;

// LCD_CAM, as an RGB panel's controller. The data lines are
// LCD_DATA_OUT0 up, one after another.
pub const LCD_DATA_OUT0: u32 = 133;
pub const LCD_H_ENABLE: u32 = 150;
pub const LCD_H_SYNC: u32 = 151;
pub const LCD_V_SYNC: u32 = 152;
pub const LCD_PCLK: u32 = 154;

// The SD/MMC host's first slot. The data lines are SDHOST_CDATA_10 up.
pub const SDHOST_CCLK_1: u32 = 172;
pub const SDHOST_CCMD_1: u32 = 178;
pub const SDHOST_CDATA_10: u32 = 180;
pub const SDHOST_CDATA_11: u32 = 181;
pub const SDHOST_CDATA_12: u32 = 182;
pub const SDHOST_CDATA_13: u32 = 183;
pub const SDHOST_CARD_DETECT_N_1: u32 = 194;
pub const SDHOST_CARD_WRITE_PRT_1: u32 = 196;

// The USB OTG controller's session inputs, which say which end of a cable
// it is: as a host, the A end with a valid VBUS.
pub const USB_OTG_IDDIG_IN: u32 = 58;
pub const USB_OTG_AVALID_IN: u32 = 59;
pub const USB_SRP_BVALID_IN: u32 = 60;
pub const USB_OTG_VBUSVALID_IN: u32 = 61;

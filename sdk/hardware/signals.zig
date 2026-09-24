// SPDX-License-Identifier: MIT
//! The GPIO matrix's peripheral signals: the numbers `gpio.connectOut`
//! and `gpio.connectIn` put a peripheral's line onto a pad by. The chip
//! has no fixed pads for these peripherals, so the matrix is the only
//! way to them. Names and numbers are ESP-IDF's (`gpio_sig_map.h`),
//! without its `_IDX`; where the same number is an input and an output,
//! one name serves both.

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

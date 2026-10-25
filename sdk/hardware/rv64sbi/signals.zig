// SPDX-License-Identifier: MIT
//! The JH7110's signals as its system pin controller crosses them onto
//! the pads (`gpio.zig`): what drives a pad (GPOUT), what enables its
//! driver (GPOEN), and which of the chip's inputs listens to a pad (GPI).
//! The numbers are Linux's (arch/riscv/boot/dts/starfive/jh7110-pinfunc.h),
//! by its names - the ones the drivers here route.

/// What drives a pad: always low, always high, or a peripheral's line.
pub const GPOUT_LOW: u8 = 0;
pub const GPOUT_HIGH: u8 = 1;
pub const GPOUT_SYS_HDMI_DDC_SCL: u8 = 11;
pub const GPOUT_SYS_HDMI_DDC_SDA: u8 = 12;
pub const GPOUT_SYS_PWMDAC_LEFT: u8 = 28;
pub const GPOUT_SYS_PWMDAC_RIGHT: u8 = 29;
pub const GPOUT_SYS_SDIO1_CLK: u8 = 55;
pub const GPOUT_SYS_SDIO1_CMD: u8 = 57;
/// DATA0 to DATA3 follow one another.
pub const GPOUT_SYS_SDIO1_DATA0: u8 = 58;

/// What enables a pad's driver: always, never, or a peripheral's line.
pub const GPOEN_ENABLE: u8 = 0;
pub const GPOEN_DISABLE: u8 = 1;
pub const GPOEN_SYS_HDMI_DDC_SCL: u8 = 3;
pub const GPOEN_SYS_HDMI_DDC_SDA: u8 = 4;
pub const GPOEN_SYS_SDIO1_CMD: u8 = 19;
/// DATA0 to DATA3 follow one another.
pub const GPOEN_SYS_SDIO1_DATA0: u8 = 20;

/// The chip's inputs.
pub const GPI_SYS_HDMI_DDC_SCL: u8 = 6;
pub const GPI_SYS_HDMI_DDC_SDA: u8 = 7;
pub const GPI_SYS_HDMI_HPD: u8 = 8;
pub const GPI_SYS_MCLK_EXT: u8 = 30;
pub const GPI_SYS_SDIO1_CD: u8 = 41;
pub const GPI_SYS_SDIO1_WP: u8 = 43;
pub const GPI_SYS_SDIO1_CMD: u8 = 44;
/// DATA0 to DATA3 follow one another.
pub const GPI_SYS_SDIO1_DATA0: u8 = 45;

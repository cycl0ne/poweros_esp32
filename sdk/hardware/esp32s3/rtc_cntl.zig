// SPDX-License-Identifier: MIT
//! RTC_CNTL's registers that the system uses: the chip's software reset,
//! the software stall of core 1, and the switch that gives the USB port
//! to a controller.
//!
//! Only names and numbers: nothing here touches the hardware.

const map = @import("map.zig");

pub const OPTIONS0: usize = map.RTC_CNTL + 0x00;
/// The second half of each core's software stall.
pub const SW_CPU_STALL: usize = map.RTC_CNTL + 0xBC;

// OPTIONS0
/// Resets the whole chip, both cores and every peripheral.
pub const OPTIONS0_SW_SYS_RST: u32 = 1 << 31;
/// Core 1's software stall, with SW_CPU_STALL's field: stalled while the
/// two hold 0x86 between them, so clearing either lets it run.
pub const OPTIONS0_SW_STALL_APPCPU_C0: u32 = 0x3 << 0;
// SW_CPU_STALL
pub const SW_STALL_APPCPU_C1: u32 = 0x3F << 20;

/// USB_CONF: which controller the chip's USB port is given to, and the
/// port's own settings while USB-Serial-JTAG has it.
pub const USB_CONF: usize = map.RTC_CNTL + 0x120;
/// The choice below counts; clear, the eFuse's does (USB-Serial-JTAG, as
/// the chip starts).
pub const USB_CONF_SW_HW_USB_PHY_SEL: u32 = 1 << 20;
/// Set: the port is the USB OTG controller's (USB_WRAP); clear:
/// USB-Serial-JTAG's.
pub const USB_CONF_SW_USB_PHY_SEL: u32 = 1 << 19;

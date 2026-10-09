// SPDX-License-Identifier: MIT
//! The watchdogs' registers: RTC_CNTL's watchdog and super watchdog, and
//! the watchdog (MWDT) of each timer group. The boot turns them all off
//! (the boot ROM leaves some armed); watchdog.resource runs TIMG0's.
//!
//! Only names and numbers: nothing here touches the hardware.

const map = @import("map.zig");

/// Written to a WPROTECT register, it lets the watchdog's others be
/// written; anything else locks them again.
pub const WDT_KEY: u32 = 0x50D83AA1;
/// The same, for the super watchdog.
pub const SWD_KEY: u32 = 0x8F1D312A;

// RTC_CNTL's watchdog and super watchdog.
pub const RTC_WDT_CONFIG0: usize = map.RTC_CNTL + 0x98;
pub const RTC_WDT_WPROTECT: usize = map.RTC_CNTL + 0xB0;
pub const RTC_SWD_CONF: usize = map.RTC_CNTL + 0xB4;
pub const RTC_SWD_WPROTECT: usize = map.RTC_CNTL + 0xB8;
/// The super watchdog cannot be turned off; this has it feed itself.
pub const SWD_AUTO_FEED_EN: u32 = 1 << 31;

/// A timer group's registers, by its number (0-1).
pub inline fn timgBase(n: u1) usize {
    return if (n == 0) map.TIMG0 else map.TIMG1;
}

// A timer group's MWDT, as offsets from the group's base.
pub const TIMG_WDT_CONFIG0 = 0x48;
pub const TIMG_WDT_CONFIG1 = 0x4C;
pub const TIMG_WDT_CONFIG2 = 0x50;
pub const TIMG_WDT_FEED = 0x60;
pub const TIMG_WDT_WPROTECT = 0x64;

// CONFIG0
pub const WDT_EN: u32 = 1 << 31;
/// What stage 0 does when its time is up (bits 29-30).
pub const WDT_STG0_SHIFT = 29;
/// PROCPU_RESET_EN: lets a "reset CPU" stage reset core 0. The S3's MWDT
/// resets only core 0; bit 12 (APPCPU_RESET_EN) is reserved.
pub const WDT_PROCPU_RESET_EN: u32 = 1 << 13;
/// SYS_RESET_LENGTH and CPU_RESET_LENGTH at their longest, 3.2 us.
pub const WDT_RESET_LENGTHS: u32 = 7 << 15 | 7 << 18;
// CONFIG1: the prescaler on the 80 MHz APB clock (bits 16-31).
pub const WDT_CLK_PRESCALE_SHIFT = 16;

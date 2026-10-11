// SPDX-License-Identifier: MIT
//! The watchdogs the ROM leaves running: the two timer groups' (MWDT0,
//! MWDT1), the LP watchdog (LP_WDT), and the super watchdog, which cannot
//! be switched off but can be told to feed itself. Each block is
//! write-protected: its key into WPROTECT first, 0 after.

const map = @import("map.zig");

/// The key that opens a watchdog's registers, the same for all of them.
pub const WDT_KEY: u32 = 0x50D83AA1;
pub const SWD_KEY: u32 = 0x50D83AA1;

// The LP watchdog and the super watchdog, in the LP_WDT block.
pub const LP_WDT_CONFIG0: usize = map.LP_WDT + 0x00;
pub const LP_WDT_WPROTECT: usize = map.LP_WDT + 0x18;
pub const LP_WDT_SWD_CONFIG: usize = map.LP_WDT + 0x1C;
pub const LP_WDT_SWD_WPROTECT: usize = map.LP_WDT + 0x20;
/// SWD_CONFIG: the super watchdog feeds itself.
pub const SWD_AUTO_FEED_EN: u32 = 1 << 18;

/// A timer group's base, by its number (0, 1).
pub fn timgBase(n: u1) usize {
    return if (n == 0) map.TIMG0 else map.TIMG1;
}

// A timer group's watchdog (MWDT), as offsets from the group's base: the
// ESP32-S3's layout.
pub const TIMG_WDT_CONFIG0 = 0x48;
pub const TIMG_WDT_CONFIG1 = 0x4C;
pub const TIMG_WDT_CONFIG2 = 0x50;
pub const TIMG_WDT_FEED = 0x60;
pub const TIMG_WDT_WPROTECT = 0x64;

// CONFIG0
pub const WDT_EN: u32 = 1 << 31;
/// What stage 0 does when its time is up (bits 29-30).
pub const WDT_STG0_SHIFT = 29;
/// PROCPU_RESET_EN: lets a "reset CPU" stage reset core 0.
pub const WDT_PROCPU_RESET_EN: u32 = 1 << 13;
/// SYS_RESET_LENGTH and CPU_RESET_LENGTH at their longest.
pub const WDT_RESET_LENGTHS: u32 = 7 << 15 | 7 << 18;
/// CONF_UPDATE_EN: what was written to CONFIG0-2 taken over; the bit
/// clears itself.
pub const WDT_CONF_UPDATE_EN: u32 = 1 << 22;
// CONFIG1: the prescaler (bits 16-31) on the watchdog's clock.
pub const WDT_CLK_PRESCALE_SHIFT = 16;
/// The clock a timer group's watchdog counts: the crystal, HP_SYS_CLKRST's
/// default for it.
pub const TIMG_WDT_CLOCK_HZ: u32 = 40_000_000;

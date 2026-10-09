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

// A timer group's watchdog, as offsets from the group's base.
pub const TIMG_WDT_CONFIG0 = 0x48;
pub const TIMG_WDT_WPROTECT = 0x64;

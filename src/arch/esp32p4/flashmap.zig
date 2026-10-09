// SPDX-License-Identifier: MPL-2.0
//! The flash, mapped one to one at 0x40000000 through the caches: flash
//! byte n is at 0x40000000 + n. The kernel's code and constants (the
//! flash part, kernel.ld) run there in place, and so can anything else
//! the flash holds be read.
//!
//! The ROM loads only the RAM part. `map`, which runs from it before any
//! code in flash, turns the L2 cache off, points the flash MMU's first
//! entries at the flash's pages - entry n at page n, 64 KiB each - and
//! clears the rest, turns the cache on again, and drops whatever the L1
//! caches held of the window from the ROM's own use of it. As ESP-IDF's
//! bootloader does before it starts an application
//! (bootloader_utility.c's set_cache_and_start_app).

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const cache = hardware.cache;

/// The flash MMU's registers in FLASH_SPI0: the entry to write, then its
/// value - the flash page, and valid.
const mmu_item_index = hardware.map.FLASH_SPI0 + 0x380;
const mmu_item_content = hardware.map.FLASH_SPI0 + 0x37C;
const mmu_flash_valid: u32 = 1 << 12;
const mmu_entries = 1024;
const page_size = 0x1_0000;

/// The L2 cache off and on again (autoload on), through the ROM.
const Cache_Disable_L2_Cache: *const fn () callconv(.c) void = @ptrFromInt(0x4FC0_0500);
const Cache_Enable_L2_Cache: *const fn (autoload: u32) callconv(.c) void = @ptrFromInt(0x4FC0_0504);
const autoload: u32 = 1 << 0;

/// The whole flash of `flash_size` bytes at 0x40000000. From the RAM
/// part, before anything in flash runs.
pub fn map(flash_size: u32) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const pages = flash_size / page_size;
    Cache_Disable_L2_Cache();
    var entry: u32 = 0;
    while (entry < mmu_entries) : (entry += 1) {
        reg(mmu_item_index).* = entry;
        reg(mmu_item_content).* = if (entry < pages) entry | mmu_flash_valid else 0;
    }
    Cache_Enable_L2_Cache(autoload);
    _ = cache.Cache_Invalidate_Addr(cache.MAP_L1_ICACHES | cache.MAP_L1_DCACHE, hardware.map.FLASH_START, flash_size);
}

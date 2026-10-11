// SPDX-License-Identifier: MIT
//! The caches and the controller's entry points in the chip's ROM. Each
//! core has an L1 instruction cache of its own; both share the L1 data
//! cache, which is in front of L2MEM as well as of flash and PSRAM, and
//! the L2 cache in front of flash and PSRAM. A call names the caches it is
//! for with a `map` of the bits below. Code and data share one address
//! space: a line of flash or PSRAM has the same address on both paths.
//!
//! The entry points go through the ROM's table, which is at the same place
//! in every revision's ROM. From ESP-IDF v6.1's esp_rom esp32p4.rom.ld and
//! rom/cache.h.
//!
//! **A write-back is the chip's own, not the ROM's**: the controller can
//! lose a sync, so a write-back is started and waited for twice, as
//! ESP-IDF's patch of the ROM's routines does
//! (esp_rom_cache_writeback_esp32p4_esp32s31.c). A lost one leaves dirty
//! lines in the cache: a DMA engine reads what was there before, and code
//! just loaded is fetched as whatever the memory held.

const map = @import("map.zig");
const mmio = @import("mmio.zig");

pub const MAP_L1_ICACHE_0: u32 = 1 << 0;
pub const MAP_L1_ICACHE_1: u32 = 1 << 1;
pub const MAP_L1_DCACHE: u32 = 1 << 4;
pub const MAP_L2_CACHE: u32 = 1 << 5;
/// Both cores' instruction caches.
pub const MAP_L1_ICACHES: u32 = MAP_L1_ICACHE_0 | MAP_L1_ICACHE_1;
/// Everything that holds data a write may have left dirty.
pub const MAP_DATA: u32 = MAP_L1_DCACHE | MAP_L2_CACHE;

/// The addresses behind the data cache: flash and PSRAM through both
/// levels, L2MEM through the first.
pub const CACHED_START: usize = map.FLASH_START;
pub const CACHED_END: usize = map.DRAM_END;

/// `size` bytes at `addr` invalidated in the caches `map` names.
pub const Cache_Invalidate_Addr: *const fn (cache_map: u32, addr: u32, size: u32) callconv(.c) i32 = @ptrFromInt(0x4FC0_03E4);
/// The dirty lines of `size` bytes at `addr` written back from the caches
/// `map` names.
pub const Cache_WriteBack_Addr: *const fn (cache_map: u32, addr: u32, size: u32) callconv(.c) i32 = &writeBackAddr;
/// The whole of the caches `map` names invalidated.
pub const Cache_Invalidate_All: *const fn (cache_map: u32) callconv(.c) i32 = @ptrFromInt(0x4FC0_0404);
/// The whole of the caches `map` names written back.
pub const Cache_WriteBack_All: *const fn (cache_map: u32) callconv(.c) i32 = &writeBackAll;

/// The controller's sync operation: the caches, the range (0 and 0 for
/// all of it), what to do, and its end.
pub const SYNC_CTRL: usize = map.CACHE + 0x98;
pub const SYNC_MAP: usize = map.CACHE + 0x9C;
pub const SYNC_ADDR: usize = map.CACHE + 0xA0;
pub const SYNC_SIZE: usize = map.CACHE + 0xA4;
pub const SYNC_WRITEBACK: u32 = 1 << 2;
pub const SYNC_DONE: u32 = 1 << 4;
/// The longest line either level has (the L2's may be 128 bytes): a range
/// rounded out to it covers whole lines of both.
const longest_line = 128;

/// A write-back of the caches `cache_map` names over the range, run to
/// its end twice.
pub inline fn syncWriteBack(cache_map: u32, addr: u32, size: u32) void {
    mmio.reg(SYNC_MAP).* = cache_map;
    mmio.reg(SYNC_ADDR).* = addr;
    mmio.reg(SYNC_SIZE).* = size;
    for (0..2) |_| {
        mmio.reg(SYNC_CTRL).* = SYNC_WRITEBACK;
        while (mmio.reg(SYNC_CTRL).* & SYNC_DONE == 0) {}
    }
}

fn writeBackAddr(cache_map: u32, addr: u32, size: u32) callconv(.c) i32 {
    if (cache_map & MAP_DATA == 0 or cache_map & MAP_L1_ICACHES != 0) return -1;
    const start = addr & ~@as(u32, longest_line - 1);
    const end = (addr + size + longest_line - 1) & ~@as(u32, longest_line - 1);
    syncWriteBack(cache_map, start, end - start);
    return 0;
}

fn writeBackAll(cache_map: u32) callconv(.c) i32 {
    if (cache_map & MAP_DATA == 0 or cache_map & MAP_L1_ICACHES != 0) return -1;
    syncWriteBack(cache_map, 0, 0);
    return 0;
}

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

const map = @import("map.zig");

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
pub const Cache_WriteBack_Addr: *const fn (cache_map: u32, addr: u32, size: u32) callconv(.c) i32 = @ptrFromInt(0x4FC0_03F4);
/// The whole of the caches `map` names invalidated.
pub const Cache_Invalidate_All: *const fn (cache_map: u32) callconv(.c) i32 = @ptrFromInt(0x4FC0_0404);
/// The whole of the caches `map` names written back.
pub const Cache_WriteBack_All: *const fn (cache_map: u32) callconv(.c) i32 = @ptrFromInt(0x4FC0_0414);

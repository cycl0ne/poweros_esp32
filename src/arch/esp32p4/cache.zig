// SPDX-License-Identifier: MPL-2.0
//! The data caches written back for DMA: what exec's cache calls
//! (src/rom/libs/exec/cache/_cache.zig) ask of the chip, by the names they
//! call it by. The P4 writes a range back through its ROM's
//! Cache_WriteBack_Addr, from the L1 data cache and the L2 cache both; it
//! has no erratum to work around, so nothing is frozen around it.

/// Cache_WriteBack_Addr(map, addr, size), through the ROM's table of entry
/// points, which is at the same place in every revision's ROM.
const rom_write_back: *const fn (map: u32, addr: u32, size: u32) callconv(.c) i32 = @ptrFromInt(0x4FC0_03F4);

/// The L1 data cache and the L2 cache, as the ROM names them.
const CACHE_MAP_L1_DCACHE: u32 = 1 << 4;
const CACHE_MAP_L2_CACHE: u32 = 1 << 5;

const line_size = @import("sdk").hardware.DCACHE_LINE_SIZE;

/// The line holding `addr` written back.
export fn cache_writeback_line_frozen(addr: u32) callconv(.c) void {
    _ = rom_write_back(CACHE_MAP_L1_DCACHE | CACHE_MAP_L2_CACHE, addr & ~@as(u32, line_size - 1), line_size);
}

/// `size` bytes from `addr` written back.
export fn cache_writeback_range_frozen(addr: u32, size: u32) callconv(.c) void {
    _ = rom_write_back(CACHE_MAP_L1_DCACHE | CACHE_MAP_L2_CACHE, addr, size);
}

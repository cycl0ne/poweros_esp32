// SPDX-License-Identifier: MPL-2.0
//! The SPI flash as a writable medium on the ESP32-P4, for flash.device:
//! the calls ../spiflash.zig has on the ESP32-S3, with the same contract.
//!
//! The whole flash is mapped at 0x40000000 from the boot on
//! (src/arch/esp32p4/flashmap.zig), so the disk area is read straight out
//! of that window and `map` only says where it is. Erasing and writing go
//! through the ROM's flash routines on MSPI1, which shares the bus with
//! MSPI0, the L2 cache's way to the flash: while a command runs the L2
//! cache is suspended, and nothing in flash or in PSRAM may be touched.
//! L2MEM, which only the L1 caches stand in front of, stays reachable.
//! Around the suspend, as ESP-IDF v6.1 does (spi_flash/cache_utils.c,
//! esp_mm/esp_cache_utils.c):
//! - the branch predictor off, since it fetches ahead through the caches;
//! - the L1 data cache's dirty lines written back first: one of PSRAM it
//!   wrote back on its own while the L2 cache is suspended would stall;
//! - afterwards the changed range dropped from every cache, so the window
//!   shows what the flash now holds.
//!
//! The caller's part is the S3's: interrupts off (the trap entry is in
//! RAM, but what it calls is in flash), the other core held - parked in
//! the RAM part, src/arch/esp32p4/rendezvous.zig - and a stack in L2MEM.
//! Every entry point here is `noinline` in `.iram.text`, the RAM part,
//! with `@setRuntimeSafety(false)`; it calls nothing but the ROM and reads
//! nothing but its own variables, in `.bss` and so in L2MEM.
//!
//! The ROM routines are the v1.x chips' (ESP-IDF's esp32p4.rom.eco0_4.ld),
//! reached through the ROM's table of entry points. They work with the
//! chip's parameters where the ROM's boot left them:
//! `rom_spiflash_legacy_data`, in the ROM's reserved part of L2MEM, which
//! src/arch/esp32p4/ram.zig keeps out of the heap.

const sdk = @import("sdk");
const hardware = sdk.hardware;
const cache = hardware.cache;

/// The flash's erase unit, and the alignment `eraseSector` wants.
pub const sector_size = 4096;
/// The flash's program unit: one command writes at most this many bytes,
/// and never across a page boundary.
pub const page_size = 256;
/// The MMU's page, and the alignment `map` wants.
pub const mmu_page_size = 64 * 1024;

const rom = struct {
    const spiflash_erase_sector: *const fn (sector: u32) callconv(.c) c_int = @ptrFromInt(0x4FC0_014C);
    const spiflash_write: *const fn (dest: u32, src: [*]const u32, len: i32) callconv(.c) c_int = @ptrFromInt(0x4FC0_0154);
    const spiflash_read: *const fn (src: u32, dest: [*]u32, len: i32) callconv(.c) c_int = @ptrFromInt(0x4FC0_0158);
    const spiflash_unlock: *const fn () callconv(.c) c_int = @ptrFromInt(0x4FC0_015C);
    const spiflash_config_param: *const fn (
        device_id: u32,
        chip_size: u32,
        block_size: u32,
        sector_size: u32,
        page_size: u32,
        status_mask: u32,
    ) callconv(.c) c_int = @ptrFromInt(0x4FC0_0168);
    const suspend_l2_cache: *const fn () callconv(.c) u32 = @ptrFromInt(0x4FC0_0508);
    const resume_l2_cache: *const fn (autoload: u32) callconv(.c) void = @ptrFromInt(0x4FC0_050C);
};

/// rom_spiflash_legacy_data: points at the chip parameters the ROM works
/// with (device id, chip size, block, sector, page, status mask).
const legacy_data = 0x4FF3_FFE8;
/// The flash's block: what the ROM's block erase erases.
const block_size = 64 * 1024;

/// MHCR, the core's branch prediction: the return stack, predicted jumps
/// and the branch target buffer.
const mhcr_predictor: u32 = 1 << 4 | 1 << 5 | 1 << 12;

/// The bytes one `programPage` call writes, in L2MEM: the caller's buffer
/// may be in PSRAM, which is out of reach while the L2 cache is suspended.
/// Words, so the ROM's write gets the alignment it wants.
var page: [page_size / 4]u32 = undefined;

/// Where the disk area is in the window, how much of it, and which flash
/// offset it starts at; map_start is 0 until `map` ran.
var map_start: usize = 0;
var map_len: usize = 0;
var map_offset: u32 = 0;

/// The bytes of the disk area that can be read straight from memory, or
/// an empty slice if `map` has not run.
pub fn mapped() []const u8 {
    if (map_start == 0) return &.{};
    const bytes: [*]const u8 = @ptrFromInt(map_start);
    return bytes[0..map_len];
}

/// Where `programPage` takes its bytes from: fill this, then call it.
pub fn pageBuffer() *align(4) [page_size]u8 {
    return @ptrCast(&page);
}

/// What `suspendCache` changed, for `resumeCache` to put back.
const Suspended = struct { autoload: u32, mhcr: u32 };

/// The L2 cache suspended. Everything between this and `resumeCache`
/// must be in ROM or the RAM part and touch nothing in flash or PSRAM.
fn suspendCache() linksection(".iram.text") Suspended {
    @setRuntimeSafety(false);
    const mhcr = asm volatile ("csrrc %[old], 0x7C1, %[bits]"
        : [old] "=r" (-> u32),
        : [bits] "r" (mhcr_predictor),
    );
    _ = cache.Cache_WriteBack_All(cache.MAP_L1_DCACHE);
    return .{ .autoload = rom.suspend_l2_cache(), .mhcr = mhcr };
}

fn resumeCache(suspended: Suspended) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    rom.resume_l2_cache(suspended.autoload);
    asm volatile ("csrs 0x7C1, %[bits]"
        :
        : [bits] "r" (suspended.mhcr & mhcr_predictor),
    );
}

/// A changed range of the flash dropped from every cache, with the L2
/// cache running again: nothing in the window is ever written through it,
/// so nothing there is dirty and dropping it loses nothing.
fn forget(at: u32, len: u32) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    _ = cache.Cache_Invalidate_Addr(cache.MAP_L1_ICACHES | cache.MAP_DATA, @intCast(hardware.map.FLASH_START + at), len);
}

/// The chip's real size to the ROM, whose routines refuse a sector past
/// what they think it is. The device id stays what the ROM read from the
/// chip.
pub noinline fn setSize(bytes: u32) linksection(".iram.text") bool {
    @setRuntimeSafety(false);
    const chip: [*]const u32 = @ptrFromInt(@as(*const volatile u32, @ptrFromInt(legacy_data)).*);
    const device_id = chip[0];
    const suspended = suspendCache();
    const result = rom.spiflash_config_param(device_id, bytes, block_size, sector_size, page_size, 0xFFFF);
    resumeCache(suspended);
    return result == 0;
}

/// What the ROM thinks the chip's size is.
pub fn size() u32 {
    const chip: [*]const u32 = @ptrFromInt(@as(*const volatile u32, @ptrFromInt(legacy_data)).*);
    return chip[1];
}

/// The chip's write protection off, once, before the first erase or write.
pub noinline fn unlock() linksection(".iram.text") bool {
    @setRuntimeSafety(false);
    const suspended = suspendCache();
    const result = rom.spiflash_unlock();
    resumeCache(suspended);
    return result == 0;
}

/// One 4 KiB sector erased, by its number (the byte offset divided by
/// sector_size). Tens of milliseconds, all of them with the L2 cache
/// suspended.
pub noinline fn eraseSector(sector: u32) linksection(".iram.text") bool {
    @setRuntimeSafety(false);
    const suspended = suspendCache();
    const result = rom.spiflash_erase_sector(sector);
    resumeCache(suspended);
    forget(sector * sector_size, sector_size);
    return result == 0;
}

/// The page buffer's first `len` bytes written at `offset`, which must not
/// cross a page boundary. Flash can only clear bits, so the range has to
/// have been erased.
pub noinline fn programPage(offset: u32, len: u32) linksection(".iram.text") bool {
    @setRuntimeSafety(false);
    const suspended = suspendCache();
    const result = rom.spiflash_write(offset, &page, @intCast(len));
    resumeCache(suspended);
    forget(offset, len);
    return result == 0;
}

/// `len` bytes from flash offset `from` into L2MEM over MSPI1 rather than
/// through the window: to check what the window shows.
pub noinline fn readRaw(from: u32, dest: [*]u32, len: u32) linksection(".iram.text") bool {
    @setRuntimeSafety(false);
    const suspended = suspendCache();
    const result = rom.spiflash_read(from, dest, @intCast(len));
    resumeCache(suspended);
    return result == 0;
}

/// Where the disk area - `len` bytes at flash offset `offset`, whole
/// 64 KiB pages - is in the window, which maps the whole flash already;
/// 0 if it is not whole pages.
pub fn map(offset: u32, len: u32) usize {
    if (offset % mmu_page_size != 0 or len % mmu_page_size != 0) return 0;
    map_start = hardware.map.FLASH_START + offset;
    map_len = len;
    map_offset = offset;
    return map_start;
}

// SPDX-License-Identifier: MPL-2.0
//! The SPI flash as a writable medium, for flash.device.
//!
//! The chip the kernel's code is executed from is also 16 MiB of storage.
//! Reading it is free: `map` points spare MMU entries at the disk area, so
//! it can be read straight out of the data window like any other memory.
//! Writing it is not. SPI1, which sends the erase and program commands,
//! shares the bus with SPI0, which serves the caches, so while a command
//! runs both caches must be suspended - and then nothing in flash and
//! nothing in PSRAM may be touched at all.
//!
//! Hence the same rules as the boot code (CLAUDE.md, tools/ressize.zig):
//! every function here is in `.iram.text` with `@setRuntimeSafety(false)`,
//! calls nothing but the ROM, and reads nothing but its own variables,
//! which are in `.bss` and so in internal SRAM. The caller must
//! - have interrupts off (exec's Disable): an interrupt would vector into
//!   `xtensa_exception`, which is in flash,
//! - run on a stack in internal SRAM, not the PSRAM one a task gets by
//!   default: a register-window spill would fault otherwise.
//! flash.device does both; that is why it has a task of its own.
//!
//! Every entry point is `noinline`: without it the compiler puts a copy
//! into its caller, which is in flash, and the first instruction fetched
//! after the cache goes down would come from there. `tools/ressize.zig`
//! checks the other direction (a reference from IRAM into flash), not this
//! one, so the placement is checked by hand: the symbols must be at
//! 0x4037xxxx, not 0x428xxxxx.
//!
//! The ROM's flash routines (esp32s3.rom.ld) need no attaching: the ROM
//! bootloader left the chip's parameters in `rom_spiflash_legacy_data` at
//! 0x3FCEFFE4, in the ROM data range src/arch/esp32s3/ram.zig keeps reserved.
//! Their addresses are declared here rather than shared with
//! src/arch/esp32s3/flashmap.zig, as psram.zig declares its own too.
//!
//! Erasing is the expensive operation: one 4 KiB sector takes tens of
//! milliseconds, all of it with interrupts off, so the kernel's 100 Hz tick
//! loses a few counts (SYSTIMER, and so the E-clock and uptime, keeps
//! running). Programming a 256-byte page is well under a millisecond, so
//! the device does one page per Disable/Enable.

const reg = @import("sdk").hardware.mmio.reg;

/// The flash's erase unit, and the alignment `erase` wants.
pub const sector_size = 4096;
/// The flash's program unit: one command writes at most this many bytes,
/// and never across a page boundary.
pub const page_size = 256;
/// The MMU's page, and the alignment `map` wants.
pub const mmu_page_size = 64 * 1024;

const mmu_table = @import("sdk").hardware.map.MMU_TABLE;
/// An MMU entry's value: the flash page for a mapped one, this for none.
const mmu_invalid: u32 = 1 << 14;
/// The data window's first address; MMU entry i maps 64 KiB there.
const dbus_base = 0x3C00_0000;
/// Entries 0-127 are PSRAM's and 128 on the kernel's code (7 pages today).
/// The disk takes 192 on, which leaves the code room to quadruple.
const first_entry = 192;
const last_entry = 512;

const rom = struct {
    const spiflash_wait_idle: *const fn (chip: ?*anyopaque) callconv(.c) c_int = @ptrFromInt(0x4000_0960);
    const spiflash_erase_sector: *const fn (sector: u32) callconv(.c) c_int = @ptrFromInt(0x4000_09FC);
    const spiflash_write: *const fn (dest: u32, src: [*]const u32, len: i32) callconv(.c) c_int = @ptrFromInt(0x4000_0A14);
    const spiflash_read: *const fn (src: u32, dest: [*]u32, len: i32) callconv(.c) c_int = @ptrFromInt(0x4000_0A20);
    const spiflash_unlock: *const fn () callconv(.c) c_int = @ptrFromInt(0x4000_0A2C);
    const spiflash_config_param: *const fn (
        device_id: u32,
        chip_size: u32,
        block_size: u32,
        sector_size: u32,
        page_size: u32,
        status_mask: u32,
    ) callconv(.c) c_int = @ptrFromInt(0x4000_0A50);
    const suspend_icache: *const fn () callconv(.c) u32 = @ptrFromInt(0x4000_189C);
    const resume_icache: *const fn (autoload: u32) callconv(.c) void = @ptrFromInt(0x4000_18A8);
    const suspend_dcache: *const fn () callconv(.c) u32 = @ptrFromInt(0x4000_18B4);
    const resume_dcache: *const fn (autoload: u32) callconv(.c) void = @ptrFromInt(0x4000_18C0);
    /// ICache or DCache, by the address. Whole lines.
    const invalidate_addr: *const fn (addr: u32, size: u32) callconv(.c) i32 = @ptrFromInt(0x4000_16B0);
};

/// EXTMEM_CACHE_STATE_REG: DCACHE_STATE is bits [23:12].
const cache_state = @import("sdk").hardware.map.EXTMEM + 0x130;
/// The caches' line size, the granularity of a range invalidate.
const line_size = 32;

/// rom_spiflash_legacy_data: points at the chip parameters the ROM works
/// with (device id, chip size, block, sector, page, status mask).
const legacy_data = 0x3FCE_FFE4;
/// The flash's block: what esp_rom_spiflash_erase_block erases.
const block_size = 64 * 1024;

/// The bytes one `program` call writes, in internal SRAM: the caller's
/// buffer may be in PSRAM, which is unreachable while the caches are off.
/// Words, so the ROM's write gets the alignment it wants.
var page: [page_size / 4]u32 = undefined;

/// Where the disk area is mapped, how much of it, and which flash offset
/// it starts at; map_start is 0 until `map` ran.
var map_start: usize = 0;
var map_len: usize = 0;
var map_offset: u32 = 0;

/// The bytes of the disk area that can be read straight from memory, or an
/// empty slice if it isn't mapped.
pub fn mapped() []const u8 {
    if (map_start == 0) return &.{};
    const p: [*]const u8 = @ptrFromInt(map_start);
    return p[0..map_len];
}

/// Where `program` takes its bytes from: fill this, then call it.
pub fn pageBuffer() *align(4) [page_size]u8 {
    return @ptrCast(&page);
}

/// Both caches suspended. Everything between this and `resumeCaches` must
/// be in ROM or IRAM and touch nothing in flash or PSRAM.
fn suspendCaches() linksection(".iram.text") u32 {
    @setRuntimeSafety(false);
    // Cache_Suspend_DCache can return before the cache is idle (a ROM bug
    // ESP-IDF patches around, as src/arch/esp32s3/psram.zig does at boot): wait
    // for CACHE_STATE[23:12] to read 1.
    const d = rom.suspend_dcache();
    var spins: u32 = 0;
    while ((reg(cache_state).* >> 12) & 0xFFF != 1 and spins < 100_000) : (spins += 1) {}
    const i = rom.suspend_icache();
    return d << 16 | i;
}

fn resumeCaches(autoload: u32) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    rom.resume_icache(autoload & 0xFFFF);
    rom.resume_dcache(autoload >> 16);
}

/// Whether a range of flash, by its offset on the chip, is in the mapping.
fn inMap(at: u32, len: u32) linksection(".iram.text") bool {
    @setRuntimeSafety(false);
    if (map_start == 0 or at < map_offset) return false;
    const rel = at - map_offset;
    return rel <= map_len and len <= map_len - rel;
}

/// The MMU entries of a changed range pointed at their pages again, with
/// the caches still suspended (an entry may only be written then). On the
/// chip this just writes what is already there. QEMU needs it: it models
/// the mapping by copying a page when its entry *changes*, and re-reads it
/// no other way, so a write would not be seen through the window - hence
/// the invalid value in between.
fn refresh(at: u32, len: u32) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    if (!inMap(at, len)) return;
    const rel = at - map_offset;
    var i = rel / mmu_page_size;
    const last = (rel + len - 1) / mmu_page_size;
    while (i <= last) : (i += 1) {
        const entry = mmu_table + 4 * (first_entry + i);
        reg(entry).* = mmu_invalid;
        reg(entry).* = map_offset / mmu_page_size + i; // flash, valid
    }
}

/// The cache lines of a changed range of the mapped area, dropped once the
/// caches are back. The area is only ever read through the cache, so
/// nothing there is dirty and invalidating cannot lose a write.
fn forget(at: u32, len: u32) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    if (!inMap(at, len)) return;
    const from = (map_start + at - map_offset) & ~@as(usize, line_size - 1);
    const to = (map_start + at - map_offset + len + line_size - 1) & ~@as(usize, line_size - 1);
    _ = rom.invalidate_addr(@intCast(from), @intCast(to - from));
}

/// The chip's real size to the ROM, whose routines refuse a sector past
/// what they think it is. Nothing has told them yet: the ROM starts with
/// 2 MiB and ESP-IDF's second-stage bootloader, which we don't have, is
/// what normally corrects it from the image header. The device id stays
/// what the ROM read from the chip.
pub noinline fn setSize(bytes: u32) linksection(".iram.text") bool {
    @setRuntimeSafety(false);
    const chip: [*]const u32 = @ptrFromInt(@as(*const u32, @ptrFromInt(legacy_data)).*);
    const device_id = chip[0];
    const autoload = suspendCaches();
    const r = rom.spiflash_config_param(device_id, bytes, block_size, sector_size, page_size, 0xFFFF);
    resumeCaches(autoload);
    return r == 0;
}

/// What the ROM thinks the chip's size is.
pub fn size() u32 {
    const chip: [*]const u32 = @ptrFromInt(@as(*const u32, @ptrFromInt(legacy_data)).*);
    return chip[1];
}

/// The chip's write protection off, once, before the first erase or write.
pub noinline fn unlock() linksection(".iram.text") bool {
    @setRuntimeSafety(false);
    const autoload = suspendCaches();
    const r = rom.spiflash_unlock();
    resumeCaches(autoload);
    return r == 0;
}

/// One 4 KiB sector erased, by its number (the byte offset divided by
/// sector_size). Tens of milliseconds, all of them with the caches off.
pub noinline fn eraseSector(sector: u32) linksection(".iram.text") bool {
    @setRuntimeSafety(false);
    const autoload = suspendCaches();
    const r = rom.spiflash_erase_sector(sector);
    refresh(sector * sector_size, sector_size);
    resumeCaches(autoload);
    forget(sector * sector_size, sector_size);
    return r == 0;
}

/// The page buffer's first `len` bytes written at `offset`, which must not
/// cross a page boundary. Flash can only clear bits, so the range has to
/// have been erased.
pub noinline fn programPage(offset: u32, len: u32) linksection(".iram.text") bool {
    @setRuntimeSafety(false);
    const autoload = suspendCaches();
    const r = rom.spiflash_write(offset, &page, @intCast(len));
    refresh(offset, len);
    resumeCaches(autoload);
    forget(offset, len);
    return r == 0;
}

/// `len` bytes from flash offset `from` into internal SRAM, over SPI1
/// rather than through the map: for a caller with no mapping, and to check
/// what the map shows.
pub noinline fn readRaw(from: u32, dest: [*]u32, len: u32) linksection(".iram.text") bool {
    @setRuntimeSafety(false);
    const autoload = suspendCaches();
    const r = rom.spiflash_read(from, dest, @intCast(len));
    resumeCaches(autoload);
    return r == 0;
}

/// The disk area into the data window, read-only, through the MMU entries
/// past the kernel's code: src/arch/esp32s3/flashmap.zig's map() for a second
/// region. `offset` and `len` are whole 64 KiB pages. Answers where it is,
/// or 0 if it doesn't fit.
pub noinline fn map(offset: u32, len: u32) linksection(".iram.text") usize {
    @setRuntimeSafety(false);
    const pages = len / mmu_page_size;
    if (offset % mmu_page_size != 0 or len % mmu_page_size != 0) return 0;
    if (first_entry + pages > last_entry) return 0;

    const autoload = suspendCaches();
    var i: u32 = 0;
    while (i < pages) : (i += 1) {
        reg(mmu_table + 4 * (first_entry + i)).* = offset / mmu_page_size + i; // flash, valid
    }
    resumeCaches(autoload);

    // Nothing to invalidate: the entries were invalid until now, so the
    // cache can hold nothing for these addresses.
    map_start = dbus_base + first_entry * mmu_page_size;
    map_len = len;
    map_offset = offset;
    return map_start;
}

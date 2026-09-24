// SPDX-License-Identifier: MPL-2.0
//! The kernel's code in flash, executed in place through the instruction
//! cache. The boot ROM loads only the image's RAM segments (esptool's
//! --ram-only-header); the code segment follows them in the image, at a
//! flash offset that agrees with its address modulo 64 KiB. find() reads the
//! image headers from flash offset 0 to learn where; map() points MMU
//! entries 128 on (0x42800000; entries 0-127 are PSRAM's) at those flash
//! pages, sets the instruction cache up (32 KiB in SRAM0, 8 ways, 32-byte
//! lines) and opens its bus. Both run from internal RAM before any code in
//! flash, as ESP-IDF's bootloader and Zephyr's simple boot do
//! (bootloader_utility.c's set_cache_and_start_app, loader.c's
//! map_rom_segments).

const reg = @import("sdk").hardware.mmio.reg;

extern var _flash_text_start: u8;
extern var _flash_text_size: u8;

/// The code's address and size, from the linker, kept in DRAM and read
/// with volatile loads: LLVM's Xtensa backend can't put an extern symbol's
/// address into the literal pool of a function in .iram.text (it fails to
/// select PCREL_WRAPPER), and a plain load would be folded back into one.
var text_start: *u8 = &_flash_text_start;
var text_size: *u8 = &_flash_text_size;

fn linkerValue(comptime which: *const *u8) linksection(".iram.text") u32 {
    @setRuntimeSafety(false);
    return @intFromPtr(@as(*const volatile *u8, which).*);
}

const mmu_table = @import("sdk").hardware.map.MMU_TABLE;
const page_size = 0x1_0000;
/// ICACHE_SHUT_CORE0_BUS [0] and ICACHE_SHUT_CORE1_BUS [1].
const extmem_icache_ctrl1 = @import("sdk").hardware.map.EXTMEM + 0x064;
const image_magic = 0xE9;
/// The image's common header (8 bytes) and extended header (16).
const image_header = 24;
const uart0_fifo = @import("sdk").hardware.map.UART0;
const uart0_status = 0x6000_001C;

const rom = struct {
    const spiflash_read: *const fn (src: u32, dest: [*]u32, len: i32) callconv(.c) c_int = @ptrFromInt(0x4000_0A20);
    const config_icache_mode: *const fn (size: u32, ways: u8, line: u8) callconv(.c) void = @ptrFromInt(0x4000_1A1C);
    const disable_icache: *const fn () callconv(.c) u32 = @ptrFromInt(0x4000_186C);
    const enable_icache: *const fn (autoload: u32) callconv(.c) void = @ptrFromInt(0x4000_1878);
    const invalidate_icache_all: *const fn () callconv(.c) void = @ptrFromInt(0x4000_16D4);
};

/// The code's first flash page, and how many pages it takes.
pub var first_page: u32 = 0;
pub var pages: u32 = 0;

pub fn start() u32 {
    return @intFromPtr(&_flash_text_start);
}

/// Where the code segment is in flash: after the RAM segments (the count
/// in the header), the checksum, which ends a 16-byte block, and a padding
/// segment esptool puts in front of it.
pub fn find() linksection(".iram.text") bool {
    @setRuntimeSafety(false);
    const vaddr = linkerValue(&text_start);
    const size = linkerValue(&text_size);
    var h: [2]u32 = undefined;
    if (rom.spiflash_read(0, &h, 8) != 0 or h[0] & 0xFF != image_magic) return false;
    var off: u32 = image_header;
    var ram_segments = (h[0] >> 8) & 0xFF;
    while (ram_segments > 0) : (ram_segments -= 1) {
        if (rom.spiflash_read(off, &h, 8) != 0) return false;
        off += 8 + h[1];
    }
    off = (off | 15) + 1;
    var tries: u32 = 0;
    while (tries < 4) : (tries += 1) {
        if (rom.spiflash_read(off, &h, 8) != 0) return false;
        if (h[0] == vaddr) {
            const data = off + 8;
            if (data % page_size != vaddr % page_size or h[1] < size) return false;
            first_page = data / page_size;
            pages = (vaddr % page_size + size + page_size - 1) / page_size;
            return true;
        }
        off += 8 + h[1];
    }
    return false;
}

/// The code's pages into the MMU, the instruction cache set up and its bus
/// opened. After psram.init, which clears the whole MMU table first.
pub fn map() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const vaddr = linkerValue(&text_start);
    rom.config_icache_mode(32 * 1024, 8, 32);
    const autoload = rom.disable_icache();
    const first_entry = (vaddr & 0x1FF_FFFF) / page_size;
    var i: u32 = 0;
    while (i < pages) : (i += 1) reg(mmu_table + 4 * (first_entry + i)).* = first_page + i; // flash, valid
    reg(extmem_icache_ctrl1).* &= ~@as(u32, 0b11);
    rom.enable_icache(autoload);
    rom.invalidate_icache_all();
}

/// Says why on UART0 and stops: without its code the kernel can't go on.
pub fn halt(message: [*:0]const u8) linksection(".iram.text") noreturn {
    @setRuntimeSafety(false);
    var p = message;
    while (p[0] != 0) : (p += 1) {
        while ((reg(uart0_status).* >> 16) & 0x3FF >= 64) {}
        reg(uart0_fifo).* = p[0];
    }
    while (true) {}
}

// SPDX-License-Identifier: MPL-2.0
//! Octal PSRAM, as the board's system tag list says it has
//! (`SYSTAG_PsramMode`), mapped through the data cache at 0x3C000000. Octal
//! is the one wiring brought up here: a board that says quad does not
//! build, and one that says none gets no PSRAM.
//!
//! Follows ESP-IDF's bring-up for a RAM app (esp_psram_impl_octal.c,
//! mspi_timing_tuning.c, cpu_start.c) with two differences: no timing
//! tuning (the MSPI input delay uses IDF's default point for 80 MHz DTR),
//! and a memory test at the end so a bad setup disables PSRAM instead of
//! handing out broken memory.
//!
//! It runs in kernel_early from IRAM, before the kernel's code in flash is
//! mapped (it clears the MMU and retimes the flash clock): every function
//! here but memory() is in .iram.text, without runtime safety (a failed
//! check would call the panic handler, which is in flash). PSRAM gets MMU
//! entries 0-127 at most (8 MiB): the code in flash starts at entry 128.

const sdk = @import("sdk");
const boards = @import("../../boards/boards.zig");
const st = sdk.expansion.systemtags;

/// How the board wires its PSRAM.
const wiring = boards.fact(st.SYSTAG_PsramMode, st.PSRAM_NONE);
comptime {
    if (wiring != st.PSRAM_NONE and wiring != st.PSRAM_OCTAL)
        @compileError("the board's PSRAM is wired in a way this code does not bring up (only octal)");
}
const reg = @import("sdk").hardware.mmio.reg;

pub const base = 0x3C00_0000;
/// Detected size in bytes; 0 until init succeeds.
pub var size: usize = 0;
/// Why init failed, if it did (kernel_early can't print yet).
pub var init_error: ?Error = null;
/// The most PSRAM that fits below the code's MMU entries.
const max_size = 8 << 20;
pub var vendor: u8 = 0;
/// Internal SRAM freed by the data cache being smaller than the memory set
/// aside for it. Empty while the cache has all 64 KB of it.
pub var spare_sram: []u8 = &.{};

pub const Error = error{
    /// No octal PSRAM answered on CS1.
    NoPsram,
    /// Written data did not read back through the cache.
    TestFailed,
};

pub fn memory() []u8 {
    const p: [*]u8 = @ptrFromInt(base);
    return p[0..size];
}

pub fn init() linksection(".iram.text") Error!void {
    @setRuntimeSafety(false);
    cacheInit();
    if (wiring == st.PSRAM_NONE) return error.NoPsram;
    pinInit();
    lowSpeed();
    try configureChip();
    cachePhases();
    highSpeed();
    map();
    try selfTest();
}

// --- registers ------------------------------------------------------------

const spi0 = 0x6000_3000; // cache side (SPI_MEM 0)
const spi1 = 0x6000_2000; // command side (SPI_MEM 1)
const spi_clock = 0x14;
const spi0_cache_sctrl = 0x40;
const spi0_sram_cmd = 0x44;
const spi0_sram_drd_cmd = 0x48;
const spi0_sram_dwr_cmd = 0x4C;
const spi0_sram_clk = 0x50;
const spi0_timing_cali = 0xBC;
const spi0_din_mode = 0xC0;
const spi0_din_num = 0xC4;
const spi0_smem_ac = 0xDC;
const spi0_smem_ddr = 0xE4;
const spi0_core_clk_sel = 0xEC;
const spi0_date = 0x3FC;
const spi1_ddr = 0xE0;

/// SPI_MEM clock values: divide the MSPI core clock by 4 or by 2.
const clk_div4 = 0x0003_0103;
const clk_div2 = 0x0001_0001;

const io_mux = sdk.hardware.map.IO_MUX;
fn ioMuxGpio(n: u32) linksection(".iram.text") usize {
    @setRuntimeSafety(false);
    return io_mux + 4 + 4 * n;
}

const extmem_dcache_ctrl1 = sdk.hardware.map.EXTMEM + 0x004;
const extmem_cache_state = sdk.hardware.map.EXTMEM + 0x130;

const mmu_table = sdk.hardware.map.MMU_TABLE;
const mmu_entries = 512;
const mmu_invalid: u32 = 1 << 14;
const mmu_psram: u32 = 1 << 15;
const page_size = 64 * 1024;

/// What the data cache is given: the top 64 KB of SRAM2, all of it, in
/// 64-byte lines.
///
/// The line is the unit in which the cache moves PSRAM, and the DMA reaches
/// PSRAM through the same controller, so it is also the largest block the
/// DMA can ask for. A display streaming a frame out of PSRAM wants the
/// largest there is: each access costs the same turnaround whatever it
/// carries, and 32-byte lines spend half the bus on turnarounds. The panel
/// needs 39 MB/s of the bus continuously, and with 32-byte lines the CPU
/// touching PSRAM at the same time was enough to leave the pixel FIFO dry.
///
/// It costs the 32 KB that a half-sized cache would have left free.
const dcache_size = 64 * 1024;
const dcache_ways = 8;
const dcache_line = sdk.hardware.DCACHE_LINE_SIZE;
/// The top 64 KB of SRAM2, of which the cache uses `dcache_size`.
const dcache_region_start = 0x3FCF_0000;
const dcache_region_len = 0x1_0000;

// --- ROM functions (esp32s3.rom.ld) ----------------------------------------

const opi_dtr_mode = 7; // ESP_ROM_SPIFLASH_OPI_DTR_MODE
const cs1: u32 = 1 << 1;

const rom = struct {
    const boot_cache_init: *const fn () callconv(.c) void = @ptrFromInt(0x4000_1668);
    const cache_suspend_dcache: *const fn () callconv(.c) u32 = @ptrFromInt(0x4000_18B4);
    const cache_resume_dcache: *const fn (autoload: u32) callconv(.c) void = @ptrFromInt(0x4000_18C0);
    const config_data_cache_mode: *const fn (cache_size: u32, ways: u8, line_size: u8) callconv(.c) void = @ptrFromInt(0x4000_1A28);
    const cache_invalidate_dcache_all: *const fn () callconv(.c) void = @ptrFromInt(0x4000_16E0);
    const cache_writeback_all: *const fn () callconv(.c) void = @ptrFromInt(0x4000_16F8);
    const opiflash_pin_config: *const fn () callconv(.c) void = @ptrFromInt(0x4000_0894);
    const spi_set_dtr_swap_mode: *const fn (spi: c_int, wr_swap: bool, rd_swap: bool) callconv(.c) void = @ptrFromInt(0x4000_093C);
    const opiflash_exec_cmd: *const fn (
        spi_num: c_int,
        mode: c_int,
        cmd: u32,
        cmd_bit_len: c_int,
        addr: u32,
        addr_bit_len: c_int,
        dummy_bits: c_int,
        mosi: ?[*]const u8,
        mosi_bit_len: c_int,
        miso: ?[*]u8,
        miso_bit_len: c_int,
        cs_mask: u32,
        is_write_erase: bool,
    ) callconv(.c) void = @ptrFromInt(0x4000_08B8);
};

// --- bring-up ---------------------------------------------------------------

/// The ROM does not set up cache and MMU for a RAM app: reset both, give
/// the data cache 32 KB, and open the data bus to 0x3C000000.
fn cacheInit() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    rom.boot_cache_init();
    for (0..mmu_entries) |i| reg(mmu_table + 4 * i).* = mmu_invalid;

    const autoload = suspendDCache();
    rom.config_data_cache_mode(dcache_size, dcache_ways, dcache_line);
    rom.cache_resume_dcache(autoload);
    reg(extmem_dcache_ctrl1).* &= ~@as(u32, 0b11); // DCACHE_SHUT_CORE0/1_BUS

    // What the cache does not occupy of the memory set aside for it.
    const p: [*]u8 = @ptrFromInt(dcache_region_start + dcache_size);
    spare_sram = p[0 .. dcache_region_len - dcache_size];
}

/// Cache_Suspend_DCache can return before the cache is idle (ROM bug
/// patched in ESP-IDF): wait for CACHE_STATE[23:12] to read 1.
fn suspendDCache() linksection(".iram.text") u32 {
    @setRuntimeSafety(false);
    const autoload = rom.cache_suspend_dcache();
    var spins: u32 = 0;
    while ((reg(extmem_cache_state).* >> 12) & 0xFFF != 1 and spins < 100_000) : (spins += 1) {}
    return autoload;
}

fn pinInit() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    rom.opiflash_pin_config(); // octal data lines D4-D7 and DQS (GPIO33-37)

    // Drive strength 3 for the MSPI clock and data pads.
    const date = reg(spi0 + spi0_date);
    date.* = (date.* & ~@as(u32, 0x1F)) | 1 << 4 | 3 << 2 | 3;
    for ([_]u32{ 27, 28, 31, 32, 33, 34, 35, 36, 37 }) |gpio| setField(ioMuxGpio(gpio), 10, 0x3, 3);

    // PSRAM chip select CS1 on GPIO26 (function 0 = SPICS1).
    setField(ioMuxGpio(26), 12, 0x7, 0);
    setField(ioMuxGpio(26), 10, 0x3, 3);

    // CS setup/hold timing (shared by SPI0 and SPI1).
    const ac = spi0 + spi0_smem_ac;
    reg(ac).* |= 0b11; // CS_SETUP, CS_HOLD
    setField(ac, 2, 0x1F, 3); // CS_SETUP_TIME
    setField(ac, 7, 0x1F, 3); // CS_HOLD_TIME
    setField(ac, 25, 0x3F, 2); // CS_HOLD_DELAY
}

/// MSPI core 80 MHz, bus 20 MHz, for configuring the chip over SPI1.
fn lowSpeed() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    setField(spi0 + spi0_core_clk_sel, 0, 0x3, 0);
    reg(spi0 + spi_clock).* = clk_div4;
    reg(spi1 + spi_clock).* = clk_div4;
    reg(spi0 + spi0_sram_clk).* = clk_div4;
    reg(spi0 + spi0_din_mode).* = 0;
    reg(spi0 + spi0_din_num).* = 0;
    reg(spi0 + spi0_timing_cali).* &= ~@as(u32, 0b11110);
}

fn configureChip() linksection(".iram.text") Error!void {
    @setRuntimeSafety(false);
    reg(spi1 + spi1_ddr).* |= 1 << 1; // SPI_FMEM_VAR_DUMMY
    rom.spi_set_dtr_swap_mode(1, false, false);

    // MR0: fixed read latency of 10 cycles, drive strength 0 (like IDF).
    var mr: [2]u8 = undefined;
    readModeRegs(0, &mr);
    const mr0_mr1 = [2]u8{ (mr[0] & 0xC0) | 0x28, mr[1] };
    rom.opiflash_exec_cmd(1, opi_dtr_mode, 0xC0C0, 16, 0, 32, 0, &mr0_mr1, 16, null, 0, cs1, false);
    vendor = mr[1] & 0x1F;

    // MR2[2:0] is the density.
    readModeRegs(2, &mr);
    size = switch (mr[0] & 0x7) {
        1 => 4 << 20,
        3 => 8 << 20,
        5 => 16 << 20,
        7 => 32 << 20,
        else => return error.NoPsram,
    };

    // Write a word over SPI1 and read it back, like IDF does.
    const pattern = [4]u8{ 0x8D, 0x7C, 0x6B, 0x5A };
    var back: [4]u8 = undefined;
    rom.opiflash_exec_cmd(1, opi_dtr_mode, 0x8080, 16, 0, 32, 8, &pattern, 32, null, 0, cs1, false);
    rom.opiflash_exec_cmd(1, opi_dtr_mode, 0x0000, 16, 0, 32, 18, null, 0, &back, 32, cs1, false);
    for (pattern, back) |sent, got| {
        if (sent != got) {
            size = 0;
            return error.NoPsram;
        }
    }
    if (size > max_size) size = max_size;
}

fn readModeRegs(addr: u32, out: *[2]u8) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    rom.opiflash_exec_cmd(1, opi_dtr_mode, 0x4040, 16, addr, 32, 8, null, 0, out, 16, cs1, false);
}

/// Octal DTR read/write commands on the cache side (SPI0).
fn cachePhases() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const sctrl = spi0 + spi0_cache_sctrl;
    reg(sctrl).* |= 1 << 0 | 1 << 3 | 1 << 4 | 1 << 5 | 1 << 20 | 1 << 21; // 4-byte addr, dummies, rd/wr cmd, octal
    setField(sctrl, 6, 0x3F, 17); // SRAM_RDUMMY_CYCLELEN: 18 cycles
    setField(sctrl, 14, 0x3F, 31); // SRAM_ADDR_BITLEN: 32 bits
    setField(sctrl, 22, 0x3F, 7); // SRAM_WDUMMY_CYCLELEN: 8 cycles

    reg(spi0 + spi0_sram_drd_cmd).* = 15 << 28 | 0x0000; // 16-bit read command
    reg(spi0 + spi0_sram_dwr_cmd).* = 15 << 28 | 0x8080; // 16-bit write command

    const ddr = reg(spi0 + spi0_smem_ddr);
    ddr.* = (ddr.* | 0b0011) & ~@as(u32, 0b1100); // DDR_EN, VAR_DUMMY, no data swap
    reg(spi0 + spi0_sram_cmd).* |= 0x007C_0000; // SDIN/SDOUT/SADDR/SCMD octal, SDUMMY_OUT
}

/// MSPI core 160 MHz: PSRAM and flash at 80 MHz, with ESP-IDF's default
/// input timing point {din_mode 4, din_num 0, extra dummy 2}.
fn highSpeed() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    setField(spi0 + spi0_core_clk_sel, 0, 0x3, 2);
    reg(spi0 + spi0_sram_clk).* = clk_div2;
    reg(spi0 + spi_clock).* = clk_div2;
    reg(spi1 + spi_clock).* = clk_div2;
    reg(spi1 + spi1_ddr).* &= ~@as(u32, 1 << 1);

    reg(spi0 + spi0_din_mode).* = 0x0492_4924; // all nine inputs: mode 4
    reg(spi0 + spi0_din_num).* = 0;
    const cali = spi0 + spi0_timing_cali;
    reg(cali).* |= 0b11; // TIMING_CLK_ENA, TIMING_CALI
    setField(cali, 2, 0x7, 2); // extra dummy cycles
}

fn map() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    for (0..size / page_size) |page| reg(mmu_table + 4 * page).* = mmu_psram | @as(u32, @intCast(page));
    rom.cache_invalidate_dcache_all();
}

/// Write a distinct word into every 64 KB page, flush the cache, and read it
/// all back. Catches bad timing, wrong size (aliasing) and a closed bus.
fn selfTest() linksection(".iram.text") Error!void {
    @setRuntimeSafety(false);
    const pages = size / page_size;
    for (0..pages) |page| {
        testWord(page, 0).* = patternFor(page, 0);
        testWord(page, 1).* = patternFor(page, 1);
    }
    rom.cache_writeback_all();
    rom.cache_invalidate_dcache_all();
    for (0..pages) |page| {
        if (testWord(page, 0).* != patternFor(page, 0) or testWord(page, 1).* != patternFor(page, 1)) {
            size = 0;
            return error.TestFailed;
        }
    }
}

/// First word and a page-dependent word further in, so every data line and
/// many address lines toggle.
fn testWord(page: usize, which: u1) linksection(".iram.text") *volatile u32 {
    @setRuntimeSafety(false);
    const offset: usize = if (which == 0) 0 else (4 + (page * 4100) % (page_size - 8)) & ~@as(usize, 3);
    return @ptrFromInt(base + page * page_size + offset);
}

fn patternFor(page: usize, which: u1) linksection(".iram.text") u32 {
    @setRuntimeSafety(false);
    const salt: u32 = if (which == 0) 0x5A5A_A5A5 else 0xC3C3_3C3C;
    return @as(u32, @truncate(page)) *% 0x9E37_79B9 ^ salt;
}

fn setField(addr: usize, comptime shift: u5, mask: u32, value: u32) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const r = reg(addr);
    r.* = (r.* & ~(mask << shift)) | (value << shift);
}

const std = @import("std");

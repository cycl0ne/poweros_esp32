// SPDX-License-Identifier: MPL-2.0
//! The PSRAM: the module's AP Memory HEX PSRAM - 16 data lines, both clock
//! edges - behind the PSRAM controller (MSPI2, which the caches reach it
//! through, and MSPI3, which talks to the chip itself), mapped at
//! 0x48000000 by the PSRAM MMU. Brought up as ESP-IDF v6.1 does
//! (esp_psram_impl_ap_hex.c, mspi_timing_by_dqs.c), at a 200 MHz bus:
//!
//! 1. The chip's power, LDO channel 2 at 1.8 V, which feeds the MPLL too;
//!    the MPLL at 400 MHz, the controller's clock, set over the analog bus
//!    and calibrated; the controller clocked from it and reset.
//! 2. The pads' drive and the data strobe (DQS) on; chip select timing,
//!    split transfers, 2 KiB pages; both controllers' bus clocks 400 / 20;
//!    the DLLs on.
//! 3. The chip's mode registers - latency, drive, burst - set with direct
//!    transactions on MSPI3 (the ROM's esp_rom_spi_cmd_*), a word written
//!    and read back to find it there, and its size read from MR2.
//! 4. MSPI2 set up for the caches' accesses - commands, 32-bit addresses,
//!    dummy cycles, DDR on 16 lines over the AXI bus.
//! 5. The timing tuned: a 128-byte pattern written at 20 MHz, then read
//!    back at 200 MHz under each of the data strobe's four phases, and
//!    under the best of them, each of 31 delay line settings a hundred
//!    times - the strobe delayed against the data, then the data against
//!    the strobe. The middle of the longest run of settings that read it
//!    back right every time is kept. A chip that reads it back under none
//!    is brought up again at 20 MHz, where no tuning is needed.
//! 6. The whole size mapped at 0x48000000, 64 KiB per MMU entry.

const std = @import("std");
const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const map = hardware.map;
const cache = hardware.cache;
const regi2c = @import("regi2c.zig");

pub const Error = error{NotFound};

/// What `init` found.
pub var size: u32 = 0;
pub var vendor: u8 = 0;
pub const base: usize = map.PSRAM_START;

// --- the power --------------------------------------------------------------------

/// LDO channel 2 (the PMU's EXT_LDO_P1_0P1A pair): the control word -
/// software owns it (bit 7), on (8), its source (9-11), the rail rather
/// than the divided reference (14) - and the analog word - the multiplier
/// (23-25), ripple suppression (26), the current limit (27) and the
/// reference (28-31).
const ldo_control = map.PMU + 0x1D0;
const ldo_analog = map.PMU + 0x1D4;
const ldo_force_tieh_sel: u32 = 1 << 7;
const ldo_xpd: u32 = 1 << 8;
const ldo_tieh_sel: u32 = 0x7 << 9;
const ldo_tieh: u32 = 1 << 14;
const ldo_mul_shift = 23;
const ldo_en_vdet: u32 = 1 << 26;
const ldo_en_cur_lim: u32 = 1 << 27;
const ldo_dref_shift = 28;
/// EFUSE_RD_MAC_SYS_2 and _3: the block version, and channel 2's
/// reference and multiplier for 1.8 V where the factory calibrated them.
const efuse_rd_mac_sys_2 = map.EFUSE + 0x4C;
const efuse_rd_mac_sys_3 = map.EFUSE + 0x50;

/// LDO channel 2 at 1.8 V: Vref x (4 + mul) / 4 with Vref = (10 + dref) /
/// 20 V - reference 8, multiplier 4 - or the factory's pair.
fn ldoInit() void {
    var dref: u32 = 8;
    var mul: u32 = 4;
    const sys_2 = reg(efuse_rd_mac_sys_2).*;
    const blk_version = ((sys_2 >> 11) & 0x3) * 100 + ((sys_2 >> 8) & 0x7);
    const efuse_dref = sys_2 >> 28;
    const efuse_mul = (reg(efuse_rd_mac_sys_3).* >> 3) & 0x7;
    if (blk_version >= 1 and efuse_dref != 0 and efuse_mul != 0) {
        dref = efuse_dref;
        mul = efuse_mul;
    }
    reg(ldo_analog).* |= ldo_en_cur_lim;
    reg(ldo_control).* &= ~ldo_tieh;
    reg(ldo_analog).* = (reg(ldo_analog).* & ~(@as(u32, 0x7) << ldo_mul_shift | @as(u32, 0xF) << ldo_dref_shift)) |
        mul << ldo_mul_shift | dref << ldo_dref_shift;
    reg(ldo_control).* = (reg(ldo_control).* & ~ldo_tieh_sel) | ldo_force_tieh_sel;
    reg(ldo_analog).* |= ldo_en_vdet;
    reg(ldo_control).* |= ldo_xpd;
    reg(ldo_analog).* &= ~ldo_en_cur_lim;
    hardware.systimer.spinUs(200);
}

// --- the MPLL -------------------------------------------------------------------

const pmu_rf_pwc = map.PMU + 0x15C;
const mspi_phy_xpd: u32 = 1 << 24;
const lp_hp_clk_ctrl = map.LP_CLKRST + 0x040;
const mpll_500m_clk_en: u32 = 1 << 28;
const ana_pll_ctrl0 = map.HP_SYS_CLKRST + 0x0BC;
const mspi_cal_end: u32 = 1 << 8;
const mspi_cal_stop: u32 = 1 << 9;
// The MPLL's registers on the analog bus.
const mpll_ir_cal = 1; // IR_CAL_RSTB in bit 5
const mpll_div = 2; // divider in bits 3-7, reference divider in 0-2
const mpll_dhref = 3; // DHREF in bits 4-5
const mpll_hz: u32 = 400_000_000;

/// The MPLL at 400 MHz: 40 MHz x (div + 1) / (ref_div + 1), div 19, ref 1.
fn mpllInit() void {
    reg(pmu_rf_pwc).* |= mspi_phy_xpd;
    reg(lp_hp_clk_ctrl).* |= mpll_500m_clk_en;
    reg(ana_pll_ctrl0).* &= ~mspi_cal_stop;
    regi2c.write(.mpll, mpll_dhref, regi2c.read(.mpll, mpll_dhref) | 3 << 4);
    const rstb = regi2c.read(.mpll, mpll_ir_cal);
    regi2c.write(.mpll, mpll_ir_cal, rstb & 0xDF);
    regi2c.write(.mpll, mpll_ir_cal, rstb | 1 << 5);
    const div: u8 = @intCast(mpll_hz / 20_000_000 - 1);
    regi2c.write(.mpll, mpll_div, div << 3 | 1);
    var spins: u32 = 0;
    while (reg(ana_pll_ctrl0).* & mspi_cal_end == 0 and spins < 1_000_000) spins += 1;
    reg(ana_pll_ctrl0).* |= mspi_cal_stop;
}

// --- the controller -------------------------------------------------------------

// HP_SYS_CLKRST: the controller's clocks, reset and source.
const soc_clk_ctrl0 = map.HP_SYS_CLKRST + 0x014;
const psram_sys_clk_en: u32 = 1 << 31;
const peri_clk_ctrl00 = map.HP_SYS_CLKRST + 0x030;
const psram_clk_src_mask: u32 = 0x3 << 12;
const psram_clk_src_mpll: u32 = 1 << 12;
const psram_pll_clk_en: u32 = 1 << 14;
const psram_core_clk_en: u32 = 1 << 15;
const hp_rst_en0 = map.HP_SYS_CLKRST + 0x0C0;
const rst_en_dual_mspi_axi: u32 = 1 << 23;
const rst_en_dual_mspi_apb: u32 = 1 << 25;

// MSPI2 (PSRAM_MSPI0).
const mspi2 = map.PSRAM_MSPI0;
const ctrl1 = mspi2 + 0x00C;
const ar_splice_en: u32 = 1 << 25;
const aw_splice_en: u32 = 1 << 26;
const cache_fctrl = mspi2 + 0x03C;
const axi_req_en: u32 = 1 << 0;
const close_axi_inf_en: u32 = 1 << 31;
const cache_sctrl = mspi2 + 0x040;
const cache_usr_saddr_4byte: u32 = 1 << 0;
const usr_wr_sram_dummy: u32 = 1 << 3;
const usr_rd_sram_dummy: u32 = 1 << 4;
const cache_sram_usr_rcmd: u32 = 1 << 5;
const sram_rdummy_cyclelen_shift = 6; // 6 bits
const sram_addr_bitlen_shift = 14; // 6 bits
const cache_sram_usr_wcmd: u32 = 1 << 20;
const sram_oct: u32 = 1 << 21;
const sram_wdummy_cyclelen_shift = 22; // 6 bits
const sram_cmd = mspi2 + 0x044;
const sdin_oct: u32 = 1 << 18;
const sdout_oct: u32 = 1 << 19;
const saddr_oct: u32 = 1 << 20;
const scmd_oct: u32 = 1 << 21;
const sdummy_wout: u32 = 1 << 23;
const sdin_hex: u32 = 1 << 26;
const sdout_hex: u32 = 1 << 27;
const sram_drd_cmd = mspi2 + 0x048; // value in 0-15, bit length - 1 in 28-31
const sram_dwr_cmd = mspi2 + 0x04C;
const sram_clk = mspi2 + 0x050;
const smem_ddr = mspi2 + 0x0D8;
const smem_ddr_en: u32 = 1 << 0;
const smem_var_dummy: u32 = 1 << 1;
const smem_ddr_rdat_swp: u32 = 1 << 2;
const smem_ddr_wdat_swp: u32 = 1 << 3;
const smem_ecc_ctrl = mspi2 + 0x174;
const smem_page_size_shift = 18; // 2 bits, 3 = 2 KiB
const timing_cali = mspi2 + 0x180;
const smem_timing_cali = mspi2 + 0x190;
const dll_timing_cali: u32 = 1 << 5;
const smem_ac = mspi2 + 0x1A0;
// MSPI3 (PSRAM_MSPI1).
const mspi3_clock = map.PSRAM_MSPI1 + 0x014;
const mspi3_ddr = map.PSRAM_MSPI1 + 0x0D4;
const fmem_var_dummy: u32 = 1 << 1;
// The PSRAM pads (IOMUX_MSPI_PIN): D, Q, WP, HOLD, DQ4-7, DQS0, CK, CS,
// DQ8-15, DQS1, a word each; drive in bits 12-13, the strobes' in 15-16
// with their power-up in bit 0.
const pad_first = map.IOMUX_MSPI_PIN + 0x01C;
const pad_last = map.IOMUX_MSPI_PIN + 0x068;
const pad_dqs0 = map.IOMUX_MSPI_PIN + 0x03C;
const pad_dqs1 = map.IOMUX_MSPI_PIN + 0x068;
/// PERI_CLK_CTRL00: the core clock's divider from the source, minus one.
const psram_core_clk_div_shift = 16;
/// SRAM_CLK and MSPI3's CLOCK: the bus clock equal to the core clock.
const clock_equals_source: u32 = 1 << 31;

// The PSRAM MMU (PSRAM_MSPI0): the entry, then its value - the page,
// valid, PSRAM.
const mmu_item_content = mspi2 + 0x37C;
const mmu_item_index = mspi2 + 0x380;
const mmu_psram_valid: u32 = 1 << 11;
const mmu_access_psram: u32 = 1 << 10;
const page_size = 0x1_0000;

// The chip's commands.
const sync_read: u16 = 0x0000;
const sync_write: u16 = 0x8080;
const reg_read: u16 = 0x4040;
const reg_write: u16 = 0xC0C0;
/// A word written and read back to find the chip.
const reference_word: u32 = 0x5A6B_7C8D;

/// What a bus speed asks of the chip and the controllers: the latencies
/// set in the chip, the dummy bits that cover them, and the controllers'
/// clock divider from the MPLL.
const Speed = struct {
    mhz: u32,
    rd_dummy_bits: u32,
    rd_reg_dummy_bits: u32,
    wr_dummy_bits: u32,
    read_latency: u8,
    write_latency: u8,

    fn divider(speed: Speed) u32 {
        return mpll_hz / (speed.mhz * 1_000_000);
    }
};
const fast: Speed = .{ .mhz = 200, .rd_dummy_bits = 2 * (14 - 1), .rd_reg_dummy_bits = 2 * (7 - 1), .wr_dummy_bits = 2 * (7 - 1), .read_latency = 4, .write_latency = 1 };
const slow: Speed = .{ .mhz = 20, .rd_dummy_bits = 2 * (10 - 1), .rd_reg_dummy_bits = 2 * (5 - 1), .wr_dummy_bits = 2 * (5 - 1), .read_latency = 2, .write_latency = 2 };

/// The bus speed `init` brought the chip up at, and what the tuning chose.
pub var bus_mhz: u32 = 0;
pub var tuned_phase: u32 = 0;
pub var tuned_delayline: Delayline = .{ .data = 0, .dqs = 0 };
/// How many delay line settings read the pattern back right every time.
pub var tuned_window: u32 = 0;

// The ROM's direct transactions, on MSPI3 with the PSRAM's chip select.
const SpiCommand = extern struct {
    cmd: u16,
    cmd_bit_len: u16,
    addr: *u32,
    addr_bit_len: u32,
    tx_data: ?*anyopaque,
    tx_data_bit_len: u32,
    rx_data: ?*anyopaque,
    rx_data_bit_len: u32,
    dummy_bit_len: u32,
};
const esp_rom_spi_cmd_config: *const fn (spi: c_int, command: *SpiCommand) callconv(.c) void = @ptrFromInt(0x4FC0_0108);
const esp_rom_spi_cmd_start: *const fn (spi: c_int, rx: ?[*]u8, rx_len: u16, cs_mask: u8, is_write_erase: bool) callconv(.c) void = @ptrFromInt(0x4FC0_010C);
const esp_rom_spi_set_op_mode: *const fn (spi: c_int, mode: c_int) callconv(.c) void = @ptrFromInt(0x4FC0_0110);
const mspi3 = 3;
const opi_dtr_mode = 7;
const psram_cs_mask: u8 = 1 << 1;

fn transaction(cmd: u16, address: u32, dummy_bits: u32, out: ?[]u8, in: ?[]u8) void {
    var addr = address;
    var command: SpiCommand = .{
        .cmd = cmd,
        .cmd_bit_len = 16,
        .addr = &addr,
        .addr_bit_len = 32,
        .tx_data = if (out) |bytes| bytes.ptr else null,
        .tx_data_bit_len = if (out) |bytes| @intCast(bytes.len * 8) else 0,
        .rx_data = if (in) |bytes| bytes.ptr else null,
        .rx_data_bit_len = if (in) |bytes| @intCast(bytes.len * 8) else 0,
        .dummy_bit_len = dummy_bits,
    };
    esp_rom_spi_set_op_mode(mspi3, opi_dtr_mode);
    esp_rom_spi_cmd_config(mspi3, &command);
    esp_rom_spi_cmd_start(mspi3, if (in) |bytes| bytes.ptr else null, if (in) |bytes| @intCast(bytes.len) else 0, psram_cs_mask, false);
}

fn readRegisters(speed: Speed, address: u32, into: []u8) void {
    transaction(reg_read, address, speed.rd_reg_dummy_bits, null, into);
}

fn writeRegisters(address: u32, from: []u8) void {
    transaction(reg_write, address, 0, from, null);
}

fn setField(address: usize, comptime shift: u5, mask: u32, value: u32) void {
    reg(address).* = (reg(address).* & ~(mask << shift)) | (value << shift);
}

/// A bus clock of `divider` source clocks per bit, high for half of them.
fn clockBits(divider: u32) u32 {
    return (divider - 1) << 16 | (divider / 2 - 1) << 8 | (divider - 1);
}

/// The PSRAM brought up at 200 MHz with its timing tuned, or at 20 MHz
/// where the tuning finds nothing that reads right; mapped.
pub fn init() Error!void {
    ldoInit();
    mpllInit();
    // At 20 MHz nothing is tuned, so only a chip that is not there fails.
    bringUp(fast) catch {
        bringUp(slow) catch return error.NotFound;
    };
    var entry: u32 = 0;
    while (entry < size / page_size) : (entry += 1) {
        reg(mmu_item_index).* = entry;
        reg(mmu_item_content).* = entry | mmu_psram_valid | mmu_access_psram;
    }
    _ = cache.Cache_Invalidate_Addr(cache.MAP_L1_DCACHE | cache.MAP_L2_CACHE, @intCast(base), size);
}

const BringUpError = Error || error{NotTuned};

fn bringUp(speed: Speed) BringUpError!void {
    reg(soc_clk_ctrl0).* |= psram_sys_clk_en;
    reg(peri_clk_ctrl00).* |= psram_pll_clk_en | psram_core_clk_en;
    reg(hp_rst_en0).* |= rst_en_dual_mspi_axi | rst_en_dual_mspi_apb;
    reg(hp_rst_en0).* &= ~rst_en_dual_mspi_apb;
    reg(hp_rst_en0).* &= ~rst_en_dual_mspi_axi;
    reg(peri_clk_ctrl00).* = (reg(peri_clk_ctrl00).* & ~psram_clk_src_mask) | psram_clk_src_mpll;
    setField(peri_clk_ctrl00, psram_core_clk_div_shift, 0xFF, 0); // the MPLL undivided

    var pad: usize = pad_first;
    while (pad <= pad_last) : (pad += 4) {
        if (pad == pad_dqs0 or pad == pad_dqs1) setField(pad, 15, 0x3, 2) else setField(pad, 12, 0x3, 2);
    }
    reg(pad_dqs0).* |= 1;
    reg(pad_dqs1).* |= 1;
    clearTuning();

    // CS setup 4, hold 4, hold delay 3 clocks; split transfers.
    reg(smem_ac).* = (reg(smem_ac).* & ~(@as(u32, 0x1F) << 2 | @as(u32, 0x1F) << 7 | @as(u32, 0x3F) << 25)) |
        1 << 0 | (4 - 1) << 2 | 1 << 1 | (4 - 1) << 7 | (3 - 1) << 25 | 1 << 31;
    setField(smem_ecc_ctrl, smem_page_size_shift, 0x3, 3);
    setBusClock(speed);
    reg(smem_timing_cali).* |= dll_timing_cali;
    reg(timing_cali).* |= dll_timing_cali;

    // MR0 (fixed latency, read latency, drive) and MR4 (write latency);
    // MR8 (burst length 2 KiB wrapping, 16 lines).
    var mr0_1: [2]u8 = undefined;
    readRegisters(speed, 0x0, &mr0_1);
    mr0_1[0] = (mr0_1[0] & ~@as(u8, 0x3F)) | 1 << 5 | speed.read_latency << 2 | 0;
    var mr4_5: [2]u8 = undefined;
    readRegisters(speed, 0x4, &mr4_5);
    mr4_5[0] = (mr4_5[0] & ~@as(u8, 0xE0)) | speed.write_latency << 5;
    writeRegisters(0x0, &mr0_1);
    writeRegisters(0x4, &mr4_5);
    var mr8: [1]u8 = undefined;
    readRegisters(speed, 0x8, &mr8);
    mr8[0] = (mr8[0] & ~@as(u8, 0x4F)) | 3 | 0 << 2 | 1 << 3 | 1 << 6;
    var mr8_pair = [2]u8{ mr8[0], 0 };
    writeRegisters(0x8, &mr8_pair);

    // A word written and read back.
    var reference: [4]u8 = @bitCast(reference_word);
    transaction(sync_write, 0x0, speed.wr_dummy_bits, &reference, null);
    var back: [4]u8 = .{ 0, 0, 0, 0 };
    transaction(sync_read, 0x0, speed.rd_dummy_bits, null, &back);
    if (@as(u32, @bitCast(back)) != reference_word) return error.NotFound;

    // MR1: the vendor; MR2: the density.
    readRegisters(speed, 0x0, &mr0_1);
    vendor = mr0_1[1] & 0x1F;
    var mr2_3: [2]u8 = undefined;
    readRegisters(speed, 0x2, &mr2_3);
    size = switch (mr2_3[0] & 0x7) {
        0x1 => 4 << 20,
        0x3 => 8 << 20,
        0x5 => 16 << 20,
        0x7 => 32 << 20,
        0x6 => 64 << 20,
        else => 0,
    };
    if (size == 0) return error.NotFound;

    // MSPI2 for the caches: the commands, 32-bit addresses, the dummy
    // cycles, DDR on 16 lines, over AXI.
    reg(cache_sctrl).* |= cache_sram_usr_wcmd | cache_sram_usr_rcmd | cache_usr_saddr_4byte | usr_wr_sram_dummy | usr_rd_sram_dummy | sram_oct;
    reg(sram_dwr_cmd).* = @as(u32, 16 - 1) << 28 | sync_write;
    reg(sram_drd_cmd).* = @as(u32, 16 - 1) << 28 | sync_read;
    setField(cache_sctrl, sram_addr_bitlen_shift, 0x3F, 32 - 1);
    setField(cache_sctrl, sram_wdummy_cyclelen_shift, 0x3F, speed.wr_dummy_bits - 1);
    setField(cache_sctrl, sram_rdummy_cyclelen_shift, 0x3F, speed.rd_dummy_bits - 1);
    reg(smem_ddr).* = (reg(smem_ddr).* & ~(smem_ddr_wdat_swp | smem_ddr_rdat_swp)) | smem_ddr_en | smem_var_dummy;
    reg(sram_cmd).* |= sdummy_wout | scmd_oct | saddr_oct | sdout_oct | sdin_oct | sdin_hex | sdout_hex;
    reg(cache_fctrl).* = (reg(cache_fctrl).* & ~close_axi_inf_en) | axi_req_en;
    reg(ctrl1).* |= aw_splice_en | ar_splice_en;

    if (speed.mhz > slow.mhz) try tune(speed);
    reg(mspi3_ddr).* |= fmem_var_dummy;
    bus_mhz = speed.mhz;
}

/// Both controllers' bus clocks at `speed`.
fn setBusClock(speed: Speed) void {
    const bits = if (speed.divider() == 1) clock_equals_source else clockBits(speed.divider());
    reg(sram_clk).* = bits;
    reg(mspi3_clock).* = bits;
}

// --- the timing -------------------------------------------------------------------

/// A delay line setting: the data pads' delay, and the strobes'.
pub const Delayline = struct { data: u4, dqs: u4 };

/// What the sweeps read back: 128 bytes at 0x80.
const pattern_address = 0x80;
const pattern_words = [32]u32{
    0x7f786655, 0xa5ff005a, 0x3f3c33aa, 0xa5ff5a00, 0x1f1e9955, 0xa5005aff, 0x0f0fccaa, 0xa55a00ff,
    0x07876655, 0xffa55a00, 0x03c333aa, 0xff00a55a, 0x01e19955, 0xff005aa5, 0x00f0ccaa, 0xff5a00a5,
    0x80786655, 0x00a5ff5a, 0xc03c33aa, 0x00a55aff, 0xe01e9355, 0x00ff5aa5, 0xf00fccaa, 0x005affa5,
    0xf8876655, 0x5aa5ff00, 0xfcc333aa, 0x5affa500, 0xfee19955, 0x5a00a5ff, 0x11f0ccaa, 0x5a00ffa5,
};
/// The strobe's phases tried: 67.5, 78.75, 90 and 101.25 degrees.
const phase_count = 4;
/// The delay lines tried, the strobe's from 15 down to 0, then the data's
/// from 1 up to 15.
const delayline_count = 31;
const reads_per_delayline = 100;
/// The most a direct transaction moves.
const fifo_bytes = 64;

fn delaylineOf(index: u32) Delayline {
    return if (index < 16)
        .{ .data = 0, .dqs = @intCast(15 - index) }
    else
        .{ .data = @intCast(index - 15), .dqs = 0 };
}

/// The pattern written at 20 MHz, then the strobe's phase and the delay
/// lines swept at `speed`, the best of each kept and set.
fn tune(speed: Speed) BringUpError!void {
    // At 20 MHz, where the default timing holds, the pattern written.
    setBusClock(slow);
    clearTuning();
    const pattern: [128]u8 = @bitCast(pattern_words);
    var at: u32 = 0;
    while (at < pattern.len) : (at += fifo_bytes) {
        var piece: [fifo_bytes]u8 = pattern[at..][0..fifo_bytes].*;
        transaction(sync_write, pattern_address + at, speed.wr_dummy_bits, &piece, null);
    }

    reg(mspi3_ddr).* &= ~fmem_var_dummy;
    setBusClock(speed);

    // The phase: the first of the longest run that reads it right.
    var phase_good: [phase_count]bool = undefined;
    for (&phase_good, 0..) |*good, phase| {
        setPhase(@intCast(phase));
        good.* = readsBack(speed, &pattern);
    }
    const phases = longestRun(&phase_good);
    if (phases.length == 0) return error.NotTuned;
    tuned_phase = phases.end + 1 - phases.length;

    // The delay line: the middle of the longest run that reads it right
    // every time.
    setPhase(tuned_phase);
    var delayline_good: [delayline_count]bool = undefined;
    for (&delayline_good, 0..) |*good, index| {
        setDelayline(delaylineOf(@intCast(index)));
        good.* = true;
        for (0..reads_per_delayline) |_| {
            if (!readsBack(speed, &pattern)) {
                good.* = false;
                break;
            }
        }
    }
    const delaylines = longestRun(&delayline_good);
    if (delaylines.length < 2) return error.NotTuned;
    tuned_window = delaylines.length;
    tuned_delayline = delaylineOf(delaylines.end - delaylines.length / 2);
    setDelayline(tuned_delayline);
}

/// Whether the pattern reads back right at `speed`.
fn readsBack(speed: Speed, pattern: *const [128]u8) bool {
    var read: [128]u8 = undefined;
    var at: u32 = 0;
    while (at < read.len) : (at += fifo_bytes) {
        @memset(read[at..][0..fifo_bytes], 0);
        transaction(sync_read, pattern_address + at, speed.rd_dummy_bits, null, read[at..][0..fifo_bytes]);
    }
    return std.mem.eql(u8, &read, pattern);
}

const Run = struct { length: u32, end: u32 };

/// The longest run of good settings, and where it ends.
fn longestRun(good: []const bool) Run {
    var best: Run = .{ .length = 0, .end = 0 };
    var length: u32 = 0;
    for (good, 0..) |is_good, index| {
        if (is_good) {
            length += 1;
            if (length > best.length) best = .{ .length = length, .end = @intCast(index) };
        } else {
            length = 0;
        }
    }
    return best;
}

/// Both strobes' phase (bits 1-2 of their pads).
fn setPhase(phase: u32) void {
    setField(pad_dqs0, 1, 0x3, phase);
    setField(pad_dqs1, 1, 0x3, phase);
}

/// The strobes' delays (their 90- and 270-degree delays, bits 7-10 and
/// 17-20) and the other pads' (DLC, bits 4-7).
fn setDelayline(delayline: Delayline) void {
    var pad: usize = pad_first;
    while (pad <= pad_last) : (pad += 4) {
        if (pad == pad_dqs0 or pad == pad_dqs1) {
            setField(pad, 7, 0xF, delayline.dqs);
            setField(pad, 17, 0xF, delayline.dqs);
        } else {
            setField(pad, 4, 0xF, delayline.data);
        }
    }
}

/// The phase and delays back at none.
fn clearTuning() void {
    setPhase(0);
    setDelayline(.{ .data = 0, .dqs = 0 });
}

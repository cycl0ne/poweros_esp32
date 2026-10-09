// SPDX-License-Identifier: MPL-2.0
//! The CPU's clock. The ROM leaves the chip on its 40 MHz crystal; the
//! boot moves it to the CPU PLL (CPLL) at 360 MHz - what a chip before
//! v3.0 runs at - with the memory and system clocks at 180 MHz and the APB
//! at 90, as ESP-IDF v6.1 does (esp_hw_support/port/esp32p4/rtc_clk.c):
//!
//! 1. The CPLL powered up (PMU), then calibrated: its reference divider,
//!    feedback divider and charge pump set over the analog bus (regi2c),
//!    and the calibration waited for. From chip v0.1 on the feedback
//!    divider's bits 2 and 3 are swapped, so its value depends on the
//!    revision in eFuse.
//! 2. The dividers raised from the slowest clock up - APB, system, memory,
//!    CPU - each taken over by SOC_CLK_DIV_UPDATE, so no clock is ever
//!    faster than it may be; then the root clock switched to the CPLL,
//!    last, as the update does not cover that switch.
//!
//! The peripherals this kernel uses keep their own sources - the UART and
//! SYSTIMER run from the crystal - so nothing else changes speed.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const regi2c = @import("regi2c.zig");

/// The clock the CPU runs at.
pub var cpu_hz: u32 = hardware.XTAL_HZ;

/// PMU_IMM_HP_CK_POWER: the CPLL and its analog bus powered, its clock
/// gate open.
const pmu_imm_hp_ck_power = hardware.map.PMU + 0x0CC;
const tie_high_xpd_cpll: u32 = 1 << 27;
const tie_high_xpd_cpll_i2c: u32 = 1 << 23;
const tie_high_global_cpll_icg: u32 = 1 << 17;

/// HP_SYS_CLKRST: the CPLL's calibration (ANA_PLL_CTRL0) and the root
/// clock's dividers, each the divider minus one.
const ana_pll_ctrl0 = hardware.map.HP_SYS_CLKRST + 0x0BC;
const cpu_pll_cal_end: u32 = 1 << 2;
const cpu_pll_cal_stop: u32 = 1 << 3;
const root_clk_ctrl0 = hardware.map.HP_SYS_CLKRST + 0x004;
const soc_clk_div_update: u32 = 1 << 4;
const cpu_clk_div_shift = 5;
const root_clk_ctrl1 = hardware.map.HP_SYS_CLKRST + 0x008;
const mem_clk_div_shift = 0;
const sys_clk_div_shift = 24;
const root_clk_ctrl2 = hardware.map.HP_SYS_CLKRST + 0x00C;
const apb_clk_div_shift = 16;

/// LP_CLKRST_HP_CLK_CTRL: the root clock's source, 0 the crystal, 1 the
/// CPLL.
const hp_clk_ctrl = hardware.map.LP_CLKRST + 0x040;
const root_src_mask: u32 = 0x3;
const root_src_cpll: u32 = 1;

/// The CPLL's registers on the analog bus.
const cpll_oc_ref_div = 2;
const cpll_oc_div_7_0 = 3;
const cpll_oc_dcur = 6;

/// EFUSE_RD_MAC_SYS_2: the chip revision - minor in bits 0-3, major's low
/// bits in 4-5 and its high bit in 23.
const efuse_rd_mac_sys_2 = hardware.map.EFUSE + 0x4C;

pub const cpll_hz: u32 = 360_000_000;

/// The chip revision, major * 100 + minor (v1.3 is 103).
pub fn chipRevision() u32 {
    const word = reg(efuse_rd_mac_sys_2).*;
    const minor = word & 0xF;
    const major = ((word >> 23) & 1) << 2 | ((word >> 4) & 0x3);
    return major * 100 + minor;
}

/// The CPU on the CPLL at 360 MHz.
pub fn init() void {
    // The root clock's source is in the LP domain, which a reset of the
    // digital part alone (USB, JTAG, software) keeps, while that reset
    // puts the dividers back: the crystal first, then all of it set up
    // as after power-on.
    reg(hp_clk_ctrl).* &= ~root_src_mask;
    reg(pmu_imm_hp_ck_power).* |= tie_high_xpd_cpll | tie_high_xpd_cpll_i2c;
    reg(pmu_imm_hp_ck_power).* |= tie_high_global_cpll_icg;

    // 360 MHz from the 40 MHz crystal.
    const feedback: u8 = if (chipRevision() >= 1) 9 else 5;
    const dchgp: u8 = 5;
    const dcur: u8 = 3;
    reg(ana_pll_ctrl0).* &= ~cpu_pll_cal_stop;
    regi2c.write(.cpu_pll, cpll_oc_ref_div, dchgp << 4);
    regi2c.write(.cpu_pll, cpll_oc_div_7_0, feedback);
    regi2c.write(.cpu_pll, cpll_oc_dcur, 1 << 6 | 3 << 4 | dcur);
    var spins: u32 = 0;
    while (reg(ana_pll_ctrl0).* & cpu_pll_cal_end == 0 and spins < 1_000_000) spins += 1;
    @import("sdk").hardware.cpu.spinCycles(400); // 10 us at 40 MHz
    reg(ana_pll_ctrl0).* |= cpu_pll_cal_stop;

    // CPLL 360 -> CPU /1 = 360 -> MEM /2 = 180 -> SYS /1 = 180 -> APB /2 = 90,
    // the slowest first.
    setField(root_clk_ctrl2, apb_clk_div_shift, 2 - 1);
    update();
    setField(root_clk_ctrl1, sys_clk_div_shift, 1 - 1);
    update();
    setField(root_clk_ctrl1, mem_clk_div_shift, 2 - 1);
    update();
    setField(root_clk_ctrl0, cpu_clk_div_shift, 1 - 1);
    update();
    reg(hp_clk_ctrl).* = (reg(hp_clk_ctrl).* & ~root_src_mask) | root_src_cpll;
    cpu_hz = cpll_hz;
}

/// An 8-bit divider field set, the rest of the register kept.
fn setField(address: usize, comptime shift: u5, value: u32) void {
    const field: u32 = @as(u32, 0xFF) << shift;
    reg(address).* = (reg(address).* & ~field) | (value << shift);
}

/// The new dividers taken over.
fn update() void {
    reg(root_clk_ctrl0).* |= soc_clk_div_update;
    while (reg(root_clk_ctrl0).* & soc_clk_div_update != 0) {}
}

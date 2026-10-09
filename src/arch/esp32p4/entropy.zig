// SPDX-License-Identifier: MPL-2.0
//! The random number generator's noise source: the SAR ADC, set sampling
//! at boot so that RNG_DATA is truly random from the first task on.
//!
//! The generator mixes the noise of the analog clocks that run, and the
//! SAR ADC's is the one there is without a radio. So init clocks the
//! ADC's digital controller from the crystal, powers the analog bus's
//! peripheral part (PMU), gives SAR ADC 1 its start-up code over that bus,
//! and has the controller sample ADC 1's channel 10 - an internal voltage,
//! never a pin - on a timer, over and over. The samples go nowhere; the
//! noise of taking them is what the generator draws on. As ESP-IDF v6.1
//! does it (bootloader_random_esp32p4.c).
//!
//! The controller stays on for good. A driver that wants the ADC for
//! readings takes it over later and must keep it sampling, or the
//! generator falls back to timing noise alone.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const map = hardware.map;
const regi2c = @import("regi2c.zig");

// HP_SYS_CLKRST: the ADC's reset, its bus clock, its function clock with
// source (bits 30-31 of CTRL22, 0 the crystal) and divider (bits 1-24 of
// CTRL23: integer, numerator, denominator).
const hp_rst_en2 = map.HP_SYS_CLKRST + 0x0C8;
const rst_en_adc: u32 = 1 << 10;
const soc_clk_ctrl2 = map.HP_SYS_CLKRST + 0x01C;
const adc_apb_clk_en: u32 = 1 << 5;
const peri_clk_ctrl22 = map.HP_SYS_CLKRST + 0x09C;
const adc_clk_src_sel: u32 = 0x3 << 30;
const peri_clk_ctrl23 = map.HP_SYS_CLKRST + 0x0A0;
const adc_clk_en: u32 = 1 << 0;
const adc_clk_div_fields: u32 = 0xFF_FFFF << 1;

// PMU_RF_PWC: the analog bus's peripheral part powered (XPD_PERIF_I2C)
// and out of reset (PERIF_I2C_RSTB).
const pmu_rf_pwc = map.PMU + 0x15C;
const perif_i2c_rstb: u32 = 1 << 26;
const xpd_perif_i2c: u32 = 1 << 27;

// The ADC's digital controller.
const ctrl_reg = map.ADC + 0x00;
const sar_clk_gated: u32 = 1 << 5;
const sar_clk_div_shift = 6;
const sar1_patt_len_shift = 14;
const xpd_sar1_force_shift = 26;
const ctrl2 = map.ADC + 0x04;
const timer_sel: u32 = 1 << 11;
const timer_target_shift = 12;
const timer_en: u32 = 1 << 24;
const sar1_patt_tab1 = map.ADC + 0x18;

// LP_ADC: ADC 1 given to the digital controller.
const meas1_ctrl2 = map.LP_ADC + 0x0C;
const meas1_start_force: u32 = 1 << 18;
const sar1_en_pad_force: u32 = 1 << 31;
const meas1_mux = map.LP_ADC + 0x10;
const sar1_dig_force: u32 = 1 << 31;

// SAR ADC 1 on the analog bus: its start-up code, and the two test bits
// that leave it measuring.
const sar1_initial_code_low = 0x0;
const sar1_initial_code_high = 0x1;
const dtest_ent_vdd_grp1 = 0x9;
const sar1_initial_code: u16 = 2166;

/// One pattern entry: channel 10 at 12 dB attenuation (bits 2-5 the
/// channel, 0-1 the attenuation).
const pattern: u32 = 10 << 2 | 3;

pub fn init() void {
    reg(hp_rst_en2).* |= rst_en_adc;
    reg(hp_rst_en2).* &= ~rst_en_adc;
    reg(soc_clk_ctrl2).* |= adc_apb_clk_en;
    reg(peri_clk_ctrl23).* |= adc_clk_en;
    reg(peri_clk_ctrl22).* &= ~adc_clk_src_sel;
    reg(ctrl_reg).* |= sar_clk_gated;
    reg(peri_clk_ctrl23).* &= ~adc_clk_div_fields;

    reg(pmu_rf_pwc).* &= ~perif_i2c_rstb;
    hardware.cpu.spinCycles(400);
    reg(pmu_rf_pwc).* |= xpd_perif_i2c;
    reg(pmu_rf_pwc).* |= perif_i2c_rstb;

    regi2c.writeMask(.sar_adc, dtest_ent_vdd_grp1, 3, 0, 0);
    regi2c.writeMask(.sar_adc, dtest_ent_vdd_grp1, 4, 4, 1);
    regi2c.writeMask(.sar_adc, sar1_initial_code_high, 3, 0, @truncate(sar1_initial_code >> 8));
    regi2c.writeMask(.sar_adc, sar1_initial_code_low, 7, 0, @truncate(sar1_initial_code));

    // The pattern table's first four entries all channel 10, one used.
    reg(sar1_patt_tab1).* = pattern << 18 | pattern << 12 | pattern << 6 | pattern;
    setField(ctrl_reg, sar1_patt_len_shift, 0xF, 0);

    reg(meas1_mux).* |= sar1_dig_force;
    reg(meas1_ctrl2).* |= meas1_start_force | sar1_en_pad_force;

    // Powered on, the ADC clock the controller's divided by 15, a
    // conversion every 100 of its cycles, for good.
    reg(ctrl_reg).* |= sar_clk_gated;
    setField(ctrl_reg, xpd_sar1_force_shift, 0x3, 3);
    setField(ctrl_reg, sar_clk_div_shift, 0xFF, 15);
    setField(ctrl2, timer_target_shift, 0xFFF, 100);
    reg(ctrl2).* |= timer_sel | timer_en;
}

fn setField(address: usize, comptime shift: u5, mask: u32, value: u32) void {
    reg(address).* = (reg(address).* & ~(mask << shift)) | (value << shift);
}

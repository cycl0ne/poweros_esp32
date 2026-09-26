// SPDX-License-Identifier: MPL-2.0
//! The random number generator's noise source: the SAR ADCs, set running
//! at boot so that RNG_DATA is truly random from the first read.
//!
//! The generator mixes the noise of whichever analog clocks run. The
//! radio is one, but it runs only under a Wi-Fi driver; the other is the
//! SAR ADC. So init gives the generator its clock and the 8 MHz
//! oscillator, then has the ADCs' digital controller sample both units
//! on a timer, over and over, each on its reserved channel 10, which
//! reads an internal voltage and never a pin. The samples go nowhere; the
//! noise of taking them is what the generator draws on. The analog side
//! is reached over the chip's internal I2C bus, through the boot ROM's
//! regi2c calls, as clock.zig reaches the PLL.
//!
//! The controller stays on for good. A driver that wants the ADCs for
//! readings takes them over later and must keep them sampling, or the
//! generator falls back to timing noise alone.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const map = hardware.map;
const system = hardware.system;

// SYSCON
const wifi_clk_en = map.SYSCON + 0x14;
const wifi_clk_rng_en: u32 = 1 << 15;

// RTC_CNTL
const rtc_clk_conf = map.RTC_CNTL + 0x74;
const dig_clk8m_en: u32 = 1 << 10;

// SENS: which controller runs each ADC
const sar_meas1_ctrl2 = map.SENS + 0x0C; // SAR1_EN_PAD_FORCE [31], MEAS1_START_FORCE [18]
const sar_meas1_mux = map.SENS + 0x10; // SAR1_DIG_FORCE [31]
const sar_meas2_ctrl2 = map.SENS + 0x30; // SAR2_EN_PAD_FORCE [31], MEAS2_START_FORCE [18]
const sar_meas2_mux = map.SENS + 0x34; // SAR2_RTC_FORCE [31]

// APB_SARADC: the digital controller
const adc_ctrl = map.APB_SARADC + 0x00;
const adc_ctrl2 = map.APB_SARADC + 0x04;
const sar1_patt_tab1 = map.APB_SARADC + 0x18;
const sar2_patt_tab1 = map.APB_SARADC + 0x28;
const adc_arb_ctrl = map.APB_SARADC + 0x38;
const adc_clkm_conf = map.APB_SARADC + 0x70;

// Analog I2C master
const ana_config = 0x6000_E044;
const i2c_sar: u32 = 1 << 18;
const ana_config2 = 0x6000_E048;
const ana_sar_cfg2: u32 = 1 << 16;

// The SAR ADC's analog registers.
const i2c_sar_adc = 0x69;
const host_id = 1;
const regi2c_write_mask: *const fn (block: u8, host: u8, reg_add: u8, msb: u8, lsb: u8, data: u8) callconv(.c) void = @ptrFromInt(0x4000_5D6C);

/// A pattern table entry: channel 10 at 12 dB attenuation.
const pattern: u32 = 10 << 2 | 3;

/// The ADCs sampling, the generator's clock on. Once, at boot, before
/// anything reads RNG_DATA.
pub fn init() void {
    reg(wifi_clk_en).* |= wifi_clk_rng_en;
    reg(rtc_clk_conf).* |= dig_clk8m_en;
    system.enable(.apb_saradc);

    // The controller's clock: APB (selector 2), divided by 3, gated on.
    setField(adc_clkm_conf, 21, 0x3, 2);
    setField(adc_clkm_conf, 0, 0xFF, 3);
    setField(adc_clkm_conf, 8, 0x3F, 0);
    setField(adc_clkm_conf, 14, 0x3F, 0);
    reg(adc_ctrl).* |= 1 << 6; // SAR_CLK_GATED

    // The analog side: the bus to it opened, the test output off, the
    // internal reference as the input.
    reg(ana_config).* &= ~i2c_sar;
    reg(ana_config2).* |= ana_sar_cfg2;
    regi2c_write_mask(i2c_sar_adc, host_id, 0x7, 1, 0, 0); // DTEST_RTC
    regi2c_write_mask(i2c_sar_adc, host_id, 0x7, 2, 2, 1); // ENT_TSENS
    regi2c_write_mask(i2c_sar_adc, host_id, 0x7, 4, 4, 1); // ENCAL_REF

    // One entry per unit: unit 1's is entry 0, unit 2's entry 1.
    setField(sar1_patt_tab1, 18, 0x3F, pattern);
    setField(sar2_patt_tab1, 12, 0x3F, pattern);
    setField(adc_ctrl, 15, 0xF, 0); // SAR1_PATT_LEN: one entry
    setField(adc_ctrl, 19, 0xF, 0); // SAR2_PATT_LEN: one entry
    setField(adc_ctrl, 3, 0x3, 1); // WORK_MODE: both units
    reg(adc_ctrl).* |= 1 << 25; // DATA_SAR_SEL

    // Unit 1 under the digital controller, unit 2 through the arbiter,
    // which takes turns; the sleep controller let go of unit 2.
    reg(sar_meas1_mux).* |= 1 << 31;
    reg(sar_meas1_ctrl2).* |= 1 << 18 | 1 << 31;
    reg(sar_meas2_mux).* &= ~(@as(u32, 1) << 31);
    reg(adc_arb_ctrl).* &= ~(@as(u32, 1) << 5 | 1 << 12);

    // Sampling on the controller's timer.
    setField(adc_ctrl, 7, 0xFF, 3); // SAR_CLK_DIV
    setField(adc_ctrl2, 12, 0xFFF, 70); // TIMER_TARGET
    reg(adc_ctrl2).* |= 1 << 11 | 1 << 24; // TIMER_SEL, TIMER_EN
}

fn setField(addr: usize, comptime shift: u5, comptime mask: u32, value: u32) void {
    const register = reg(addr);
    register.* = (register.* & ~(mask << shift)) | ((value & mask) << shift);
}

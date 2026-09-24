// SPDX-License-Identifier: MPL-2.0
//! CPU clock: move the core from the 40 MHz crystal onto the 480 MHz BBPLL at
//! 240 MHz. Follows ESP-IDF's rtc_clk sequence for the ESP32-S3.
//!
//! Nothing else is touched. The UARTs run from the crystal (serial.device's
//! uart.zig and exec's rawio/_rawio.zig set them up after this), so the switch
//! doesn't change their rates.

const reg = @import("sdk").hardware.mmio.reg;
const timer = @import("timer.zig");

/// The CPU clock after init, and the crystal: the SDK's, which drivers read.
pub const cpu_hz = @import("sdk").hardware.CPU_HZ;
pub const xtal_hz = @import("sdk").hardware.XTAL_HZ;

// SYSTEM
const system_cpu_per_conf = @import("sdk").hardware.map.SYSTEM + 0x10; // CPUPERIOD_SEL [1:0], PLL_FREQ_SEL [2]
const system_sysclk_conf = 0x600C_0060; // PRE_DIV_CNT [9:0], SOC_CLK_SEL [11:10]

// RTC_CNTL
const rtc_options0 = @import("sdk").hardware.map.RTC_CNTL;
const bb_i2c_force_pd: u32 = 1 << 6;
const bbpll_i2c_force_pd: u32 = 1 << 8;
const bbpll_force_pd: u32 = 1 << 10;
const rtc_date = 0x6000_81FC; // SLAVE_PD [18:13]

// Analog I2C master
const i2c_mst_ana_conf0 = 0x6000_E040;
const bbpll_stop_force_high: u32 = 1 << 2;
const bbpll_stop_force_low: u32 = 1 << 3;
const bbpll_cal_done: u32 = 1 << 24;
const ana_config = 0x6000_E044;
const ana_i2c_bbpll: u32 = 1 << 17;

// Analog register blocks, written through the ROM's regi2c helpers.
const i2c_bbpll = 0x66;
const i2c_dig_reg = 0x6D;
const host_id = 1;

const regi2c_write: *const fn (block: u8, host: u8, reg_add: u8, data: u8) callconv(.c) void = @ptrFromInt(0x4000_5D60);
const regi2c_write_mask: *const fn (block: u8, host: u8, reg_add: u8, msb: u8, lsb: u8, data: u8) callconv(.c) void = @ptrFromInt(0x4000_5D6C);
const ets_update_cpu_frequency: *const fn (ticks_per_us: u32) callconv(.c) void = @ptrFromInt(0x4000_1A4C);

/// Core voltage for 240 MHz: ESP-IDF's default when the eFuse holds no
/// calibrated value.
const dbias_240m = 28;

/// False if the BBPLL never reported calibration done (QEMU does not model it).
pub var pll_calibrated = false;

pub fn init() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    // Power up the BBPLL and the analog bus that configures it.
    reg(ana_config).* &= ~ana_i2c_bbpll;
    reg(rtc_options0).* &= ~(bb_i2c_force_pd | bbpll_i2c_force_pd | bbpll_force_pd);

    configureBbpll480();
    switchCpuTo240();
    ets_update_cpu_frequency(cpu_hz / 1_000_000);
}

/// 40 MHz crystal -> 480 MHz. Values from ESP-IDF clk_ll_bbpll_set_config.
fn configureBbpll480() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    setField(system_cpu_per_conf, 2, 0x1, 1); // PLL_FREQ_SEL: 480 MHz

    reg(i2c_mst_ana_conf0).* &= ~bbpll_stop_force_high;
    reg(i2c_mst_ana_conf0).* |= bbpll_stop_force_low;

    regi2c_write(i2c_bbpll, host_id, 4, 0x6B); // MODE_HF
    regi2c_write(i2c_bbpll, host_id, 2, 5 << 4 | 0); // OC_REF_DIV: dchgp 5, div_ref 0
    regi2c_write(i2c_bbpll, host_id, 3, 8); // OC_DIV_7_0
    regi2c_write_mask(i2c_bbpll, host_id, 5, 2, 0, 0); // OC_DR1
    regi2c_write_mask(i2c_bbpll, host_id, 5, 6, 4, 0); // OC_DR3
    regi2c_write(i2c_bbpll, host_id, 6, 1 << 6 | 3 << 4 | 3); // OC_DCUR: dlref 1, dhref 3, dcur 3
    regi2c_write_mask(i2c_bbpll, host_id, 9, 1, 0, 3); // OC_VCO_DBIAS

    // Silicon finishes in microseconds; QEMU never sets the bit.
    const deadline = timer.now() + 1000 * (timer.systimer_hz / 1_000_000);
    while (reg(i2c_mst_ana_conf0).* & bbpll_cal_done == 0 and timer.now() < deadline) {}
    pll_calibrated = reg(i2c_mst_ana_conf0).* & bbpll_cal_done != 0;
    delayUs(10);

    reg(i2c_mst_ana_conf0).* &= ~bbpll_stop_force_low;
    reg(i2c_mst_ana_conf0).* |= bbpll_stop_force_high;
}

/// APB stays at 80 MHz in hardware once the CPU runs from the PLL. The flash
/// (MSPI) clock follows the CPU clock source, so it runs, like all of the
/// boot code (kernel_early), from IRAM before the code in flash is mapped;
/// psram.init then sets the MSPI clocks for both.
fn switchCpuTo240() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    // Raise the core voltage before speeding up.
    regi2c_write_mask(i2c_dig_reg, host_id, 4, 4, 0, dbias_240m); // EXT_RTC_DREG
    regi2c_write_mask(i2c_dig_reg, host_id, 6, 4, 0, dbias_240m); // EXT_DIG_DREG
    delayUs(40);
    setField(rtc_date, 13, 0x3F, 0); // SLAVE_PD: all LDO slaves on

    setField(system_cpu_per_conf, 0, 0x3, 2); // CPUPERIOD_SEL: 240 MHz
    setField(system_sysclk_conf, 0, 0x3FF, 0); // PRE_DIV_CNT: divide by 1
    setField(system_sysclk_conf, 10, 0x3, 1); // SOC_CLK_SEL: PLL
}

/// The `mask`-wide field at bit `shift` of the register at `addr`.
fn setField(addr: usize, comptime shift: u5, mask: u32, value: u32) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const r = reg(addr);
    r.* = (r.* & ~(mask << shift)) | (value << shift);
}

/// Busy-wait on SYSTIMER; there are no interrupts yet.
fn delayUs(us: u32) linksection(".iram.text") void {
    @setRuntimeSafety(false);
    const end = timer.now() + @as(u64, us) * (timer.systimer_hz / 1_000_000);
    while (timer.now() < end) {}
}

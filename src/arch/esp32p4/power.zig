// SPDX-License-Identifier: MPL-2.0
//! The core's supply. The ROM runs the chip's digital core from its own
//! internal regulator; a board feeds it from an external buck converter
//! the chip switches on (EN_DCDC) and steers (FB_DCDC) through its DC-DC
//! controller (the PMU's DCM). The boot hands the core over to that
//! converter, at about 1.25 V, before the clocks go up - as ESP-IDF
//! v6.1's rtc_clk_init does:
//!
//! 1. The analog bus's regulator controls forced to software and the
//!    bias block's force bits cleared.
//! 2. The internal regulator kept on for the moment, at its level for the
//!    running chip: the factory's measurement (eFuse) plus 16, about
//!    1.15 V, or 24 where the chip has none; and the always-on (LP)
//!    domain's regulator at its own measured level plus 20, near the
//!    converter's voltage, or 29 - the analog bus step above leaves that
//!    domain on it.
//! 3. The converter switched on (DCM_CTRL's on request), its switch let
//!    go, and its set-point for the running chip 27 - higher if the
//!    voltage monitor's reading of the core asks for it - with its mode
//!    and the bias generator for the running chip; the PMU given the
//!    regulator's level.
//! 4. A millisecond for the converter to settle, then the internal
//!    regulator off.
//!
//! This is the v1.x chips' sequence, which this kernel is built for; from
//! v3.1 on the converter's feedback resistor is forced off around the
//! switch as well.
//!
//! Left where the ROM puts it, the set-point is 20: on a board whose
//! converter has no feedback divider of its own - the CrowPanel's - the
//! core then runs low, and the PSRAM controller, clocked at 400 MHz for a
//! 200 MHz PSRAM, answers a cache fill with a bus error now and then.
//!
//! From ESP-IDF v6.1's esp_hw_support/port/esp32p4/rtc_clk_init.c,
//! pmu_param.c and soc/esp32p4/register/hw_ver1/soc/pmu_reg.h.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const map = hardware.map;
const regi2c = @import("regi2c.zig");
const cpu = hardware.cpu;

/// PMU_HP_ACTIVE_BIAS: the converter's set-point (bits 18-22) and mode
/// (23-24), and the bias generator on (25), while the chip runs.
const hp_active_bias = map.PMU + 0x18;
const xpd_bias: u32 = 1 << 25;
const dcm_vset_shift = 18;
const dcm_vset_mask: u32 = 0x1F << dcm_vset_shift;
const dcm_mode_shift = 23;
const dcm_mode_mask: u32 = 0x3 << dcm_mode_shift;
/// PMU_HP_ACTIVE_HP_REGULATOR0: the voltage monitor's reading of what the
/// core needs (bits 9-13), the PMU in charge of the level (14), the
/// internal regulator on (18), its level (27-31).
const hp_active_regulator0 = map.PMU + 0x28;
const dbias_vol_shift = 9;
const dbias_sel: u32 = 1 << 14;
const regulator_xpd: u32 = 1 << 18;
const dbias_shift = 27;
const dbias_mask: u32 = 0x1F << dbias_shift;
/// PMU_POWER_DCDC_SWITCH: the converter's switch forced on or off.
const dcdc_switch = map.PMU + 0x10C;
const dcdc_switch_force_pu: u32 = 1 << 0;
const dcdc_switch_force_pd: u32 = 1 << 1;
/// PMU_DCM_CTRL: ask the converter on; its done signal forced.
const dcm_ctrl = map.PMU + 0x204;
const dcdc_on_req: u32 = 1 << 0;
const dcdc_done_force: u32 = 1 << 7;

/// The converter's set-point while the chip runs: about 1.25 V.
const active_dcm_vset: u32 = 27;
/// The converter's mode while the chip runs.
const active_dcm_mode: u32 = 1;
/// The internal regulator's level without a measurement of the factory's.
const default_hp_dbias: u32 = 24;

/// PMU_HP_SLEEP_LP_REGULATOR0: the always-on domain's regulator while
/// the chip runs - its level in bits 27-31.
const lp_active_regulator0 = map.PMU + 0x9C;
/// The always-on domain's level without a measurement of the factory's.
const default_lp_dbias: u32 = 29;

/// EFUSE_RD_MAC_SYS_2: the eFuse block's version; EFUSE_RD_MAC_SYS_4:
/// the factory's levels for the running chip, the core's in bits 16-19,
/// the always-on domain's in 20-23.
const efuse_rd_mac_sys_2 = map.EFUSE + 0x4C;
const efuse_rd_mac_sys_4 = map.EFUSE + 0x54;

/// The internal regulator's level for the running chip.
fn activeDbias() u32 {
    const measured = (reg(efuse_rd_mac_sys_4).* >> 16) & 0xF;
    if (measured == 0) return default_hp_dbias;
    return @min(measured + 16, 31);
}

/// The always-on domain's regulator level for the running chip; the
/// factory measured it from block version 2 on (100 excepted).
fn activeLpDbias() u32 {
    const sys_2 = reg(efuse_rd_mac_sys_2).*;
    const blk_version = ((sys_2 >> 11) & 0x3) * 100 + ((sys_2 >> 8) & 0x7);
    if (blk_version < 2 or blk_version == 100) return default_lp_dbias;
    const measured = (reg(efuse_rd_mac_sys_4).* >> 20) & 0xF;
    if (measured == 0) return default_lp_dbias;
    return @min(measured + 16 + 4, 31);
}

/// The core handed from the internal regulator to the board's converter.
pub fn init() void {
    regi2c.writeMask(.dig_reg, 10, 0, 0, 1); // force the RTC regulator's control
    regi2c.writeMask(.dig_reg, 10, 1, 1, 1); // and the digital one's
    regi2c.writeMask(.dig_reg, 13, 2, 2, 0);
    regi2c.writeMask(.dig_reg, 13, 3, 3, 0);
    regi2c.writeMask(.bias, 4, 0, 0, 0);
    regi2c.writeMask(.bias, 4, 1, 1, 0);
    regi2c.writeMask(.bias, 4, 2, 2, 0);
    regi2c.writeMask(.bias, 4, 3, 3, 0);

    const regulator = reg(hp_active_regulator0);
    regulator.* = (regulator.* & ~dbias_mask) | regulator_xpd | activeDbias() << dbias_shift;
    const lp_regulator = reg(lp_active_regulator0);
    lp_regulator.* = (lp_regulator.* & ~dbias_mask) | activeLpDbias() << dbias_shift;

    const reading = (regulator.* >> dbias_vol_shift) & 0x1F;
    const vset = @max(active_dcm_vset, reading);
    reg(dcm_ctrl).* = (reg(dcm_ctrl).* & ~dcdc_done_force) | dcdc_on_req;
    reg(dcdc_switch).* &= ~(dcdc_switch_force_pu | dcdc_switch_force_pd);
    const bias = reg(hp_active_bias);
    bias.* = (bias.* & ~(dcm_vset_mask | dcm_mode_mask)) | vset << dcm_vset_shift |
        active_dcm_mode << dcm_mode_shift | xpd_bias;
    regulator.* |= dbias_sel;
    cpu.spinCycles(40_000); // a millisecond at the crystal's 40 MHz
    regulator.* &= ~regulator_xpd;
}

/// The converter's set-point and the internal regulator's level as they
/// stand, for the boot's log.
pub const State = struct { vset: u32, dbias: u32, internal_on: bool, lp_dbias: u32 };

pub fn state() State {
    const regulator = reg(hp_active_regulator0).*;
    return .{
        .vset = (reg(hp_active_bias).* & dcm_vset_mask) >> dcm_vset_shift,
        .dbias = (regulator & dbias_mask) >> dbias_shift,
        .internal_on = regulator & regulator_xpd != 0,
        .lp_dbias = (reg(lp_active_regulator0).* & dbias_mask) >> dbias_shift,
    };
}

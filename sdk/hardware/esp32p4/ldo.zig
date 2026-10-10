// SPDX-License-Identifier: MIT
//! The chip's four adjustable LDO regulators, VO1 to VO4, which a board
//! wires to whatever needs a supply of its own: the PSRAM's 1.8 V, the
//! MIPI D-PHY's 2.5 V, an SD card's 3.3 V. Each is a control word and an
//! analog word in the PMU.
//!
//! The output is Vref x (1 + mul / 4) with Vref = 0.5 V + 0.05 V x dref up
//! to dref 8 and 1.0 V + 0.1 V x (dref - 9) from 9 on; `set` takes the
//! dref (0 to 15) and mul (0 to 7) whose result is nearest the voltage
//! asked for. Where the factory measured a channel (eFuse block version 1
//! on), its gain, offset and multiplier error go into that result: VO3's,
//! here, whose measurements are in EFUSE_RD_MAC_SYS_3; the others are set
//! by the formula alone.
//!
//! Turning a channel on follows ESP-IDF v6.1's esp_ldo_acquire_channel:
//! the current limit on while the output is set and switched on, and the
//! output owned by software rather than by the PMU's power states.
//!
//! From ESP-IDF v6.1's soc/esp32p4/register/hw_ver1/soc/pmu_reg.h and
//! hal/ldo_ll.h.

const reg = @import("mmio.zig").reg;
const map = @import("map.zig");

/// Each channel's control word; its analog word is the next one.
const control_words = [4]usize{ map.PMU + 0x1B8, map.PMU + 0x1D0, map.PMU + 0x1C0, map.PMU + 0x1D8 };

// The control word.
const force_tieh_sel: u32 = 1 << 7;
const xpd: u32 = 1 << 8;
const tieh_sel_mask: u32 = 0x7 << 9;
const tieh: u32 = 1 << 14;
// The analog word.
const mul_shift = 23;
const mul_mask: u32 = 0x7 << mul_shift;
const en_vdet: u32 = 1 << 26;
const en_cur_lim: u32 = 1 << 27;
const dref_shift = 28;
const dref_mask: u32 = 0xF << dref_shift;

/// EFUSE_RD_MAC_SYS_2: the block version; _3: VO3's gain, offset and
/// multiplier error.
const efuse_rd_mac_sys_2 = map.EFUSE + 0x4C;
const efuse_rd_mac_sys_3 = map.EFUSE + 0x50;

/// What the factory measured of a channel, in thousandths: the gain of
/// its reference, its offset in millivolts, the gain of its multiplier.
const Calibration = struct { gain: i64 = 1000, offset: i64 = 0, mul_gain: i64 = 1000 };

fn calibrationOf(channel: u32) Calibration {
    if (channel != 3) return .{};
    const sys_2 = reg(efuse_rd_mac_sys_2).*;
    const blk_version = ((sys_2 >> 11) & 0x3) * 100 + ((sys_2 >> 8) & 0x7);
    if (blk_version < 1) return .{};
    const word = reg(efuse_rd_mac_sys_3).*;
    const gain: i64 = (word >> 6) & 0xFF;
    const offset: i64 = (word >> 14) & 0x3F;
    const mul_gain: i64 = (word >> 20) & 0x3F;
    var measured: Calibration = .{};
    if (gain != 0) measured.gain = if (gain & 0x80 != 0) 975 - (gain & 0x7F) else gain + 975;
    if (offset != 0) measured.offset = if (offset & 0x20 != 0) -(offset & 0x1F) - 3 else offset - 3;
    if (mul_gain != 0) measured.mul_gain = if (mul_gain & 0x20 != 0) 990 - (mul_gain & 0x1F) else mul_gain + 990;
    return measured;
}

/// The millivolts dref and mul give on a channel measured as `measured`.
fn output(measured: Calibration, dref: u32, mul: u32) i64 {
    const vref: i64 = if (dref < 9) 500 + 50 * @as(i64, dref) else 1000 + 100 * (@as(i64, dref) - 9);
    const base = @divTrunc(vref * measured.gain, 1000) + measured.offset;
    return @divTrunc(base * (1_000_000 + 250 * @as(i64, mul) * measured.mul_gain), 1_000_000);
}

/// Channel `channel` (1 to 4) on at the voltage nearest `millivolts`;
/// false for a channel there is not.
pub fn set(channel: u32, millivolts: u32) bool {
    if (channel < 1 or channel > 4) return false;
    const control = reg(control_words[channel - 1]);
    const analog = reg(control_words[channel - 1] + 4);
    const measured = calibrationOf(channel);
    var best_dref: u32 = 0;
    var best_mul: u32 = 0;
    var best_error: i64 = 1 << 40;
    for (0..16) |dref| {
        for (0..8) |mul| {
            const off = output(measured, @intCast(dref), @intCast(mul)) - millivolts;
            const error_mv = if (off < 0) -off else off;
            if (error_mv < best_error) {
                best_error = error_mv;
                best_dref = @intCast(dref);
                best_mul = @intCast(mul);
            }
        }
    }
    analog.* |= en_cur_lim;
    if (millivolts == 3300) control.* |= tieh else control.* &= ~tieh;
    analog.* = (analog.* & ~(mul_mask | dref_mask)) | best_mul << mul_shift | best_dref << dref_shift;
    control.* = (control.* & ~tieh_sel_mask) | force_tieh_sel;
    analog.* |= en_vdet;
    control.* |= xpd;
    analog.* &= ~en_cur_lim;
    return true;
}

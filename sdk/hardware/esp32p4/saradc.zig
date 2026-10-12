// SPDX-License-Identifier: MIT
//! The SAR ADC's first unit, as the kernel and battery.resource share it:
//! which pad is which of its channels, what the chip's eFuse holds of its
//! calibration at 12 dB, the last sample its digital controller took, and
//! the millivolts that sample is.
//!
//! The kernel keeps the unit sampling for the random number generator
//! (src/arch/esp32p4/entropy.zig) - on a board that measures its battery
//! on one of the unit's pads, that pad, at 12 dB, with the calibrated
//! start-up code - so a reading is the last sample, there to be read at
//! any time.
//!
//! **The calibration** is ESP-IDF v6.1's curve fitting
//! (esp_adc/adc_cali_curve_fitting.c, efuse/esp32p4/esp_efuse_rtc_calib.c)
//! for chips before v3: each channel's sample corrected by its own
//! offset, a straight line through one point the factory measured -
//! 2300 mV, and the sample it gave - and a first-order correction of it.
//! A chip whose BLOCK2 was never given its calibration (its block version
//! 0) has none, and its samples are not turned into millivolts.

const reg = @import("mmio.zig").reg;
const map = @import("map.zig");

/// The eFuse controller's blocks as read: BLOCK1's third word (the
/// version of BLOCK2), BLOCK2 (SYS_PART1) and BLOCK10 (SYS_PART2).
const efuse_mac_sys_2 = map.EFUSE + 0x4C;
const efuse_block2 = map.EFUSE + 0x5C;
const efuse_block10 = map.EFUSE + 0x15C;
/// The digital controller's last sample of the unit, its low 12 bits.
const sar1_data_status = map.ADC + 0x40;

/// The unit's channel on `pad`: GPIO16 to GPIO23 are channels 0 to 7.
pub fn channelOf(pad: u8) ?u8 {
    if (pad < 16 or pad > 23) return null;
    return pad - 16;
}

/// What one chip's eFuse says about the unit at 12 dB: the start-up code
/// the analog side is given, the point the line goes through, and the
/// channel's own offset, which comes off every sample first.
pub const Calibration = struct {
    init_code: u16,
    point_mv: u32 = 2300,
    point_raw: u32,
    offset: i32,
};

/// The chip's own calibration of `channel`; null for a chip without one.
pub fn calibration(channel: u8) ?Calibration {
    const version = reg(efuse_mac_sys_2).*;
    const minor = (version >> 8) & 0x7;
    const major = (version >> 11) & 0x3;
    if (major * 100 + minor < 1) return null;
    const init_code = field(efuse_block2, 158, 10) + 1400;
    const point = signed(field(efuse_block2, 238, 10), 9);
    // At 12 dB the channel's offset counts once: (4 - 3) times.
    const offset = signed(field(efuse_block10, 40 + @as(u32, channel) * 4, 4), 3);
    return .{
        .init_code = @intCast(init_code),
        .point_raw = @intCast(2350 + point),
        .offset = offset,
    };
}

/// Bits `bit` to `bit + width` of the block at `block`, which may cross
/// into the next word.
fn field(block: usize, bit: u32, comptime width: u5) u32 {
    const word = bit / 32;
    const low: u64 = reg(block + word * 4).*;
    const high: u64 = if (word + 1 < 8) reg(block + (word + 1) * 4).* else 0;
    const both = low | high << 32;
    return @truncate((both >> @intCast(bit % 32)) & ((@as(u64, 1) << width) - 1));
}

/// A field whose bit `sign_bit` is its sign and the rest its size.
fn signed(value: u32, comptime sign_bit: u5) i32 {
    const sign = @as(u32, 1) << sign_bit;
    const size: i32 = @intCast(value & ~sign);
    return if (value & sign != 0) -size else size;
}

/// The digital controller's last sample of the unit, 0 to 4095.
pub fn latest() u32 {
    return reg(sar1_data_status).* & 0xFFF;
}

/// A sample in millivolts at the pad.
pub fn millivolts(raw: u32, cal: Calibration) u32 {
    const corrected: i32 = @as(i32, @intCast(raw)) - cal.offset;
    const clamped: u32 = @intCast(@min(@max(corrected, 0), 4095));
    const slope: u64 = 65536 * @as(u64, cal.point_mv) / cal.point_raw;
    const first: u64 = @as(u64, clamped) * slope / 65536;
    if (first == 0) return 0;
    // error = -(28811493455181565 / 1e16) + first x 10082311568625 / 1e16
    const constant: i64 = -@as(i64, @intCast(28811493455181565 / 10_000_000_000_000_000));
    const error_mv: i64 = constant + @as(i64, @intCast(first * 10082311568625 / 10_000_000_000_000_000));
    const result = @as(i64, @intCast(first)) - error_mv;
    return if (result < 0) 0 else @intCast(result);
}

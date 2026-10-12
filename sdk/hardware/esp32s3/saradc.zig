// SPDX-License-Identifier: MIT
//! The SAR ADC's first unit, as the kernel and battery.resource share it:
//! which pad is which of its channels, what the chip's eFuse holds of its
//! calibration at 12 dB, the last sample its digital controller took, and
//! the millivolts that sample is.
//!
//! The kernel keeps the unit sampling for the random number generator
//! (src/arch/esp32s3/entropy.zig) - on a board that measures its battery
//! on one of the unit's pads, that pad, at 12 dB, with the calibrated
//! start-up code - so a reading is the last sample, there to be read at
//! any time.
//!
//! **The calibration** is ESP-IDF v6.1's curve fitting
//! (esp_adc/adc_cali_curve_fitting.c, efuse/esp32s3/esp_efuse_rtc_calib.c):
//! a straight line through one point the factory measured - 850 mV, and
//! the sample it gave - and a fourth-order correction of it. A chip whose
//! BLOCK2 was never given its calibration (BLK_VERSION_MAJOR not 1) has
//! none, and its samples are not turned into millivolts.

const reg = @import("mmio.zig").reg;
const map = @import("map.zig");

/// The eFuse controller, and its BLOCK2 as read: SYS_PART1, eight words.
const efuse_block2 = map.EFUSE + 0x5C;
/// The digital controller's last sample of the unit, its low 12 bits.
const sar1_data_status = map.APB_SARADC + 0x40;

/// The unit's channel on `pad`: GPIO1 to GPIO10 are channels 0 to 9.
pub fn channelOf(pad: u8) ?u8 {
    if (pad < 1 or pad > 10) return null;
    return pad - 1;
}

/// What one chip's eFuse says about the unit at 12 dB: the start-up code
/// the analog side is given, and the point the line goes through.
pub const Calibration = struct {
    init_code: u16,
    point_mv: u32 = 850,
    point_raw: u32,
};

/// The chip's own calibration of the unit's channels, which on this
/// chip is one for all of them; null for a chip without one.
pub fn calibration(channel: u8) ?Calibration {
    _ = channel;
    if (field(128, 2) != 1) return null;
    const init_code = field(149, 8) + field(157, 6) + field(163, 6) + field(169, 6) + 2010;
    return .{ .init_code = @intCast(init_code), .point_raw = field(225, 8) + 900 };
}

/// Bits `bit` to `bit + width` of BLOCK2, which may cross into the next
/// word.
fn field(comptime bit: u32, comptime width: u5) u32 {
    const word = bit / 32;
    const low: u64 = reg(efuse_block2 + word * 4).*;
    const high: u64 = if (word + 1 < 8) reg(efuse_block2 + (word + 1) * 4).* else 0;
    const both = low | high << 32;
    return @truncate((both >> (bit % 32)) & ((@as(u64, 1) << width) - 1));
}

/// The digital controller's last sample of the unit, 0 to 4095.
pub fn latest() u32 {
    return reg(sar1_data_status).* & 0xFFF;
}

/// The correction's terms at 12 dB: each a coefficient over a divisor,
/// with its sign, the n-th multiplied by the first step's voltage to the
/// n-th power.
const terms = [_]struct { coefficient: u64, divisor: u64, sign: i32 }{
    .{ .coefficient = 644403418269478, .divisor = 1_000_000_000_000_000, .sign = -1 },
    .{ .coefficient = 644334888647536, .divisor = 10_000_000_000_000_000, .sign = -1 },
    .{ .coefficient = 1297891447611, .divisor = 10_000_000_000_000_000, .sign = 1 },
    .{ .coefficient = 70769718, .divisor = 1_000_000_000_000_000, .sign = -1 },
    .{ .coefficient = 13515, .divisor = 1_000_000_000_000_000, .sign = 1 },
};

/// A sample in millivolts at the pad.
pub fn millivolts(raw: u32, cal: Calibration) u32 {
    const slope: u64 = 65536 * @as(u64, cal.point_mv) / cal.point_raw;
    const first: u64 = @as(u64, raw) * slope / 65536;
    if (first == 0) return 0;
    var error_mv: i64 = @as(i64, @intCast(terms[0].coefficient / terms[0].divisor)) * terms[0].sign;
    var power: u64 = 1;
    for (terms[1..]) |term| {
        power *= first;
        error_mv += @as(i64, @intCast(power * term.coefficient / term.divisor)) * term.sign;
    }
    const result = @as(i64, @intCast(first)) - error_mv;
    return if (result < 0) 0 else @intCast(result);
}

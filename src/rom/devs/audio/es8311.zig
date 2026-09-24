// SPDX-License-Identifier: MPL-2.0
//! The ES8311 codec: the registers audio.device writes over I2C to make
//! it take a stereo stream and drive a speaker, and the bring-up as a run
//! of writes. Nothing here touches a bus, so the host tests hold it.
//!
//! The part is told two things about timing: where its master clock comes
//! from, and how that clock divides into the sample rate. The divisions
//! are a table in the maker's driver; this file holds the row for a
//! master clock 256 times the sample rate, which is what this machine's
//! I2S makes, and works the rest out from it.
//!
//! It is a mono part with one speaker output. The stream it is given is
//! still stereo, because that is what the I2S frame is; the part takes
//! the left channel of it.

const std = @import("std");

/// Where it answers by default, with its address pin low.
pub const address: u16 = 0x18;

// --- registers --------------------------------------------------------------------

/// Reset and power: 0x1F resets everything, 0x80 powers it on, and bit 6
/// says whether the part is the master of the serial port.
pub const reg_reset: u8 = 0x00;
/// The clock manager: which clocks run, and where the master clock is
/// taken from.
pub const reg_clock: u8 = 0x01;
/// The dividers, in the order the maker's table gives them.
pub const reg_div1: u8 = 0x02;
pub const reg_adc_osr: u8 = 0x03;
pub const reg_dac_osr: u8 = 0x04;
pub const reg_div2: u8 = 0x05;
pub const reg_bclk_div: u8 = 0x06;
pub const reg_lrck_high: u8 = 0x07;
pub const reg_lrck_low: u8 = 0x08;
/// The serial port in and out: the word length.
pub const reg_sdp_in: u8 = 0x09;
pub const reg_sdp_out: u8 = 0x0A;
/// The analogue side: powered, the amplifiers, the DAC and the output.
pub const reg_system_power: u8 = 0x0D;
pub const reg_system_pga: u8 = 0x0E;
pub const reg_system_dac: u8 = 0x12;
pub const reg_system_output: u8 = 0x13;
/// The converters' own settings.
pub const reg_adc: u8 = 0x1C;
pub const reg_dac_equalizer: u8 = 0x37;
/// How loud the output is, 0 to 255.
pub const reg_volume: u8 = 0x32;

/// How long the part is held in reset, in milliseconds.
pub const reset_ms: u32 = 20;

/// One write of the bring-up: a register, a value, and the milliseconds
/// to wait after it.
pub const Step = struct {
    reg: u8,
    value: u8,
    delay_ms: u8 = 0,
};

/// The bring-up, for a master clock on the part's own pin that is 256
/// times the sample rate: the part reset and powered, its dividers set,
/// its serial port told sixteen bits, and its DAC and output turned on.
/// Silent until `volumeFor` says otherwise.
pub const bring_up = [_]Step{
    // Everything reset, then powered on, as a slave of the serial port.
    .{ .reg = reg_reset, .value = 0x1F, .delay_ms = reset_ms },
    .{ .reg = reg_reset, .value = 0x00 },
    .{ .reg = reg_reset, .value = 0x80 },
    // Every clock on, taken from the master clock pin.
    .{ .reg = reg_clock, .value = 0x3F },
    // The dividers of the maker's table for 256 times the rate: nothing
    // pre-divided, the converters oversampling sixteen times, the bit
    // clock a quarter of the master clock's own division, and the word
    // clock counted out in 0x00FF.
    .{ .reg = reg_div1, .value = 0x00 },
    .{ .reg = reg_adc_osr, .value = 0x10 },
    .{ .reg = reg_dac_osr, .value = 0x10 },
    .{ .reg = reg_div2, .value = 0x00 },
    .{ .reg = reg_bclk_div, .value = 0x03 },
    .{ .reg = reg_lrck_high, .value = 0x00 },
    .{ .reg = reg_lrck_low, .value = 0xFF },
    // Sixteen bits a sample, both ways.
    .{ .reg = reg_sdp_in, .value = 0x0C },
    .{ .reg = reg_sdp_out, .value = 0x0C },
    // The analogue side up: the reference, the amplifiers, the DAC, and
    // the output to the speaker driver.
    .{ .reg = reg_system_power, .value = 0x01 },
    .{ .reg = reg_system_pga, .value = 0x02 },
    .{ .reg = reg_system_dac, .value = 0x00 },
    .{ .reg = reg_system_output, .value = 0x10 },
    .{ .reg = reg_adc, .value = 0x6A },
    .{ .reg = reg_dac_equalizer, .value = 0x08 },
    // Silent to start with: a speaker that comes up mid-note is a bang.
    .{ .reg = reg_volume, .value = 0x00 },
};

/// The volume register for `percent` of the loudest, as the maker's
/// driver counts it: 0 is silent and 100 the loudest the part goes.
pub fn volumeFor(percent: u32) u8 {
    if (percent == 0) return 0;
    const of: u32 = @min(percent, 100);
    return @intCast(of * 256 / 100 - 1);
}

// --- tests --------------------------------------------------------------------------

const testing = std.testing;

test "the bring-up: reset first, then silent, and nothing missing" {
    try testing.expectEqual(reg_reset, bring_up[0].reg);
    try testing.expectEqual(@as(u8, 0x1F), bring_up[0].value);
    try testing.expectEqual(@as(u8, reset_ms), bring_up[0].delay_ms);
    const last = bring_up[bring_up.len - 1];
    try testing.expectEqual(reg_volume, last.reg);
    try testing.expectEqual(@as(u8, 0), last.value);

    // The registers that have to be written for a sound to come out.
    const wanted = [_]u8{ reg_clock, reg_sdp_in, reg_system_power, reg_system_dac, reg_system_output };
    for (wanted) |want| {
        var found = false;
        for (bring_up) |step| {
            if (step.reg == want) found = true;
        }
        try testing.expect(found);
    }
}

test "the volume: silence, the middle and the top" {
    try testing.expectEqual(@as(u8, 0), volumeFor(0));
    try testing.expectEqual(@as(u8, 255), volumeFor(100));
    try testing.expectEqual(@as(u8, 255), volumeFor(200));
    try testing.expectEqual(@as(u8, 127), volumeFor(50));
}

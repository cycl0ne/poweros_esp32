// SPDX-License-Identifier: MPL-2.0
//! The HDMI port's sound: the JH7110's HDMI transmitter, Innosilicon's,
//! told to send I2STX0's stream (`i2s.zig`) with the picture. The display
//! driver brings the transmitter up (`fbboard/jh7110.zig`); this sets up
//! only its sound, and only once the picture is there.
//!
//! The transmitter takes the stream on its first I2S input, standard I2S
//! with two channels, and the master clock with it at 256 times the rate.
//! The monitor rebuilds the rate from the TMDS clock and two numbers sent
//! with it, so that 128 times the rate is the TMDS clock times N over CTS.
//! N is HDMI's own for 48000 Hz, 6144; CTS is the TMDS clock in kHz.
//!
//! After StarFive's starfive_hdmi_audio.c.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const display = @import("../../../libs/rtg_driver/fbboard/jh7110.zig");

/// The power management unit and the VOUT domain's reset generator, to
/// tell whether the transmitter is up: its domain on (bit 4), its reset
/// let go (bit 9). Nothing in the domain answers while it is off, so the
/// domain is asked first.
const PMU_CURR_POWER_MODE: usize = 0x1703_0080;
const DOMAIN_VOUT: u32 = 1 << 4;
const VOUT_RESET_STATUS: usize = 0x295C_004C;
const VOUTRST_HDMI_TX: u32 = 1 << 9;

/// The transmitter: register n is at n times four.
const HDMI: usize = 0x2959_0000;
const AV_MUTE = 0x05;
const AUDIO_MUTE: u32 = 1 << 1;
const AUDIO_CTRL1 = 0x35;
const CTS_EXTERNAL: u32 = 1 << 7;
const SOURCE_MASK: u32 = 3 << 3;
const MCLK_RATIO_MASK: u32 = 3;
const MCLK_256FS: u32 = 1;
const AUDIO_SAMPLE_RATE = 0x37;
const AUDIO_I2S_MODE = 0x38;
const I2S_FORMAT_MASK: u32 = 3;
const I2S_INPUTS_MASK: u32 = 0xF << 2;
const I2S_INPUT0: u32 = 1 << 2;
/// Which input each channel pair takes: 0, each its own.
const AUDIO_I2S_MAP = 0x39;
const AUDIO_N = [3]usize{ 0x3F, 0x40, 0x41 };
const AUDIO_CTS = [3]usize{ 0x45, 0x46, 0x47 };

/// The rates the transmitter names: 48000 Hz.
const RATE_48K: u32 = 0x2;
const N_48K: u32 = 6144;
/// The TMDS clock of the one mode the display path has, in kHz.
const CTS: u32 = display.pixel_clock_hz / 1000;

fn hdmi(index: usize) *volatile u32 {
    return reg(HDMI + index * 4);
}

fn modify(index: usize, mask: u32, value: u32) void {
    hdmi(index).* = hdmi(index).* & ~mask | value;
}

/// A 20-bit number into its three registers, the top four bits first.
fn write20(registers: [3]usize, value: u32) void {
    hdmi(registers[0]).* = (value >> 16) & 0xF;
    hdmi(registers[1]).* = (value >> 8) & 0xFF;
    hdmi(registers[2]).* = value & 0xFF;
}

/// Whether the display driver has the transmitter up.
pub fn present() bool {
    if (reg(PMU_CURR_POWER_MODE).* & DOMAIN_VOUT == 0) return false;
    return reg(VOUT_RESET_STATUS).* & VOUTRST_HDMI_TX != 0;
}

/// The transmitter set up for the stream at `rate` (`i2s.sample_rate`),
/// and its sound on. Only once `present`.
pub fn start(comptime rate: u32) void {
    if (rate != 48_000) @compileError("hdmi.zig is set up for 48000 Hz");
    // starfive_hdmi_audio_init: I2S, MCLK at 256 times the rate, the
    // standard format, each input to its own pair.
    modify(AUDIO_CTRL1, CTS_EXTERNAL | SOURCE_MASK | MCLK_RATIO_MASK, CTS_EXTERNAL | MCLK_256FS);
    modify(AUDIO_I2S_MODE, I2S_FORMAT_MASK, 0);
    hdmi(AUDIO_I2S_MAP).* = 0;
    // starfive_hdmi_audio_hw_params: the rate, two channels on the first
    // input, N and CTS.
    hdmi(AUDIO_SAMPLE_RATE).* = RATE_48K;
    modify(AUDIO_I2S_MODE, I2S_INPUTS_MASK, I2S_INPUT0);
    write20(AUDIO_N, N_48K);
    write20(AUDIO_CTS, CTS);
    modify(AV_MUTE, AUDIO_MUTE, 0);
}

/// The sound off; the picture stays.
pub fn stop() void {
    modify(AV_MUTE, AUDIO_MUTE, AUDIO_MUTE);
}

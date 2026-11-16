// SPDX-License-Identifier: MPL-2.0
//! The sound the BCM2712's first HDMI port carries: the link's side of
//! it, which is the HDMI controller's.
//!
//! The samples go into the controller's MAI FIFO, which the sound's
//! driver feeds IEC 958 subframes over a DMA channel. What is here sets
//! the MAI up for a stream (`audioStart`) - its format, its sample
//! clock, which channels are on - and has the controller send the
//! subframes as audio sample packets, with the audio infoframe and the
//! two numbers the monitor rebuilds the sample clock from, which depend
//! on the mode's pixel clock (`regenerate`): a mode set while sound
//! plays sets those again (`bcm2712.start`). `audioStop` takes all of it
//! off again. What a mode set and the sound both write is kept together
//! (`bcm2712.Shared`), under its lock.
//!
//! After vc4_hdmi.c's audio half.

const sdk = @import("sdk");
const bcm2712 = @import("bcm2712.zig");

const ExecBase = sdk.interface.exec.ExecBase;

const MAI_CHANNEL_MAP = 0x0A4;

const MAI_CONFIG = 0x0A8;

const AUDIO_PACKET_CONFIG = 0x0C0;

const CRP_CFG = 0x0D0;

const CTS_0 = 0x0D4;

const CTS_1 = 0x0D8;

const HD_MAI_CTL = 0x10;

const HD_MAI_THR = 0x14;

const HD_MAI_FMT = 0x18;

const HD_MAI_SMP = 0x20;

/// The MAI, the sound's way in: its control, its FIFO's thresholds for
/// the DMA's request and for panic, the stream's format, the FIFO's
/// data word and its sample clock - 108 MHz times M over N.
const MAI_RESET: u32 = 1 << 0;

const MAI_ERRORF: u32 = 1 << 1;

const MAI_ERRORE: u32 = 1 << 2;

const MAI_ENABLE: u32 = 1 << 3;

const MAI_CHNUM_SHIFT = 4;

const MAI_FLUSH: u32 = 1 << 9;

const MAI_WHOLSMP: u32 = 1 << 12;

const MAI_CHALIGN: u32 = 1 << 13;

const MAI_DLATE: u32 = 1 << 15;

const MAI_THRESHOLDS: u32 = 0x10 << 23 | 0x10 << 15 | 0x1C << 7 | 0x1C;

const MAI_FORMAT_PCM: u32 = 2;

const MAI_CONFIG_REVERSED: u32 = 1 << 27 | 1 << 26;

const AUDIO_ZERO_FLAT: u32 = 1 << 29;

const AUDIO_ZERO_INACTIVE: u32 = 1 << 24;

/// The B frame's preamble, as the subframes carry it (alsa-lib's 8).
const AUDIO_B_FRAME: u32 = 8 << 10;

const CRP_EXTERNAL_CTS: u32 = 1 << 24;

/// The DVP's 108 MHz, which the MAI's sample clock is divided from.
const AUDIO_CLOCK_HZ: u64 = 108_000_000;

pub const INFOFRAME_AUDIO: u8 = 0x84;

/// The audio infoframe for `channels` of LPCM: the rest as the stream's
/// own header says, the speakers front left and right.
pub fn audioFrame(channels: u32) bcm2712.Infoframe {
    return bcm2712.infoframe(INFOFRAME_AUDIO, 1, &.{ @intCast(channels - 1), 0, 0, 0, 0, 0, 0, 0, 0, 0 });
}

/// The MAI's code for a sample rate; 0, not said, for any other.
pub fn rateCode(rate: u32) u32 {
    return switch (rate) {
        32_000 => 7,
        44_100 => 8,
        48_000 => 9,
        88_200 => 11,
        96_000 => 12,
        176_400 => 14,
        192_000 => 15,
        else => 0,
    };
}

/// The MAI's sample clock for `rate`: 108 MHz divided by N over M, the
/// nearest fraction with M to 256 (vc4_hdmi_audio_set_mai_clock), as its
/// register holds them - N above, M less one in the low byte.
pub fn maiSample(rate: u32) u32 {
    var best_n: u64 = 0;
    var best_m: u64 = 1;
    var best_error: u64 = ~@as(u64, 0);
    var m: u64 = 1;
    while (m <= 256) : (m += 1) {
        const n = (AUDIO_CLOCK_HZ * m + rate / 2) / rate;
        if (n == 0 or n > 0xFF_FFFF) continue;
        const exact = AUDIO_CLOCK_HZ * m;
        const off = if (n * rate > exact) n * rate - exact else exact - n * rate;
        // |n/m - clock/rate|, compared without dividing.
        if (best_error == ~@as(u64, 0) or off * best_m < best_error * m) {
            best_n = n;
            best_m = m;
            best_error = off;
        }
        if (off == 0) break;
    }
    return @intCast(best_n << 8 | (best_m - 1));
}

/// N and CTS, which the monitor rebuilds the sample clock from, for the
/// sound playing at the mode's pixel clock (vc4_hdmi_set_n_cts), as
/// rtg.library works them out. Nothing without the library.
pub fn regenerate(port: *const bcm2712.Port, shared: *const bcm2712.Shared) void {
    const rb = shared.rtg_base orelse return;
    var n: u32 = 0;
    var cts: u32 = 0;
    if (!rb.HdmiAudioClock(shared.pixel_khz * 1000, shared.audio_rate, &n, &cts)) return;
    bcm2712.at(port.blocks.hdmi, CRP_CFG).* = CRP_EXTERNAL_CTS | n;
    bcm2712.at(port.blocks.hdmi, CTS_0).* = cts;
    bcm2712.at(port.blocks.hdmi, CTS_1).* = cts;
}

/// Whether sound can go out: the display up as HDMI.
pub fn audible(port: *const bcm2712.Port, shared: *const bcm2712.Shared) bool {
    if (!bcm2712.on_bcm2712 or !bcm2712.running(port)) return false;
    return shared.hdmi;
}

/// The sound started: `channels` channels of IEC 958 subframes at `rate`
/// into the MAI FIFO, sent as audio sample packets with their infoframe
/// (vc4_hdmi_audio_startup, then vc4_hdmi_audio_prepare). The DMA
/// channel that feeds the FIFO starts after. False, and nothing started,
/// when the display is not up as HDMI.
pub fn audioStart(port: *const bcm2712.Port, sys: *ExecBase, shared: *bcm2712.Shared, rate: u32, channels: u32, waiter: anytype) bool {
    if (!bcm2712.on_bcm2712 or channels == 0 or channels > 8 or rateCode(rate) == 0) return false;
    sys.ObtainSemaphore(&shared.lock);
    defer sys.ReleaseSemaphore(&shared.lock);
    if (!bcm2712.running(port) or !shared.hdmi) return false;
    bcm2712.at(port.blocks.hd, HD_MAI_CTL).* = MAI_RESET | MAI_FLUSH | MAI_DLATE | MAI_ERRORE | MAI_ERRORF;
    bcm2712.at(port.blocks.hd, HD_MAI_SMP).* = maiSample(rate);
    bcm2712.at(port.blocks.hd, HD_MAI_CTL).* = channels << MAI_CHNUM_SHIFT | MAI_WHOLSMP | MAI_CHALIGN | MAI_ENABLE;
    bcm2712.at(port.blocks.hd, HD_MAI_FMT).* = rateCode(rate) << 8 | MAI_FORMAT_PCM << 16;
    bcm2712.at(port.blocks.hd, HD_MAI_THR).* = MAI_THRESHOLDS;
    const mask = (@as(u32, 1) << @intCast(channels)) - 1;
    bcm2712.at(port.blocks.hdmi, MAI_CONFIG).* = MAI_CONFIG_REVERSED | mask;
    bcm2712.at(port.blocks.hdmi, MAI_CHANNEL_MAP).* = channelMap(mask);
    bcm2712.at(port.blocks.hdmi, AUDIO_PACKET_CONFIG).* = AUDIO_ZERO_FLAT | AUDIO_ZERO_INACTIVE | AUDIO_B_FRAME | mask;
    shared.audio_rate = rate;
    shared.audio_channels = channels;
    regenerate(port, shared);
    bcm2712.writePacket(port, &audioFrame(channels), waiter);
    return true;
}

/// The sound stopped, once its DMA channel has: the MAI and its FIFO
/// reset, the audio infoframe no longer sent (vc4_hdmi_audio_shutdown,
/// vc4_hdmi_audio_reset).
pub fn audioStop(port: *const bcm2712.Port, sys: *ExecBase, shared: *bcm2712.Shared, waiter: anytype) void {
    if (!bcm2712.on_bcm2712) return;
    sys.ObtainSemaphore(&shared.lock);
    defer sys.ReleaseSemaphore(&shared.lock);
    shared.audio_rate = 0;
    shared.audio_channels = 0;
    if (!bcm2712.running(port)) return;
    bcm2712.at(port.blocks.hd, HD_MAI_CTL).* = MAI_DLATE | MAI_ERRORE | MAI_ERRORF;
    if (shared.hdmi) bcm2712.stopPacket(port, INFOFRAME_AUDIO, waiter);
    bcm2712.at(port.blocks.hd, HD_MAI_CTL).* = MAI_RESET;
    bcm2712.at(port.blocks.hd, HD_MAI_CTL).* = MAI_ERRORF;
    bcm2712.at(port.blocks.hd, HD_MAI_CTL).* = MAI_FLUSH;
}

/// Each channel of `mask` taken from the MAI's channel of its own number
/// (vc5_hdmi_channel_map): four bits a channel.
pub fn channelMap(mask: u32) u32 {
    var map: u32 = 0;
    for (0..8) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) != 0) map |= @as(u32, @intCast(i)) << @intCast(4 * i);
    }
    return map;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the sound's numbers: the audio infoframe, the MAI's clock, the channels' map" {
    try testing.expectEqualSlices(u8, &.{ 0x84, 0x01, 0x0A, 0x70, 0x01, 0 }, audioFrame(2)[0..6]);
    // 108 MHz over 48 kHz is 2250 exactly; over 44.1 kHz 120000/49.
    try testing.expectEqual(@as(u32, 2250 << 8), maiSample(48_000));
    try testing.expectEqual(@as(u32, 120_000 << 8 | 48), maiSample(44_100));
    try testing.expectEqual(@as(u32, 3375 << 8), maiSample(32_000));
    try testing.expectEqual(@as(u32, 9), rateCode(48_000));
    try testing.expectEqual(@as(u32, 0), rateCode(22_050));
    try testing.expectEqual(@as(u32, 0x10), channelMap(0x3));
    try testing.expectEqual(@as(u32, 0x7654_3210), channelMap(0xFF));
}

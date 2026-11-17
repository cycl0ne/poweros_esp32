// SPDX-License-Identifier: MPL-2.0
//! The sound the BCM2711's first HDMI port carries: the link's side of
//! it, which is the HDMI controller's.
//!
//! The samples go into the controller's MAI FIFO, which the sound's
//! driver feeds IEC 958 subframes over a DMA channel. The controller is
//! the firmware's - the mode stays as it lit it, and the display touches
//! nothing of it - so what the sound needs of it is set up here
//! (`audioStart`), as Linux's vc4_hdmi does on a BCM2711 (its vc5
//! registers): the MAI for the stream - its format, its sample clock,
//! which channels are on - the audio packets, the numbers the monitor
//! rebuilds the sample clock from (N and CTS), and the audio infoframe.
//! `audioStop` takes all of it off again.
//!
//! **CTS** goes by the pixel clock, which the firmware does not say. It
//! is measured as the sound starts (`pixelKhz`): the frame's pixels,
//! from the controller's timing, times the frames HDMI0 counts in a
//! quarter of a second, at 8 bits a colour as the firmware sends them.
//!
//! **The audio infoframe** goes in a slot of the controller's packet RAM
//! the firmware does not send: it has the general control packet in
//! slot 0, the AVI infoframe in 2 and the SPD in 4, where Linux would put
//! the audio's (its type less 0x80) - so it goes in 3.
//!
//! Where the blocks are is the port's table
//! (`sdk.hardware.bcm2711.HdmiPort`).

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const hwcpu = sdk.hardware.cpu;
const RtgDriverBase = sdk.interface.rtgdriver.RtgDriverBase;
const HdmiPort = sdk.hardware.bcm2711.HdmiPort;

/// Whether this is built for the BCM2711; on anything else - the host's
/// tests - the port is never up.
const on_bcm2711 = sdk.hardware.chip == .a64v80;

/// The controller's registers the sound writes or reads.
const MAI_CHANNEL_MAP = 0x09C;
const MAI_CONFIG = 0x0A0;
const AUDIO_PACKET_CONFIG = 0x0B8;
const RAM_PACKET_CONFIG = 0x0BC;
const RAM_PACKET_STATUS = 0x0C4;
const CRP_CFG = 0x0C8;
const CTS_0 = 0x0CC;
const CTS_1 = 0x0D0;
const SCHEDULER_CONTROL = 0x0E0;
const HORZA = 0x0E4;
const HORZB = 0x0E8;
const VERTA0 = 0x0EC;
const VERTB0 = 0x0F0;
const SCHEDULER_MODE_HDMI: u32 = 1 << 0;

/// HDMI0's in the shared block: the MAI - its control, its FIFO's
/// thresholds, the stream's format and its sample clock - the video's
/// control, and the frames sent.
const HD_MAI_CTL = 0x10;
const HD_MAI_THR = 0x14;
const HD_MAI_FMT = 0x18;
const HD_MAI_SMP = 0x20;
const HD_VID_CTL = 0x44;
const HD_FRAME_COUNT = 0x60;
const VID_ENABLE: u32 = 1 << 31;

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

/// The packet RAM: nine words a slot, the header in the first and four
/// subpackets of seven bytes in the eight after.
const PACKET_STRIDE = 0x24;
const audio_slot: u5 = 3;

/// An infoframe as the packet RAM takes it: its type, version and
/// length, its checksum, and the body.
const Infoframe = [31]u8;
const INFOFRAME_AUDIO: u8 = 0x84;

/// How long the frames are counted for the pixel clock, and how far
/// apart the two reads on either side of a frame's start may be.
const measure_us: u32 = 250_000;
const sharp_ns: u64 = 2000;

fn at(base: usize, offset: usize) *volatile u32 {
    return reg(base + offset);
}

/// Whether sound can go out: HDMI0 sending video, as HDMI.
pub fn audible(port: *const HdmiPort) bool {
    if (!on_bcm2711) return false;
    return at(port.hd, HD_VID_CTL).* & VID_ENABLE != 0 and at(port.hdmi, SCHEDULER_CONTROL).* & SCHEDULER_MODE_HDMI != 0;
}

/// The sound started: `channels` channels of IEC 958 subframes at `rate`
/// into the MAI FIFO, sent as audio sample packets with their infoframe
/// (vc4_hdmi_audio_startup, then vc4_hdmi_audio_prepare). The DMA
/// channel that feeds the FIFO starts after. False, and nothing started,
/// when the port is not sending HDMI, its pixel clock does not measure,
/// or the MAI does not take the rate.
pub fn audioStart(port: *const HdmiPort, rb: *RtgDriverBase, rate: u32, channels: u32) bool {
    if (!on_bcm2711) return false;
    if (channels == 0 or channels > 8 or rateCode(rate) == 0 or !audible(port)) return false;
    const pixel_khz = pixelKhz(port, rb) orelse return false;
    var n: u32 = 0;
    var cts: u32 = 0;
    if (!rb.HdmiAudioClock(pixel_khz * 1000, rate, &n, &cts)) return false;
    at(port.hd, HD_MAI_CTL).* = MAI_RESET | MAI_FLUSH | MAI_DLATE | MAI_ERRORE | MAI_ERRORF;
    at(port.hd, HD_MAI_SMP).* = maiSample(rate);
    at(port.hd, HD_MAI_CTL).* = channels << MAI_CHNUM_SHIFT | MAI_WHOLSMP | MAI_CHALIGN | MAI_ENABLE;
    at(port.hd, HD_MAI_FMT).* = rateCode(rate) << 8 | MAI_FORMAT_PCM << 16;
    at(port.hd, HD_MAI_THR).* = MAI_THRESHOLDS;
    const mask = (@as(u32, 1) << @intCast(channels)) - 1;
    at(port.hdmi, MAI_CONFIG).* = MAI_CONFIG_REVERSED | mask;
    at(port.hdmi, MAI_CHANNEL_MAP).* = channelMap(mask);
    at(port.hdmi, AUDIO_PACKET_CONFIG).* = AUDIO_ZERO_FLAT | AUDIO_ZERO_INACTIVE | AUDIO_B_FRAME | mask;
    at(port.hdmi, CRP_CFG).* = CRP_EXTERNAL_CTS | n;
    at(port.hdmi, CTS_0).* = cts;
    at(port.hdmi, CTS_1).* = cts;
    writePacket(port, rb, &audioFrame(channels));
    return true;
}

/// The sound stopped, once its DMA channel has: the MAI and its FIFO
/// reset, the audio infoframe no longer sent (vc4_hdmi_audio_shutdown,
/// vc4_hdmi_audio_reset).
pub fn audioStop(port: *const HdmiPort, rb: *RtgDriverBase) void {
    if (!on_bcm2711) return;
    at(port.hd, HD_MAI_CTL).* = MAI_DLATE | MAI_ERRORE | MAI_ERRORF;
    stopPacket(port, rb);
    at(port.hd, HD_MAI_CTL).* = MAI_RESET;
    at(port.hd, HD_MAI_CTL).* = MAI_ERRORF;
    at(port.hd, HD_MAI_CTL).* = MAI_FLUSH;
}

// --- the MAI's numbers ---------------------------------------------------------

/// The MAI's code for a sample rate; 0, not said, for any other.
fn rateCode(rate: u32) u32 {
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
fn maiSample(rate: u32) u32 {
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

/// Each channel of `mask` taken from the MAI's channel of its own number
/// (vc5_hdmi_channel_map): four bits a channel.
fn channelMap(mask: u32) u32 {
    var map: u32 = 0;
    for (0..8) |i| {
        if (mask & (@as(u32, 1) << @intCast(i)) != 0) map |= @as(u32, @intCast(i)) << @intCast(4 * i);
    }
    return map;
}

// --- the infoframe -----------------------------------------------------------

/// The audio infoframe for `channels` of LPCM: the rest as the stream's
/// own header says, the speakers front left and right.
fn audioFrame(channels: u32) Infoframe {
    var frame: Infoframe = @splat(0);
    frame[0] = INFOFRAME_AUDIO;
    frame[1] = 1;
    frame[2] = 10;
    frame[4] = @intCast(channels - 1);
    var sum: u8 = 0;
    for (frame) |byte| sum +%= byte;
    frame[3] = 0 -% sum;
    return frame;
}

/// The infoframe `frame` into the audio's slot and sent with every frame
/// from now on (vc4_hdmi_write_infoframe): the slot's sending stopped and
/// waited out, its nine words written, then sent again, beside what the
/// firmware sends.
fn writePacket(port: *const HdmiPort, rb: *RtgDriverBase, frame: *const Infoframe) void {
    const bit = @as(u32, 1) << audio_slot;
    stopPacket(port, rb);
    const first = port.packets + @as(usize, audio_slot) * PACKET_STRIDE;
    var i: usize = 0;
    while (i < 28) : (i += 7) {
        const pair = first + i / 7 * 8;
        reg(pair).* = @as(u32, frame[i]) | @as(u32, frame[i + 1]) << 8 | @as(u32, frame[i + 2]) << 16;
        reg(pair + 4).* = @as(u32, frame[i + 3]) | @as(u32, frame[i + 4]) << 8 | @as(u32, frame[i + 5]) << 16 | @as(u32, frame[i + 6]) << 24;
    }
    reg(first + 32).* = 0;
    at(port.hdmi, RAM_PACKET_CONFIG).* |= bit;
    waitStatus(port, rb, bit, true);
}

/// The audio's slot no longer sent, waited out.
fn stopPacket(port: *const HdmiPort, rb: *RtgDriverBase) void {
    const bit = @as(u32, 1) << audio_slot;
    at(port.hdmi, RAM_PACKET_CONFIG).* &= ~bit;
    waitStatus(port, rb, bit, false);
}

/// The packet RAM's status for `bit` waited for to be `set`, a tenth of
/// a second at the most.
fn waitStatus(port: *const HdmiPort, rb: *RtgDriverBase, bit: u32, set: bool) void {
    var waited: u32 = 0;
    while ((at(port.hdmi, RAM_PACKET_STATUS).* & bit != 0) != set and waited < 100) : (waited += 1) rb.RtgDelay(1000);
}

// --- the pixel clock ---------------------------------------------------------

/// The pixels of a frame of the controller's timing - the lines' and the
/// frame's, blanking and all: HORZA its active pixels and front porch,
/// HORZB its sync and back porch, VERTA0 its active lines, front porch
/// and sync, VERTB0 its back porch.
fn framePixels(horza: u32, horzb: u32, verta: u32, vertb: u32) u64 {
    const line = (horza & 0x3FFF) + (horza >> 16 & 0x3FF) + (horzb & 0x3FF) + (horzb >> 16 & 0x3FF);
    const lines = (verta & 0x1FFF) + (verta >> 16 & 0x7F) + (verta >> 24 & 0x1F) + (vertb & 0x1FF);
    return @as(u64, line) * lines;
}

/// The pixel clock in kHz, rounded, for `pixels` a frame and `frames`
/// counted in `ticks` of a counter that runs at `frequency`.
fn khzOf(pixels: u64, frames: u64, ticks: u64, frequency: u64) u32 {
    return @intCast((pixels * frames * frequency + ticks * 500) / (ticks * 1000));
}

fn frameCount(port: *const HdmiPort) u32 {
    return at(port.hd, HD_FRAME_COUNT).* & 0xFFFF;
}

const Start = struct { count: u32, at: u64 };

/// The next frame HDMI0 starts, as its count moves on: the count, and
/// the counter's time half way between the last read that saw the one
/// before and the read that saw it - taken only where those were no more
/// than `sharp_ns` apart, so an interrupt between them makes it the frame
/// after. Null where none does within a tenth of a second.
fn nextStart(port: *const HdmiPort) ?Start {
    const frequency = hwcpu.counterFrequency();
    const sharp = frequency * sharp_ns / 1_000_000_000;
    const until = hwcpu.time() + frequency / 10;
    var before = hwcpu.time();
    var count = frameCount(port);
    while (true) {
        const read_at = hwcpu.time();
        const now = frameCount(port);
        const after = hwcpu.time();
        if (now != count) {
            if (after - before <= sharp) return .{ .count = now, .at = before + (after - before) / 2 };
            count = now;
        }
        if (after > until) return null;
        before = read_at;
    }
}

/// HDMI0's pixel clock in kHz: the frames it starts in a quarter of a
/// second, timed from one start to another, times the pixels of its
/// frame. Null where it sends none.
fn pixelKhz(port: *const HdmiPort, rb: *RtgDriverBase) ?u32 {
    const pixels = framePixels(at(port.hdmi, HORZA).*, at(port.hdmi, HORZB).*, at(port.hdmi, VERTA0).*, at(port.hdmi, VERTB0).*);
    if (pixels == 0) return null;
    const first = nextStart(port) orelse return null;
    rb.RtgDelay(measure_us);
    const last = nextStart(port) orelse return null;
    const frames = (last.count -% first.count) & 0xFFFF;
    if (frames == 0 or last.at <= first.at) return null;
    return khzOf(pixels, frames, last.at - first.at, hwcpu.counterFrequency());
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "1920x1080 at 60 Hz as the firmware set HDMI0: 2200 by 1125, 148.5 MHz" {
    const pixels = framePixels(0x0058_C780, 0x0094_002C, 0x0504_0438, 0x0000_0024);
    try testing.expectEqual(@as(u64, 2200 * 1125), pixels);
    // 15 frames in a quarter of a second of the 54 MHz counter.
    try testing.expectEqual(@as(u32, 148_500), khzOf(pixels, 15, 54_000_000 / 4, 54_000_000));
    // At 59.94 Hz the same frames take 1.001 times as long.
    try testing.expectEqual(@as(u32, 148_352), khzOf(pixels, 15, 54_000_000 / 4 * 1001 / 1000, 54_000_000));
}

test "the sound's numbers: the audio infoframe, the MAI's clock, the channels' map" {
    try testing.expectEqualSlices(u8, &.{ 0x84, 0x01, 0x0A, 0x70, 0x01, 0 }, audioFrame(2)[0..6]);
    // 108 MHz over 48 kHz is 2250 exactly; over 44.1 kHz 120000/49.
    try testing.expectEqual(@as(u32, 2250 << 8), maiSample(48_000));
    try testing.expectEqual(@as(u32, 120_000 << 8 | 48), maiSample(44_100));
    try testing.expectEqual(@as(u32, 9), rateCode(48_000));
    try testing.expectEqual(@as(u32, 0), rateCode(22_050));
    try testing.expectEqual(@as(u32, 0x10), channelMap(0x3));
}

test "the audio infoframe's slot is one the firmware leaves free" {
    // The firmware sends slots 0, 2 and 4 (RAM_PACKET_CONFIG 0x10015).
    try testing.expect(@as(u32, 0x15) & @as(u32, 1) << audio_slot == 0);
}

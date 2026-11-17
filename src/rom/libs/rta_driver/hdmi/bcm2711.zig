// SPDX-License-Identifier: MPL-2.0
//! The Compute Module 4's first HDMI port as a sink: the monitor's
//! speakers, in stereo at 48000 Hz, in the mode the VideoCore's firmware
//! lit, where it lit it as HDMI.
//!
//! The Compute Module 5's module (`bcm2712.zig`) on the BCM2711, with the
//! same sink (`mai.zig`), for the HDMI sound the board lists
//! (CHIP_BCM2711_HDMI_AUDIO): one of the chip's 40-bit DMA4 channels
//! feeds HDMI0's MAI. The controller is the firmware's - the display
//! driver keeps its mode (`rtg_driver/fbboard/bcm2711.zig`) and touches
//! nothing of it - so the sound sets up what it needs there itself
//! (`audioStart`), as Linux's vc4_hdmi does on a BCM2711 (its vc5
//! registers): the MAI for the stream, which channels go where, the
//! audio packets, the numbers the monitor rebuilds the sample clock from
//! (N and CTS), and the audio infoframe.
//!
//! **CTS** goes by the pixel clock, which the firmware does not say. It
//! is measured as the sink starts (`pixelKhz`): the frame's pixels, from
//! the controller's timing, times the frames HDMI0 counts in a quarter
//! of a second, at 8 bits a colour as the firmware sends them.
//!
//! **The audio infoframe** goes in a slot of the controller's packet RAM
//! the firmware does not send: it has the general control packet in
//! slot 0, the AVI infoframe in 2 and the SPD in 4, where Linux would put
//! the audio's (its type less 0x80) - so it goes in 3.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const hwcpu = sdk.hardware.cpu;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const st = sdk.expansion.systemtags;
const mai = @import("mai.zig");
/// The sound's arithmetic, the BCM2712's and this one's alike: the MAI's
/// rate codes and sample clock, N and CTS, the channel map and the audio
/// infoframe.
const hdmi = @import("../../rtg_driver/fbboard/bcm2712.zig");

/// Whether this is built for the BCM2711; on anything else - the host's
/// tests - the port is never up.
const on_bcm2711 = sdk.hardware.chip == .a64v80;

pub const chip = st.CHIP_BCM2711_HDMI_AUDIO;
pub const version = 1;
pub const revision = 0;
pub const build_date = "17.11.2026";

/// HDMI0's controller (the device tree's "hdmi"), its packet RAM
/// ("packet"), and the block it shares with HDMI1 that holds each port's
/// MAI ("hd").
const HDMI: usize = 0xFEF0_0700;
const PACKET: usize = 0xFEF0_1B00;
const HD: usize = 0xFEF2_0000;

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
/// thresholds, the stream's format, the FIFO's data word and its sample
/// clock - the video's control, and the frames sent.
const HD_MAI_CTL = 0x10;
const HD_MAI_THR = 0x14;
const HD_MAI_FMT = 0x18;
const HD_MAI_DATA = 0x1C;
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
/// The B frame's preamble, as the subframes carry it.
const AUDIO_B_FRAME: u32 = mai.PREAMBLE_Z << 10;
const CRP_EXTERNAL_CTS: u32 = 1 << 24;

/// The packet RAM: nine words a slot, the header in the first and four
/// subpackets of seven bytes in the eight after.
const PACKET_STRIDE = 0x24;
const audio_slot: u5 = 3;

/// The chip's peripherals at 0xFC00_0000 as the ARM sees them, and at
/// 0x4_7C00_0000 as the 40-bit DMA channels do (the scb bus's
/// dma-ranges, and Linux's 0x4_0000_0000 put to a 40-bit channel's
/// device address); RAM is where it is to both.
const arm_peripherals: usize = 0xFC00_0000;
const dma_peripherals: usize = 0x4_7C00_0000;

/// HDMI0's MAI FIFO as the channel reaches it, the request line it asks
/// for data on (DREQ 10, the device tree's dmas cell for hdmi0), and the
/// channel's bus priorities from the same cell: QoS 10, 15 in a panic.
pub const mai_data: usize = HD + HD_MAI_DATA - arm_peripherals + dma_peripherals;
pub const audio_dreq: u32 = 10;
pub const dma_flags: u32 = 0x00FA_0000;

/// How long the frames are counted for the pixel clock, and how far
/// apart the two reads on either side of a frame's start may be.
const measure_us: u32 = 250_000;
const sharp_ns: u64 = 2000;

/// Whether sound can go out: HDMI0 sending video, as HDMI.
pub fn audible(sys: *ExecBase) bool {
    _ = sys;
    if (!on_bcm2711) return false;
    return reg(HD + HD_VID_CTL).* & VID_ENABLE != 0 and reg(HDMI + SCHEDULER_CONTROL).* & SCHEDULER_MODE_HDMI != 0;
}

/// The sound started: `channels` channels of IEC 958 subframes at `rate`
/// into the MAI FIFO, sent as audio sample packets with their infoframe
/// (vc4_hdmi_audio_startup, then vc4_hdmi_audio_prepare). The DMA
/// channel that feeds the FIFO starts after. False, and nothing started,
/// when the port is not sending HDMI.
pub fn audioStart(sys: *ExecBase, rate: u32, channels: u32, waiter: anytype) bool {
    if (!on_bcm2711) return false;
    if (channels == 0 or channels > 8 or !audible(sys)) return false;
    const pixel_khz = pixelKhz(waiter) orelse return false;
    exec.kprintf(sys, "%s: HDMI0's pixel clock is %d kHz\n", .{ mai.MODULE_NAME, pixel_khz });
    reg(HD + HD_MAI_CTL).* = MAI_RESET | MAI_FLUSH | MAI_DLATE | MAI_ERRORE | MAI_ERRORF;
    reg(HD + HD_MAI_SMP).* = hdmi.maiSample(rate);
    reg(HD + HD_MAI_CTL).* = channels << MAI_CHNUM_SHIFT | MAI_WHOLSMP | MAI_CHALIGN | MAI_ENABLE;
    reg(HD + HD_MAI_FMT).* = hdmi.rateCode(rate) << 8 | MAI_FORMAT_PCM << 16;
    reg(HD + HD_MAI_THR).* = MAI_THRESHOLDS;
    const mask = (@as(u32, 1) << @intCast(channels)) - 1;
    reg(HDMI + MAI_CONFIG).* = MAI_CONFIG_REVERSED | mask;
    reg(HDMI + MAI_CHANNEL_MAP).* = hdmi.channelMap(mask);
    reg(HDMI + AUDIO_PACKET_CONFIG).* = AUDIO_ZERO_FLAT | AUDIO_ZERO_INACTIVE | AUDIO_B_FRAME | mask;
    const regen = hdmi.clockRegen(rate, pixel_khz);
    reg(HDMI + CRP_CFG).* = CRP_EXTERNAL_CTS | regen.n;
    reg(HDMI + CTS_0).* = regen.cts;
    reg(HDMI + CTS_1).* = regen.cts;
    writePacket(&hdmi.audioFrame(channels), waiter);
    return true;
}

/// The sound stopped, once its DMA channel has: the MAI and its FIFO
/// reset, the audio infoframe no longer sent (vc4_hdmi_audio_shutdown,
/// vc4_hdmi_audio_reset).
pub fn audioStop(sys: *ExecBase, waiter: anytype) void {
    _ = sys;
    if (!on_bcm2711) return;
    reg(HD + HD_MAI_CTL).* = MAI_DLATE | MAI_ERRORE | MAI_ERRORF;
    stopPacket(waiter);
    reg(HD + HD_MAI_CTL).* = MAI_RESET;
    reg(HD + HD_MAI_CTL).* = MAI_ERRORF;
    reg(HD + HD_MAI_CTL).* = MAI_FLUSH;
}

// --- the infoframe -----------------------------------------------------------

/// The infoframe `frame` into the audio's slot and sent with every frame
/// from now on (vc4_hdmi_write_infoframe): the slot's sending stopped and
/// waited out, its nine words written, then sent again, beside what the
/// firmware sends.
fn writePacket(frame: *const hdmi.Infoframe, waiter: anytype) void {
    const bit = @as(u32, 1) << audio_slot;
    stopPacket(waiter);
    const first = PACKET + @as(usize, audio_slot) * PACKET_STRIDE;
    var i: usize = 0;
    while (i < 28) : (i += 7) {
        const pair = first + i / 7 * 8;
        reg(pair).* = @as(u32, frame[i]) | @as(u32, frame[i + 1]) << 8 | @as(u32, frame[i + 2]) << 16;
        reg(pair + 4).* = @as(u32, frame[i + 3]) | @as(u32, frame[i + 4]) << 8 | @as(u32, frame[i + 5]) << 16 | @as(u32, frame[i + 6]) << 24;
    }
    reg(first + 32).* = 0;
    reg(HDMI + RAM_PACKET_CONFIG).* |= bit;
    waitStatus(bit, true, waiter);
}

/// The audio's slot no longer sent, waited out.
fn stopPacket(waiter: anytype) void {
    const bit = @as(u32, 1) << audio_slot;
    reg(HDMI + RAM_PACKET_CONFIG).* &= ~bit;
    waitStatus(bit, false, waiter);
}

/// The packet RAM's status for `bit` waited for to be `set`, a tenth of
/// a second at the most.
fn waitStatus(bit: u32, set: bool, waiter: anytype) void {
    var waited: u32 = 0;
    while ((reg(HDMI + RAM_PACKET_STATUS).* & bit != 0) != set and waited < 100) : (waited += 1) waiter.wait(1000);
}

// --- the pixel clock ---------------------------------------------------------

/// The pixels of a frame of the controller's timing - the lines' and the
/// frame's, blanking and all: HORZA its active pixels and front porch,
/// HORZB its sync and back porch, VERTA0 its active lines, front porch
/// and sync, VERTB0 its back porch.
pub fn framePixels(horza: u32, horzb: u32, verta: u32, vertb: u32) u64 {
    const line = (horza & 0x3FFF) + (horza >> 16 & 0x3FF) + (horzb & 0x3FF) + (horzb >> 16 & 0x3FF);
    const lines = (verta & 0x1FFF) + (verta >> 16 & 0x7F) + (verta >> 24 & 0x1F) + (vertb & 0x1FF);
    return @as(u64, line) * lines;
}

/// The pixel clock in kHz, rounded, for `pixels` a frame and `frames`
/// counted in `ticks` of a counter that runs at `frequency`.
pub fn khzOf(pixels: u64, frames: u64, ticks: u64, frequency: u64) u32 {
    return @intCast((pixels * frames * frequency + ticks * 500) / (ticks * 1000));
}

fn frameCount() u32 {
    return reg(HD + HD_FRAME_COUNT).* & 0xFFFF;
}

const Start = struct { count: u32, at: u64 };

/// The next frame HDMI0 starts, as its count moves on: the count, and
/// the counter's time half way between the last read that saw the one
/// before and the read that saw it - taken only where those were no more
/// than `sharp_ns` apart, so an interrupt between them makes it the frame
/// after. Null where none does within a tenth of a second.
fn nextStart() ?Start {
    const frequency = hwcpu.counterFrequency();
    const sharp = frequency * sharp_ns / 1_000_000_000;
    const until = hwcpu.time() + frequency / 10;
    var before = hwcpu.time();
    var count = frameCount();
    while (true) {
        const read_at = hwcpu.time();
        const now = frameCount();
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
fn pixelKhz(waiter: anytype) ?u32 {
    const pixels = framePixels(reg(HDMI + HORZA).*, reg(HDMI + HORZB).*, reg(HDMI + VERTA0).*, reg(HDMI + VERTB0).*);
    if (pixels == 0) return null;
    const first = nextStart() orelse return null;
    waiter.wait(measure_us);
    const last = nextStart() orelse return null;
    const frames = (last.count -% first.count) & 0xFFFF;
    if (frames == 0 or last.at <= first.at) return null;
    return khzOf(pixels, frames, last.at - first.at, hwcpu.counterFrequency());
}

const Sink = mai.Driver(@This());

/// No library and no vectors: the tag's init is the whole of it.
export const rta_hdmi_bcm2711_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rta_hdmi_bcm2711_tag,
    .flags = exec.RTF_COLDSTART,
    .version = version,
    .pri = 31,
    .type = .rta_driver,
    .name = mai.MODULE_NAME,
    .id_string = Sink.version_string[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&Sink.init)),
};

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

test "the MAI's FIFO as the 40-bit DMA channels reach it" {
    try testing.expectEqual(@as(usize, 0x4_7EF2_001C), mai_data);
}

test "the audio infoframe's slot is one the firmware leaves free" {
    // The firmware sends slots 0, 2 and 4 (RAM_PACKET_CONFIG 0x10015).
    try testing.expect(@as(u32, 0x15) & @as(u32, 1) << audio_slot == 0);
}

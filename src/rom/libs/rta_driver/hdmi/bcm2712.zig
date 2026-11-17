// SPDX-License-Identifier: MPL-2.0
//! The Compute Module 5's first HDMI port as a sink: the monitor's
//! speakers, in stereo at 48000 Hz while the picture goes out as HDMI.
//!
//! A module of its own, rta-hdmi as the VisionFive 2's: at cold start it
//! opens rta.library, hands in a driver of the sink kind, and makes a
//! sink for the HDMI sound the board lists (CHIP_BCM2712_HDMI_AUDIO),
//! named as the board names the part. The part is the DMA channel that
//! feeds the HDMI controller (PART_Address its registers, PART_Irq its
//! interrupt); the controller is the display's (`rtg_driver/fbboard/
//! bcm2712.zig`), which the sound shares with it and which sets it up
//! for the stream (`audioStart`). The sink is the one the BCM2711's port
//! has too (`mai.zig`).

const sdk = @import("sdk");
const exec = sdk.exec;
const st = sdk.expansion.systemtags;
const display = @import("../../rtg_driver/fbboard/bcm2712.zig");
const mai = @import("mai.zig");

pub const chip = st.CHIP_BCM2712_HDMI_AUDIO;
pub const version = 1;
pub const revision = 0;
pub const build_date = "29.10.2026";

/// The MAI's FIFO and its request line, as the display has them.
pub const mai_data = display.mai_data;
pub const audio_dreq = display.audio_dreq;

/// The channel's bus priorities, as the device tree's dmas cell for the
/// HDMI's sound gives them: QoS 10, 15 in a panic.
pub const dma_flags: u32 = 0x00FA_0000;

pub const audible = display.audible;
pub const audioStart = display.audioStart;
pub const audioStop = display.audioStop;

const Sink = mai.Driver(@This());

/// No library and no vectors: the tag's init is the whole of it.
export const rta_hdmi_bcm2712_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rta_hdmi_bcm2712_tag,
    .flags = exec.RTF_COLDSTART,
    .version = version,
    .pri = 31,
    .type = .rta_driver,
    .name = mai.MODULE_NAME,
    .id_string = Sink.version_string[1..], // past the NUL: a C string
    .init = @ptrCast(@constCast(&Sink.init)),
};

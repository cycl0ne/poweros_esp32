// SPDX-License-Identifier: MPL-2.0
//! The Compute Module 5's first HDMI port as a sink: the monitor's
//! speakers, in stereo at 48000 Hz while the picture goes out as HDMI.
//!
//! A module of its own, rta-hdmi as the VisionFive 2's: at cold start it
//! opens rta.library, hands in a driver of the sink kind, and makes a
//! sink for the HDMI sound the board lists (CHIP_BCM2712_HDMI_AUDIO),
//! named as the board names the part. The part is the DMA channel that
//! feeds the HDMI controller, with the controller's FIFO and its request
//! line; the controller is the display's, whose board sets its side of
//! the sound up (`rtg_driver/bcm2712board/sound.zig`). The sink is the
//! one the BCM2711's port has too (`mai.zig`).

const sdk = @import("sdk");
const exec = sdk.exec;
const st = sdk.expansion.systemtags;
const mai = @import("mai.zig");

pub const chip = st.CHIP_BCM2712_HDMI_AUDIO;
pub const version = 1;
pub const revision = 2;
pub const build_date = "17.11.2026";

/// The channel's bus priorities, as the device tree's dmas cell for the
/// HDMI's sound gives them: QoS 10, 15 in a panic.
pub const dma_flags: u32 = 0x00FA_0000;

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

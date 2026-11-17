// SPDX-License-Identifier: MPL-2.0
//! The Compute Module 4's first HDMI port as a sink: the monitor's
//! speakers, in stereo at 48000 Hz, in the mode the VideoCore's firmware
//! lit, where it lit it as HDMI.
//!
//! The Compute Module 5's module (`bcm2712.zig`) on the BCM2711, with the
//! same sink (`mai.zig`), for the HDMI sound the board lists
//! (CHIP_BCM2711_HDMI_AUDIO): one of the chip's 40-bit DMA4 channels
//! feeds HDMI0's MAI, whose FIFO and request line the part names. The
//! controller's side of the sound is the display's board's
//! (`rtg_driver/bcm2711board/sound.zig`).

const sdk = @import("sdk");
const exec = sdk.exec;
const st = sdk.expansion.systemtags;
const mai = @import("mai.zig");

pub const chip = st.CHIP_BCM2711_HDMI_AUDIO;
pub const version = 1;
pub const revision = 1;
pub const build_date = "17.11.2026";

/// The channel's bus priorities, from the device tree's dmas cell for
/// hdmi0: QoS 10, 15 in a panic.
pub const dma_flags: u32 = 0x00FA_0000;

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

// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the Raspberry Pi 4 Model B carries beyond the ones every
//! image has: the display drivers, which take over the picture the
//! VideoCore's firmware lit - `bcm2711` where it is the scaler's on the
//! first HDMI port (CHIP_BCM2711_HVS), `fw` where it is the framebuffer
//! alone (CHIP_UEFI_FB, `screen.zig`) - and the microSD slot as a disk -
//! sdcard.device, which hands the card's partitions to expansion.library
//! at cold start, FAT's handler for its boot partition and
//! posfs-handler for its volumes. And sound: rta.library, the HDMI
//! port's sink (rta-hdmi) and audio.device, which plays through it. And
//! videodec.resource for the chip's H.265 block (CHIP_BCM2711_HEVC), and
//! vchiq.resource, the queue to the VideoCore's firmware
//! (CHIP_BCM2711_VCHIQ), through which videodec.resource decodes H.264
//! and jpeg.resource JPEG. The chip is the Compute Module 4's, and so are
//! the drivers.

const rom = @import("../../rom/modules.zig");

// What every image has, what draws, the pipe and the clock of things that
// move, and the drivers of this board's parts.
pub const modules = rom.core ++ rom.screen ++ rom.pipe ++ rom.motion ++ .{
    @import("../../rom/libs/rtg_driver/bcm2711board/bcm2711board.zig"),
    @import("../../rom/libs/rtg_driver/fwboard/fwboard.zig"),
    @import("../../disk/devs/sdcard/sdcard.zig"),
    @import("../../disk/devs/handlers/fat/fat.zig"),
    @import("../../disk/devs/handlers/posfs/posfs.zig"),
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/hdmi/bcm2711.zig"),
    @import("../../rom/devs/audio/audio.zig"),
    @import("../../rom/resources/videodec/videodec.zig"),
    @import("../../rom/resources/vchiq/vchiq.zig"),
    @import("../../rom/resources/jpeg/jpeg.zig"),
};

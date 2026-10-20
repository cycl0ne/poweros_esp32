// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the VisionFive 2 carries beyond the ones every image has:
//! the display driver for its HDMI port, dma.resource for the chip's DMA
//! controller, and the card slot as a disk the machine can start from -
//! sdcard.device, which hands the card's partitions to expansion.library
//! at cold start, and FAT's handler for them. Both are the disk's own
//! drivers, built into the ROM as they are. And sound: rta.library, the
//! HDMI port's sink (rta-hdmi), the file sink and audio.device, which
//! plays through them and through the outputs USB brings (uac.device,
//! from the disk).

pub const modules = .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
    @import("../../rom/resources/dma/dma.zig"),
    @import("../../disk/devs/sdcard/sdcard.zig"),
    @import("../../disk/devs/handlers/fat/fat.zig"),
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/hdmi/hdmi.zig"),
    @import("../../rom/libs/rta_driver/file/file.zig"),
    @import("../../rom/devs/audio/audio.zig"),
};

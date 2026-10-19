// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the VisionFive 2 carries beyond the ones every image has:
//! the display driver for its HDMI port, audio.device for the port's
//! sound and dma.resource for the DMA controller that feeds it, and the
//! card slot as a disk the machine can start from - sdcard.device, which
//! hands the card's partitions to expansion.library at cold start, and
//! FAT's handler for them. Both are the disk's own drivers, built into
//! the ROM as they are.

pub const modules = .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
    @import("../../rom/resources/dma/dma.zig"),
    @import("../../rom/devs/audio/audio.zig"),
    @import("../../disk/devs/sdcard/sdcard.zig"),
    @import("../../disk/devs/handlers/fat/fat.zig"),
};

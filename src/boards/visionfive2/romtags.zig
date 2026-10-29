// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the VisionFive 2 carries beyond the ones every image has:
//! the display driver for its HDMI port, dma.resource for the chip's DMA
//! controller, jpeg.resource for its JPEG codec, thermal.resource for its
//! temperature sensor, battclock.resource for its RTC, which keeps the
//! date over a reset, and the card slot as a disk the machine can start
//! from - sdcard.device, which hands the card's partitions to
//! expansion.library at cold start, and FAT's handler for them. Both are
//! the disk's own drivers, built into the ROM as they are. And sound: rta.library, the
//! HDMI port's sink (rta-hdmi), the audio jack's (rta-pwmdac), the file
//! sink and audio.device, which plays through them and through the
//! outputs USB brings (uac.device, from the disk).
//!
//! And the SSD on the M.2 slot: pci.library for the PCI Express ports,
//! nvme.device and posfs-handler, the disk's own too - what starting from
//! the SSD takes. nvme.device is a cold-start device in the ROM: it makes
//! pci.library, brings up the SSD and hands its partitions to
//! expansion.library as boot nodes, so a bootable one is started from
//! when its BootPri is the highest of every disk's. The ROM's
//! posfs-handler runs the SSD's posfs partitions unless their table
//! brings a newer one.

pub const modules = .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
    @import("../../rom/resources/dma/dma.zig"),
    @import("../../rom/resources/jpeg/jpeg.zig"),
    @import("../../rom/resources/thermal/thermal.zig"),
    @import("../../rom/resources/battclock/battclock.zig"),
    @import("../../disk/devs/sdcard/sdcard.zig"),
    @import("../../disk/devs/handlers/fat/fat.zig"),
    @import("../../disk/libs/pci/pci.zig"),
    @import("../../disk/devs/nvme/nvme.zig"),
    @import("../../disk/devs/handlers/posfs/posfs.zig"),
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/hdmi/hdmi.zig"),
    @import("../../rom/libs/rta_driver/pwmdac/pwmdac.zig"),
    @import("../../rom/libs/rta_driver/file/file.zig"),
    @import("../../rom/devs/audio/audio.zig"),
};

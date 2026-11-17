// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the Compute Module 4 carries beyond the ones every image
//! has: the display driver, which takes over the picture the VideoCore's
//! firmware lit (CHIP_BCM2711_HVS or CHIP_UEFI_FB, `screen.zig`), and the
//! eMMC as a disk the machine can start from - sdcard.device, which hands
//! the eMMC's partitions to expansion.library at cold start, FAT's handler
//! for its boot partitions and posfs-handler for its volumes, all three
//! the disk's own drivers, built into the ROM as they are (as the
//! VisionFive 2 has them for its card). And sound: rta.library, the HDMI
//! port's sink (rta-hdmi) and audio.device, which plays through it, as
//! the Compute Module 5 has them.

const rom = @import("../../rom/modules.zig");

// What every image has, what draws, the pipe and the clock of things that
// move, and the drivers of this board's parts.
pub const modules = rom.core ++ rom.screen ++ rom.pipe ++ rom.motion ++ .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
    @import("../../disk/devs/sdcard/sdcard.zig"),
    @import("../../disk/devs/handlers/fat/fat.zig"),
    @import("../../disk/devs/handlers/posfs/posfs.zig"),
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/hdmi/bcm2711.zig"),
    @import("../../rom/devs/audio/audio.zig"),
};

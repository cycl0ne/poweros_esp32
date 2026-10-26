// SPDX-License-Identifier: MPL-2.0
//! The ROM tags QEMU's virt machine carries beyond the ones every image
//! has: the display driver for its virtio GPU and its ramfb, and sound
//! that plays into nothing - rta.library, the null sink and audio.device -
//! so a program that plays runs as it would on a board, and the file sink,
//! which plays into a WAV file.
//!
//! And what starting from an NVMe SSD takes, the disk's own drivers built
//! in as they are: pci.library, nvme.device - a cold-start device in the
//! ROM, which hands the SSDs' partitions to expansion.library as boot
//! nodes - and posfs-handler, the file system on them. The machine has no
//! flash: SYS: is the system disk's DH0:.

pub const modules = .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/null/null.zig"),
    @import("../../rom/libs/rta_driver/file/file.zig"),
    @import("../../rom/devs/audio/audio.zig"),
    @import("../../disk/libs/pci/pci.zig"),
    @import("../../disk/devs/nvme/nvme.zig"),
    @import("../../disk/devs/handlers/posfs/posfs.zig"),
};

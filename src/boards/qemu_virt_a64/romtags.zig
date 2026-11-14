// SPDX-License-Identifier: MPL-2.0
//! The ROM tags QEMU's AArch64 virt machine carries beyond the ones every
//! image has: the display driver for its virtio GPU and its ramfb, and
//! sound that plays into nothing - rta.library, the null sink and
//! audio.device - so a program that plays runs as it would on a board, and
//! the file sink, which plays into a WAV file.
//!
//! And what starting from an NVMe SSD takes, as on the RISC-V 64 virt
//! machine: pci.library, nvme.device and posfs-handler, the disk's own,
//! built in as they are.

const rom = @import("../../rom/modules.zig");

// What every image has, what draws, the pipe and the clock of things that move, which this machine keeps in its ROM,
// and the drivers of this board's parts.
pub const modules = rom.core ++ rom.screen ++ rom.pipe ++ rom.motion ++ .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/null/null.zig"),
    @import("../../rom/libs/rta_driver/file/file.zig"),
    @import("../../rom/devs/audio/audio.zig"),
    @import("../../disk/libs/pci/pci.zig"),
    @import("../../disk/devs/nvme/nvme.zig"),
    @import("../../disk/devs/handlers/posfs/posfs.zig"),
};

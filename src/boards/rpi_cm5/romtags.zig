// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the Compute Module 5 carries beyond the ones every image
//! has: the SSD on the IO board's M.2 slot - pci.library for the PCI
//! Express port, nvme.device and posfs-handler, the disk's own, as the
//! VisionFive 2 has them. nvme.device is a cold-start device in the ROM:
//! it makes pci.library, brings up the SSD and hands its partitions to
//! expansion.library as boot nodes. The ROM's posfs-handler runs the
//! SSD's posfs partitions unless their table brings a newer one. The
//! RP1's Ethernet and GPIO, and HDMI, come later.

pub const modules = .{
    @import("../../disk/libs/pci/pci.zig"),
    @import("../../disk/devs/nvme/nvme.zig"),
    @import("../../disk/devs/handlers/posfs/posfs.zig"),
};

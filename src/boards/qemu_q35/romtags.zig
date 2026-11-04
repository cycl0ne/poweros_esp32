// SPDX-License-Identifier: MPL-2.0
//! The ROM tags QEMU's q35 machine carries beyond the ones every image
//! has: the display driver, for the framebuffer the firmware lit and
//! handed over - the kernel declares it as the board's panel
//! (`system.zig`), and the driver copies the picture into it.
//!
//! What starting from an NVMe disk takes - pci.library, nvme.device and
//! posfs-handler, as both other emulated 64-bit boards carry them - comes
//! with PCI, which is the next item of the list in `todo/port_x86_64/`.
//! Until then SYS: is the disk image the stub reads off the boot
//! partition.

pub const modules = .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
};

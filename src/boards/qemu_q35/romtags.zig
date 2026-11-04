// SPDX-License-Identifier: MPL-2.0
//! The ROM tags QEMU's q35 machine carries beyond the ones every image
//! has: the display driver, for the framebuffer the firmware lit and
//! handed over - the kernel declares it as the board's panel
//! (`system.zig`), and the driver copies the picture into it.
//!
//! battclock.resource for the clock the machine keeps its date in, which
//! every machine of this architecture has, and power.resource for turning
//! the machine off and for its power button.
//!
//! And what starting from an NVMe disk takes, as on both other emulated
//! 64-bit boards: pci.library, nvme.device and posfs-handler, the disk's
//! own, built in as they are. The machine has no flash: SYS: is the system
//! disk's DH0:, and the firmware's boot partition carries the kernel
//! alone.

pub const modules = .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
    @import("../../rom/resources/battclock/battclock.zig"),
    @import("../../rom/resources/power/power.zig"),
    @import("../../disk/libs/pci/pci.zig"),
    @import("../../disk/devs/nvme/nvme.zig"),
    @import("../../disk/devs/handlers/posfs/posfs.zig"),
};

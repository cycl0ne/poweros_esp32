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
//!
//! amdgpu.resource for an AMD graphics device: it claims the function
//! and reads the table of its blocks, which the display driver and every
//! other driver of a part of the device ask it for. A machine without one
//! has the resource all the same, and it says there is none.
//!
//! watchdog.resource for the chipset's watchdog, which an AMD chipset
//! has: it comes up after pci.library, finds the chipset there and starts
//! nothing until a program arms it. A machine without one has the
//! resource all the same, and arming it is refused.
//!
//! jpeg.resource for the JPEG decoder an AMD graphics device has beside
//! its video decoder: it touches nothing as it starts, and its first
//! decode finds the decoder through amdgpu.resource and starts it - only
//! while the watchdog is armed. A machine without one has the resource
//! all the same, and its decodes say there is no codec.
//!
//! And sound: rta.library, the machine's own audio controllers
//! (rta-hda), the sink that plays into a file, the one that plays into
//! nothing, and audio.device over them. An audio controller of this
//! architecture is a function on PCI that the driver finds for itself,
//! so a machine with one has sound of its own and a machine with none
//! falls through to the file sink and the null one, and a program that
//! plays runs either way.

pub const modules = .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
    @import("../../rom/resources/battclock/battclock.zig"),
    @import("../../rom/resources/power/power.zig"),
    @import("../../disk/libs/pci/pci.zig"),
    @import("../../rom/resources/amdgpu/amdgpu.zig"),
    @import("../../rom/resources/watchdog/watchdog.zig"),
    @import("../../rom/resources/jpeg/jpeg.zig"),
    @import("../../disk/devs/nvme/nvme.zig"),
    @import("../../disk/devs/handlers/posfs/posfs.zig"),
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/hda/hda.zig"),
    @import("../../rom/libs/rta_driver/null/null.zig"),
    @import("../../rom/libs/rta_driver/file/file.zig"),
    @import("../../rom/devs/audio/audio.zig"),
};

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
//! ps2.resource for the keyboard and the pointing device on the machine's
//! keyboard controller - a laptop's own keyboard and TrackPoint - which
//! hands their keys and moves to keyboard.device and mouse.device. A
//! machine without the controller has the resource all the same, and it
//! says there is none.
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
//! videodec.resource for the video decoder of the same device: found
//! through amdgpu.resource as it starts, by reading only, and started by
//! the first decoder opened - only while the watchdog is armed. A machine
//! without one has the resource all the same, and it answers no codecs.
//!
//! And sound: rta.library, the machine's own audio controllers
//! (rta-hda), the sink that plays into a file, the one that plays into
//! nothing, and audio.device over them. An audio controller of this
//! architecture is a function on PCI that the driver finds for itself,
//! so a machine with one has sound of its own and a machine with none
//! falls through to the file sink and the null one, and a program that
//! plays runs either way.
//!
//! And what starting from a USB stick takes: rdb.library, which reads a
//! stick's table and gives its partitions their drives; usb.library,
//! xhci.device for the controllers and usb/disk.device for the stick, none
//! of them started at cold start - ramlib makes each from its tag when it
//! is first opened; and usbstart, which opens them where the disk the
//! firmware started this system from has not been found by then. A system
//! on an SSD starts none of them here, and finds them in the ROM when
//! `S:Startup-Sequence` starts the buses.

pub const modules = .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
    @import("../../rom/resources/battclock/battclock.zig"),
    @import("../../rom/resources/power/power.zig"),
    @import("../../rom/resources/ps2/ps2.zig"),
    @import("../../disk/libs/pci/pci.zig"),
    @import("../../rom/resources/amdgpu/amdgpu.zig"),
    @import("../../rom/resources/watchdog/watchdog.zig"),
    @import("../../rom/resources/jpeg/jpeg.zig"),
    @import("../../rom/resources/videodec/videodec.zig"),
    @import("../../disk/devs/nvme/nvme.zig"),
    @import("../../disk/devs/handlers/posfs/posfs.zig"),
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/hda/hda.zig"),
    @import("../../rom/libs/rta_driver/null/null.zig"),
    @import("../../rom/libs/rta_driver/file/file.zig"),
    @import("../../rom/devs/audio/audio.zig"),
    @import("../../disk/libs/rdb/rdb.zig"),
    @import("../../disk/libs/usb/usb.zig"),
    @import("../../disk/devs/xhci/xhci.zig"),
    @import("../../disk/devs/usb/disk/disk.zig"),
    @import("../../rom/boot/usbstart.zig"),
};

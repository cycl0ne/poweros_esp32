// SPDX-License-Identifier: MPL-2.0
//! usbstart: the USB buses started as the machine comes up, where the
//! disk the firmware started this system from is still to be found.
//!
//! A machine started from a USB stick has its system on that stick, and
//! a stick is found only once its bus runs: usb.library, the controller's
//! device and the stick's class driver are in the ROM of such a machine,
//! none of them started at cold start - ramlib makes each from its ROM
//! tag the first time it is opened. This is what opens them: an after-DOS
//! resident below ramlib, which dos.library starts ahead of choosing the
//! system's disk when the firmware named a partition (expansion.library's
//! IsBootPartition) and no driver has noted a drive on its disk yet
//! (BootDrive). Every bus is started, from 0 until usb.library says there
//! is no such bus; the stick's driver then gives its partitions their
//! drives and notes the system's, which dos.library is waiting for.
//!
//! Where the firmware named nothing, or the disk is found already - a
//! system on an SSD, whose driver read its table at cold start - it does
//! nothing, and the buses are `C:USB AUTO`'s to start from
//! `S:Startup-Sequence` as on every other machine. Started here, they run
//! with the ROM's class drivers alone until then: `USB AUTO` has each
//! offer what no driver took to the ones in `DEVS:usb/`.

const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const ExecBase = sdk.interface.exec.ExecBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const UsbBase = sdk.interface.usb.UsbBase;

pub const NAME = "usbstart";
const VERSION = 1;
const REVISION = 0;
const VERSION_STRING = "\x00$VER: usbstart 1.0 (13.11.2026)\r\n";

/// The expansion.library that has IsBootPartition and BootDrive.
const expansion_revision = 5;
/// A machine's buses are counted until one is not there; this ends the
/// count on a machine whose answer never comes.
const bus_most = 32;

fn init(seg_list: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*anyopaque {
    _ = seg_list;
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return null;
    defer sys.CloseLibrary(expansion_lib);
    if (expansion_lib.version == 1 and expansion_lib.revision < expansion_revision) return null;
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    if (!eb.IsBootPartition(null) or eb.BootDrive() != null) return null;

    const usb_lib = sys.OpenLibrary(usb.USBNAME, 1) orelse {
        exec.kprintf(sys, "%s: no %s, so a disk on USB is not found\n", .{ @as([*:0]const u8, NAME), @as([*:0]const u8, usb.USBNAME) });
        return null;
    };
    // A bus that runs holds the library open itself.
    defer sys.CloseLibrary(usb_lib);
    const ub: *UsbBase = @ptrCast(usb_lib);
    var started: u32 = 0;
    var bus: u32 = 0;
    while (bus < bus_most) : (bus += 1) {
        const result = ub.StartUSB(bus);
        if (result == usb.USBERR_NOBUS) break;
        if (result == 0) started += 1;
    }
    exec.kprintf(sys, "%s: %d USB buses started, to find the disk the firmware started from\n", .{ @as([*:0]const u8, NAME), started });
    return null;
}

/// After ramlib, which makes usb.library and the devices under it from
/// their ROM tags as they are opened here.
pub export const usbstart_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &usbstart_tag,
    .flags = exec.RTF_AFTERDOS,
    .version = VERSION,
    .type = .unknown,
    .pri = -110,
    .name = NAME,
    .id_string = VERSION_STRING[1..], // past the NUL: a C string
    .init = &init,
};

comptime {
    _ = REVISION;
}

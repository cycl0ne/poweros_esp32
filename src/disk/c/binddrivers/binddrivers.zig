// SPDX-License-Identifier: MIT
//! BindDrivers: the block devices in DEVS: for this board's hardware
//! started, so that each mounts its drives. Built against the SDK only.
//!
//!   BindDrivers
//!
//! expansion.library lists the units of every block device the board has
//! (ObtainDeviceUnits with DEVIF_BLOCK): a device in DEVS: is listed only
//! for the parts the board was built with - sdcard.device where there is
//! a card slot. Each one listed that is a file in DEVS: is opened once
//! and closed again; opening loads it, and a block device that starts
//! makes the drives of what is in it (a card's partitions, or SD0:) and
//! stays. The ROM's devices are up already, and a USB class driver is
//! loaded by usb.library when what it drives is plugged in, so neither
//! is opened. A device that finds no hardware behind it does not start,
//! and is passed over without a word.
//!
//! The startup-sequence runs it after S:User-Startup, so a drive mounted
//! there by hand - `Mount SD0:` from the MountList - is the one the device
//! finds, and uses.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "BindDrivers";
const VERSION_STRING = "\x00$VER: BindDrivers 1.0 (18.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "";

/// The expansion.library that lists devices by what they speak.
const expansion_version = 1;

const MSG_NOLIBRARY = "No %s\n";

/// Whether a device speaks a command set.
fn speaks(unit: *const devices.DeviceUnit, set: u32) bool {
    var index: usize = 0;
    while (unit.speaks[index] != 0) : (index += 1) {
        if (unit.speaks[index] == set) return true;
    }
    return false;
}

fn sameName(one: [*:0]const u8, other: [*:0]const u8) bool {
    var index: usize = 0;
    while (one[index] == other[index]) : (index += 1) {
        if (one[index] == 0) return true;
    }
    return false;
}

/// A device opened on one of its units and closed again: loaded and
/// started, if it was not.
fn start(sys: *ExecBase, name: [*:0]const u8, unit: u32) void {
    const port = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(port);
    var io: exec.IOStdReq = .{ .req = .{ .message = .{ .reply_port = port, .length = @sizeOf(exec.IOStdReq) } } };
    if (sys.OpenDevice(name, unit, &io.req, 0) != 0) return;
    sys.CloseDevice(&io.req);
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, expansion_version) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{sdk.expansion.EXPANSIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);

    const list = eb.ObtainDeviceUnits(devices.DEVIF_BLOCK, null) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer eb.ReleaseDeviceUnits(list);

    // The units come by device: each device is opened on its first one.
    var last: ?[*:0]const u8 = null;
    var it = list.iterator();
    while (it.next()) |node| {
        const unit: *const devices.DeviceUnit = @ptrCast(@alignCast(node));
        const name = unit.node.name orelse continue;
        if (last) |previous| {
            if (sameName(previous, name)) continue;
        }
        last = name;
        if (unit.flags & devices.DUF_ROM != 0) continue;
        if (speaks(unit, devices.DEVIF_USBCLASS)) continue;
        start(sys, name, unit.unit);
    }
    return dos.RETURN_OK;
}

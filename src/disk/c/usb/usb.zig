// SPDX-License-Identifier: MIT
//! USB: a USB bus started or stopped. Built against the SDK only.
//!
//!   USB [START/S] [STOP/S] [AUTO/S] [BUS/K/N]
//!
//!   USB START         bus 0 started: its controller up, what is plugged
//!                     in set up and given to its drivers
//!   USB STOP BUS 1    bus 1 stopped, everything on it let go
//!   USB AUTO          every bus whose socket can only be a host started:
//!                     what the startup-sequence does, so a board whose
//!                     keyboard and mouse are USB has them from the start
//!   USB               which buses run
//!
//! A bus is one of the board's USB sockets that may be a host, in the
//! order the board lists them (usb.library's StartUSB). On the ESP32-S3
//! boards the socket is the console's too, so AUTO leaves it, and
//! starting its bus is to take it over.

const sdk = @import("sdk");
const dos = sdk.dos;
const usb = sdk.usb;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UsbBase = sdk.interface.usb.UsbBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const st_expansion = sdk.expansion;
const st = st_expansion.systemtags;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "USB";
const VERSION_STRING = "\x00$VER: USB 1.0 (11.10.2026)\r\n";

const template = "START/S,STOP/S,AUTO/S,BUS/K/N";
const arg_start = 0;
const arg_stop = 1;
const arg_auto = 2;
const arg_bus = 3;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    if (argv[arg_start] != 0 and argv[arg_stop] != 0) {
        _ = dl.PutStr("only one of START or STOP\n");
        return dos.RETURN_ERROR;
    }
    const bus: u32 = if (argv[arg_bus] != 0) @intCast(@as(*const i32, @ptrFromInt(argv[arg_bus])).*) else 0;

    const usb_lib = sys.OpenLibrary(usb.USBNAME, 1) orelse {
        _ = Printf(dl, "no %s\n", .{usb.USBNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(usb_lib);
    const ub: *UsbBase = @ptrCast(usb_lib);

    if (argv[arg_start] != 0) {
        const result = ub.StartUSB(bus);
        if (result == 0) return dos.RETURN_OK;
        const why: [*:0]const u8 = switch (result) {
            usb.USBERR_NOBUS => "this board has no such bus",
            usb.USBERR_CONTROLLER => "its controller could not be opened",
            else => "no memory",
        };
        _ = Printf(dl, "bus %d: %s\n", .{ bus, why });
        return dos.RETURN_ERROR;
    }
    if (argv[arg_stop] != 0) {
        ub.StopUSB(bus);
        return dos.RETURN_OK;
    }
    if (argv[arg_auto] != 0) return startHostOnly(sys, dl, ub);

    // Which buses run: those with a root hub on the list.
    var running: [usb.USB_MAX_BUSES]bool = @splat(false);
    const list = ub.ObtainUSBDeviceList();
    var it = list.iterator();
    while (it.next()) |node| {
        const device: *usb.USBDevice = @fieldParentPtr("node", node);
        if (device.depth == 0 and device.bus < running.len) running[device.bus] = true;
    }
    ub.ReleaseUSBDeviceList();
    var any = false;
    for (running, 0..) |runs, number| {
        if (!runs) continue;
        any = true;
        _ = Printf(dl, "bus %d runs\n", .{@as(u32, @intCast(number))});
    }
    if (!any) _ = dl.PutStr("no bus runs\n");
    return dos.RETURN_OK;
}

/// Every bus whose socket can only be a host, started; the board's USB
/// parts say which, in the order StartUSB numbers them.
fn startHostOnly(sys: *ExecBase, dl: *DosBase, ub: *UsbBase) i32 {
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(utility_lib);
    const utility: *UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(st_expansion.EXPANSIONNAME, 1) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *ExpansionBase = @ptrCast(expansion_lib);
    var bus: u32 = 0;
    var part = eb.FindBoardPart(null, st.PARTKIND_USB, st.CHIP_ANY);
    while (part) |it| : (part = eb.FindBoardPart(it, st.PARTKIND_USB, st.CHIP_ANY)) {
        const roles = utility.GetTagData(st.PART_UsbRoles, st.USBROLE_HOST, it.tags);
        if (roles & st.USBROLE_HOST == 0) continue;
        if (roles & st.USBROLE_DEVICE == 0) {
            const result = ub.StartUSB(bus);
            if (result != 0) _ = Printf(dl, "bus %d did not start (%d)\n", .{ bus, result });
        }
        bus += 1;
    }
    return dos.RETURN_OK;
}

export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

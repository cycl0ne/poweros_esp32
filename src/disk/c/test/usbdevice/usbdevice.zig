// SPDX-License-Identifier: MIT
//! USBDevice: a device driven from a program, through usb.library alone. Built
//! against the SDK only.
//!
//!   USBDevice ADDRESS/A/N,BUS/K/N,INTERFACE/K/N,READS/K/N
//!
//! The device at ADDRESS is asked for its device descriptor with a
//! control transfer of the program's own (DoUSBControl), which is
//! printed. If INTERFACE is given, that interface is claimed
//! (ClaimUSBInterface) - it must be one no class driver took - a pipe is
//! opened to its first interrupt or bulk IN endpoint, and READS packets
//! (default 5) are read from it and printed, each as it comes; Ctrl-C
//! stops. QEMU's `usb-tablet` is such a device: no driver takes it, and
//! it reports the pointer's place when it moves.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const usb = sdk.usb;
const d = usb.descriptors;
const usbhc = sdk.devices.usbhc;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UsbBase = sdk.interface.usb.UsbBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "USBDevice";
const VERSION_STRING = "\x00$VER: USBDevice 1.0 (11.10.2026)\r\n";

const template = "ADDRESS/A/N,BUS/K/N,INTERFACE/K/N,READS/K/N";
const arg_address = 0;
const arg_bus = 1;
const arg_interface = 2;
const arg_reads = 3;

fn numberAt(slot: usize, default: i32) i32 {
    if (slot == 0) return default;
    return @as(*const i32, @ptrFromInt(slot)).*;
}

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
    const address = numberAt(argv[arg_address], 0);
    const bus = numberAt(argv[arg_bus], 0);
    const interface_number = numberAt(argv[arg_interface], -1);
    const reads = numberAt(argv[arg_reads], 5);

    const usb_lib = sys.OpenLibrary(usb.USBNAME, 1) orelse {
        _ = Printf(dl, "no %s\n", .{usb.USBNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(usb_lib);
    const ub: *UsbBase = @ptrCast(usb_lib);

    // The device, found on the list; it stays while this runs only as
    // long as it stays plugged in - a test may live with that.
    var found: ?*usb.USBDevice = null;
    const list = ub.ObtainUSBDeviceList();
    var it = list.iterator();
    while (it.next()) |node| {
        const device: *usb.USBDevice = @fieldParentPtr("node", node);
        if (device.address == address and device.bus == bus) found = device;
    }
    ub.ReleaseUSBDeviceList();
    const device = found orelse {
        _ = Printf(dl, "no device at address %d on bus %d\n", .{ address, bus });
        return dos.RETURN_ERROR;
    };

    // The device descriptor, asked for afresh.
    var descriptor: d.DeviceDescriptor = .{};
    const setup = usb.SetupPacket{
        .request_type = d.USB_DIR_IN,
        .request = d.USB_REQ_GET_DESCRIPTOR,
        .value = @as(u16, d.USB_DT_DEVICE) << 8,
        .index = 0,
        .length = @sizeOf(d.DeviceDescriptor),
    };
    var got: u32 = 0;
    const err = ub.DoUSBControl(device, &setup, &descriptor, &got);
    if (err != 0) {
        _ = Printf(dl, "GET_DESCRIPTOR: error %d\n", .{err});
        return dos.RETURN_ERROR;
    }
    _ = Printf(dl, "device descriptor, %d bytes: USB %x.%02x, class %d/%d/%d, endpoint 0 %d bytes\n", .{
        got,                                   @as(u32, descriptor.bcd_usb >> 8),    @as(u32, descriptor.bcd_usb & 0xFF),
        @as(u32, descriptor.device_class),     @as(u32, descriptor.device_subclass), @as(u32, descriptor.device_protocol),
        @as(u32, descriptor.max_packet_size0),
    });
    _ = Printf(dl, "  vendor %04x, product %04x, release %x, %d configuration(s)\n", .{
        @as(u32, descriptor.vendor_id), @as(u32, descriptor.product_id), @as(u32, descriptor.bcd_device), @as(u32, descriptor.num_configurations),
    });
    if (interface_number < 0) return dos.RETURN_OK;
    return readInterface(sys, dl, ub, device, @intCast(interface_number), reads);
}

/// The interface claimed, and packets read from its first IN endpoint.
fn readInterface(sys: *ExecBase, dl: *DosBase, ub: *UsbBase, device: *usb.USBDevice, number: u32, reads: i32) i32 {
    var interface = ub.FindUSBInterface(device, null, -1, -1, -1);
    while (interface) |found| : (interface = ub.FindUSBInterface(device, found, -1, -1, -1)) {
        if (found.interface_number == number and found.alternate_setting == 0) break;
    }
    const chosen = interface orelse {
        _ = Printf(dl, "the device has no interface %d\n", .{number});
        return dos.RETURN_ERROR;
    };
    if (!ub.ClaimUSBInterface(device, number, COMMAND_NAME)) {
        _ = Printf(dl, "interface %d is %s's\n", .{ number, device.drivers[number] orelse "someone else" });
        return dos.RETURN_ERROR;
    }
    defer ub.ReleaseUSBInterface(device, number);
    const endpoint = ub.FindUSBEndpoint(device, chosen, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_INT) orelse
        ub.FindUSBEndpoint(device, chosen, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_BULK) orelse {
        _ = Printf(dl, "interface %d has no IN endpoint\n", .{number});
        return dos.RETURN_ERROR;
    };
    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    const pipe = ub.OpenUSBPipe(device, endpoint.endpoint_address, port) orelse return dos.RETURN_FAIL;
    defer ub.CloseUSBPipe(pipe);
    _ = Printf(dl, "reading endpoint 0x%02x, %d bytes a packet (Ctrl-C stops)\n", .{ @as(u32, endpoint.endpoint_address), @as(u32, pipe.io.max_packet) });

    var buffer: [64]u8 = undefined;
    var count: i32 = 0;
    while (count < reads) : (count += 1) {
        pipe.io.std.data = &buffer;
        pipe.io.std.length = @min(@as(u32, pipe.io.max_packet), buffer.len);
        sys.SendIO(&pipe.io.std.req);
        const got = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0 and sys.CheckIO(&pipe.io.std.req) == null) {
            _ = sys.AbortIO(&pipe.io.std.req);
            _ = sys.WaitIO(&pipe.io.std.req);
            _ = dl.PutStr("stopped\n");
            return dos.RETURN_WARN;
        }
        _ = sys.WaitIO(&pipe.io.std.req);
        if (pipe.io.std.req.err != 0) {
            _ = Printf(dl, "read: error %d\n", .{@as(i32, pipe.io.std.req.err)});
            return dos.RETURN_ERROR;
        }
        const length: usize = @intCast(pipe.io.std.actual);
        _ = Printf(dl, "%3d:", .{count + 1});
        for (buffer[0..length]) |byte| _ = Printf(dl, " %02x", .{@as(u32, byte)});
        _ = dl.PutStr("\n");
    }
    return dos.RETURN_OK;
}

export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

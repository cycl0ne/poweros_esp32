// SPDX-License-Identifier: MIT
//! USBInfo: what is on the USB buses. Built against the SDK only.
//!
//!   USBInfo [DEVICE/K/N] [FULL/S] [PORTS/S]
//!
//!   USBInfo            every device: where it is, how fast, what it is,
//!                      the most current it draws, and who drives each
//!                      of its interfaces
//!   USBInfo FULL       with each device's USB version and its own, its
//!                      serial number, its place below the root hub, its
//!                      speed, the current it draws of what its port
//!                      gives, its interfaces and endpoints, and the
//!                      states its SuperSpeed link rests in
//!   USBInfo DEVICE 3   the device at address 3 only
//!   USBInfo PORTS      the chip's USB ports and who holds each
//!                      (usbport.resource) instead
//!
//! The list is copied under usb.library's lock and printed after it, so a
//! device plugged in meanwhile is not held up by the printing.
//!
//! What a device draws is its configuration's bMaxPower, which counts
//! 8 mA at SuperSpeed and 2 mA below it. What its port gives is what the
//! USB rules give it: 900 mA at SuperSpeed and 500 mA below it on a root
//! hub's port or on one of a hub that powers itself, 150 mA and 100 mA on
//! one of a hub that runs on the bus itself. How much a board's sockets
//! can really give, the stack does not know.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const usb = sdk.usb;
const d = usb.descriptors;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UsbBase = sdk.interface.usb.UsbBase;
const usbhc = sdk.devices.usbhc;
const usbport = sdk.resources.usbport;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "USBInfo";
const VERSION_STRING = "\x00$VER: USBInfo 1.4 (28.11.2026)\r\n";

const template = "DEVICE/K/N,FULL/S,PORTS/S";
const arg_device = 0;
const arg_full = 1;
const arg_ports = 2;

const max_devices = 32;
const config_bytes = 256;
/// The most ports from a root hub down to a device: five hubs and the
/// device's own, and one to spare.
const max_route = 7;

/// A device, copied out of the list.
const Copy = struct {
    bus: u32 = 0,
    address: u8 = 0,
    speed: u8 = 0,
    port: u8 = 0,
    depth: u8 = 0,
    hub_address: u8 = 0,
    /// How many hubs are above the hub it is plugged into, and whether
    /// that hub's configuration says it powers itself.
    hub_depth: u8 = 0,
    hub_powers_itself: bool = false,
    /// The ports from the root hub down to it, the root hub's first.
    route: [max_route]u8 = @splat(0),
    route_length: u8 = 0,
    flags: u32 = 0,
    descriptor: d.DeviceDescriptor = .{},
    product: [40]u8 = @splat(0),
    manufacturer: [40]u8 = @splat(0),
    serial: [40]u8 = @splat(0),
    drivers: [usb.USB_MAX_INTERFACES][24]u8 = @splat(@splat(0)),
    config: [config_bytes]u8 = @splat(0),
    config_length: u32 = 0,
};

fn copyString(into: []u8, from: ?[*:0]const u8) void {
    const text = from orelse return;
    var i: usize = 0;
    while (i + 1 < into.len and text[i] != 0) : (i += 1) into[i] = text[i];
    into[i] = 0;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const only: i32 = if (argv[arg_device] != 0) @as(*const i32, @ptrFromInt(argv[arg_device])).* else -1;
    const full = argv[arg_full] != 0;
    if (argv[arg_ports] != 0) return printPorts(sys, dl);

    const usb_lib = sys.OpenLibrary(usb.USBNAME, 1) orelse {
        _ = Printf(dl, "no %s\n", .{usb.USBNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(usb_lib);
    const ub: *UsbBase = @ptrCast(usb_lib);

    const memory = sys.AllocVec(@sizeOf([max_devices]Copy), exec.MEMF_CLEAR) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(memory);
    const copies: *[max_devices]Copy = @ptrCast(@alignCast(memory));
    var count: usize = 0;

    const list = ub.ObtainUSBDeviceList();
    var it = list.iterator();
    while (it.next()) |node| {
        if (count >= max_devices) break;
        const device: *usb.USBDevice = @fieldParentPtr("node", node);
        if (only >= 0 and device.address != only) continue;
        const copy = &copies[count];
        copy.* = .{
            .bus = device.bus,
            .address = device.address,
            .speed = device.speed,
            .port = device.port,
            .depth = device.depth,
            .hub_address = if (device.hub) |hub| hub.address else 0,
            .flags = device.flags,
            .descriptor = device.descriptor,
        };
        copyString(&copy.product, device.product);
        copyString(&copy.manufacturer, device.manufacturer);
        copyString(&copy.serial, device.serial);
        copy.route_length = routeOf(device, &copy.route);
        if (device.hub) |hub| {
            copy.hub_depth = hub.depth;
            if (hub.config) |config| {
                const hub_config: *align(1) const d.ConfigDescriptor = @ptrCast(config);
                if (hub.config_length >= @sizeOf(d.ConfigDescriptor)) copy.hub_powers_itself = hub_config.attributes & d.USB_CONFIG_SELF_POWERED != 0;
            }
        }
        for (device.drivers, 0..) |driver, n| copyString(&copy.drivers[n], driver);
        if (device.config) |config| {
            copy.config_length = @min(device.config_length, config_bytes);
            @memcpy(copy.config[0..copy.config_length], config[0..copy.config_length]);
        }
        count += 1;
    }
    ub.ReleaseUSBDeviceList();

    if (count == 0) {
        _ = dl.PutStr("no USB device (USB START starts a bus)\n");
        return dos.RETURN_OK;
    }
    _ = dl.PutStr("bus addr hub port speed  id         class    mA  device\n");
    for (copies[0..count]) |*copy| {
        printDevice(dl, copy);
        if (full) {
            printDetails(dl, copy);
            printConfig(dl, copy);
        }
    }
    return dos.RETURN_OK;
}

/// Each of the chip's USB ports and who holds it; one nobody holds is
/// with the controller the chip starts it with.
fn printPorts(sys: *ExecBase, dl: *DosBase) i32 {
    const found = sys.OpenResource(usbport.USBPORTNAME) orelse {
        _ = Printf(dl, "no %s\n", .{usbport.USBPORTNAME});
        return dos.RETURN_WARN;
    };
    const pb: *usbport.UsbPortBase = @ptrCast(@alignCast(found));
    var port: u32 = 0;
    while (port < usbport.USBPORT_PORTS) : (port += 1) {
        const holder: [*:0]const u8 = pb.USBPortOwner(port) orelse "nobody";
        _ = Printf(dl, "port %u: %s\n", .{ port, holder });
    }
    return dos.RETURN_OK;
}

fn speedName(speed: u8) [*:0]const u8 {
    return switch (speed) {
        usbhc.USB_SPEED_LOW => "low",
        usbhc.USB_SPEED_HIGH => "high",
        usbhc.USB_SPEED_SUPER => "super",
        else => "full",
    };
}

/// The most a device at `speed` moves, as the USB rules have it.
fn rateName(speed: u8) [*:0]const u8 {
    return switch (speed) {
        usbhc.USB_SPEED_LOW => "1.5 Mbit/s",
        usbhc.USB_SPEED_HIGH => "480 Mbit/s",
        usbhc.USB_SPEED_SUPER => "5 Gbit/s or more",
        else => "12 Mbit/s",
    };
}

/// The ports from the root hub down to `device`, into `into`, the root
/// hub's first; how many there are, 0 for a root hub or one too deep.
fn routeOf(device: *const usb.USBDevice, into: *[max_route]u8) u8 {
    var length: u8 = 0;
    var at = device;
    while (at.hub) |hub| {
        length += 1;
        if (length > max_route) return 0;
        at = hub;
    }
    var place = length;
    at = device;
    while (at.hub) |hub| {
        place -= 1;
        into[place] = at.port;
        at = hub;
    }
    return length;
}

/// The most current the device draws in the configuration it is in, in
/// mA; null for a root hub, or for a device in none.
fn drawOf(copy: *const Copy) ?u32 {
    if (copy.depth == 0 or copy.config_length < @sizeOf(d.ConfigDescriptor)) return null;
    const config: *align(1) const d.ConfigDescriptor = @ptrCast(&copy.config);
    const unit: u32 = if (copy.speed == usbhc.USB_SPEED_SUPER) 8 else 2;
    return @as(u32, config.max_power) * unit;
}

/// The current the device's port gives it by the USB rules, in mA; null
/// for a root hub.
fn portGives(copy: *const Copy) ?u32 {
    if (copy.depth == 0) return null;
    const super = copy.speed == usbhc.USB_SPEED_SUPER;
    if (copy.hub_depth == 0 or copy.hub_powers_itself) return if (super) 900 else 500;
    return if (super) 150 else 100;
}

fn className(class: u8) [*:0]const u8 {
    return switch (class) {
        d.USB_CLASS_PER_INTERFACE => "-",
        d.USB_CLASS_AUDIO => "audio",
        d.USB_CLASS_COMM => "comm",
        d.USB_CLASS_HID => "hid",
        d.USB_CLASS_PRINTER => "print",
        d.USB_CLASS_MASS_STORAGE => "disk",
        d.USB_CLASS_HUB => "hub",
        d.USB_CLASS_CDC_DATA => "data",
        d.USB_CLASS_VENDOR_SPEC => "vendor",
        else => "?",
    };
}

fn printDevice(dl: *DosBase, copy: *const Copy) void {
    const desc = copy.descriptor;
    _ = Printf(dl, "%3d %4d %3d %4d %-5s  %04x:%04x  %-6s ", .{
        copy.bus,              @as(u32, copy.address),   @as(u32, copy.hub_address), @as(u32, copy.port),
        speedName(copy.speed), @as(u32, desc.vendor_id), @as(u32, desc.product_id),  className(desc.device_class),
    });
    const draw = drawOf(copy);
    if (draw) |current| {
        _ = Printf(dl, "%4d  ", .{current});
    } else {
        _ = dl.PutStr("   -  ");
    }
    const name: [*:0]const u8 = if (copy.product[0] != 0) @ptrCast(&copy.product) else "(no name)";
    _ = Printf(dl, "%s", .{name});
    if (copy.manufacturer[0] != 0) _ = Printf(dl, ", %s", .{@as([*:0]const u8, @ptrCast(&copy.manufacturer))});
    if (copy.flags & usb.USBDF_FAILED != 0) _ = dl.PutStr(" - did not answer");
    if (draw) |current| {
        if (current > portGives(copy).?) _ = dl.PutStr(" - draws more than its port gives");
    }
    _ = dl.PutStr("\n");
    for (copy.drivers, 0..) |driver, n| {
        if (driver[0] == 0) continue;
        _ = Printf(dl, "                                    interface %d: %s\n", .{ @as(u32, @intCast(n)), @as([*:0]const u8, @ptrCast(&driver)) });
    }
}

/// The device's USB version and its own, its serial number, its place
/// below the root hub and its speed, and the current it draws of what its
/// port gives.
fn printDetails(dl: *DosBase, copy: *const Copy) void {
    const desc = copy.descriptor;
    _ = Printf(dl, "      USB %x.%x, version %x.%02x", .{
        @as(u32, desc.bcd_usb >> 8),    @as(u32, (desc.bcd_usb >> 4) & 0xF),
        @as(u32, desc.bcd_device >> 8), @as(u32, desc.bcd_device & 0xFF),
    });
    if (copy.serial[0] != 0) _ = Printf(dl, ", serial %s", .{@as([*:0]const u8, @ptrCast(&copy.serial))});
    _ = dl.PutStr("\n");
    if (copy.route_length == 0) {
        _ = Printf(dl, "      the root hub of bus %d\n", .{copy.bus});
    } else {
        _ = Printf(dl, "      at %d-", .{copy.bus});
        for (copy.route[0..copy.route_length], 0..) |port, place| {
            if (place != 0) _ = dl.PutStr(".");
            _ = Printf(dl, "%d", .{@as(u32, port)});
        }
        _ = Printf(dl, ", up to %s\n", .{rateName(copy.speed)});
    }
    const draw = drawOf(copy) orelse return;
    const gives = portGives(copy).?;
    if (draw > gives) {
        _ = Printf(dl, "      draws up to %d mA, more than the %d mA its port gives", .{ draw, gives });
    } else if (draw == 0) {
        _ = Printf(dl, "      draws nothing of the %d mA its port gives", .{gives});
    } else {
        _ = Printf(dl, "      draws up to %d mA of the %d mA its port gives", .{ draw, gives });
    }
    const config: *align(1) const d.ConfigDescriptor = @ptrCast(&copy.config);
    _ = dl.PutStr(if (config.attributes & d.USB_CONFIG_SELF_POWERED != 0) ", powering itself" else ", from the bus");
    if (config.attributes & d.USB_CONFIG_REMOTE_WAKEUP != 0) _ = dl.PutStr("; it can wake the machine");
    _ = dl.PutStr("\n");
}

/// The states the device's link rests in, then each interface and
/// endpoint of its configuration.
fn printConfig(dl: *DosBase, copy: *const Copy) void {
    const resting: [*:0]const u8 = switch (copy.flags & (usb.USBDF_U1 | usb.USBDF_U2)) {
        usb.USBDF_U1 | usb.USBDF_U2 => "U1 and U2",
        usb.USBDF_U1 => "U1",
        usb.USBDF_U2 => "U2",
        else => "",
    };
    if (resting[0] != 0) _ = Printf(dl, "      link rests in %s when idle\n", .{resting});
    var at: u32 = 0;
    while (at + 2 <= copy.config_length) {
        const length = copy.config[at];
        if (length < 2 or at + length > copy.config_length) break;
        const kind = copy.config[at + 1];
        if (kind == d.USB_DT_INTERFACE and length >= 9) {
            const interface: *align(1) const d.InterfaceDescriptor = @ptrCast(&copy.config[at]);
            _ = Printf(dl, "      interface %d.%d  class %s (%d/%d/%d), %d endpoints\n", .{
                @as(u32, interface.interface_number),   @as(u32, interface.alternate_setting),
                className(interface.interface_class),   @as(u32, interface.interface_class),
                @as(u32, interface.interface_subclass), @as(u32, interface.interface_protocol),
                @as(u32, interface.num_endpoints),
            });
        } else if (kind == d.USB_DT_ENDPOINT and length >= 7) {
            const endpoint: *align(1) const d.EndpointDescriptor = @ptrCast(&copy.config[at]);
            const kinds = [_][*:0]const u8{ "control", "isochronous", "bulk", "interrupt" };
            _ = Printf(dl, "        endpoint 0x%02x  %s %s, %d bytes, every %d\n", .{
                @as(u32, endpoint.endpoint_address),
                @as([*:0]const u8, if (endpoint.endpoint_address & d.USB_DIR_IN != 0) "in " else "out"),
                kinds[endpoint.attributes & 3],
                @as(u32, endpoint.max_packet_size & 0x7FF),
                @as(u32, endpoint.interval),
            });
        }
        at += length;
    }
}

export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

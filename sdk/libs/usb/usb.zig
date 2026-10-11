// SPDX-License-Identifier: MIT
//! usb.library's structures and constants: a device on a bus as the
//! library keeps it, a pipe to one of its endpoints, a class driver's
//! binding, and the notification. The calls are in `sdk.interface.usb`;
//! the protocol itself - setup packets, descriptors, class codes, a
//! hub's requests - is `descriptors.zig`, here as well.
//!
//! **A bus** is a unit of a host controller device (sdk/devices/usbhc.zig).
//! StartUSB starts one: a process that owns the bus's devices, finds what
//! is plugged in, gives each an address and a configuration, and offers
//! each of its interfaces to the class drivers in `DEVS:usb/`
//! (sdk/devices/usbclass.zig). StopUSB lets go of everything on it.
//!
//! **A device** is a `USBDevice` on the library's list, which a program
//! reads between ObtainUSBDeviceList and ReleaseUSBDeviceList; the
//! library adds and removes them, and nobody else writes one. Its
//! descriptors are kept as they came, and walked with NextUSBDescriptor,
//! FindUSBInterface and FindUSBEndpoint.
//!
//! **A pipe** is an `IOUsbHC` request already filled in for one endpoint
//! (OpenUSBPipe): set io_Data and io_Length, SendIO or DoIO it, and the
//! endpoint's data toggle stays in it from one transfer to the next.

const exec = @import("../exec/exec.zig");
const usbhc = @import("../../devices/usbhc.zig");
pub const descriptors = @import("descriptors.zig");

/// The library's name, for OpenLibrary.
pub const USBNAME = "usb.library";

pub const SetupPacket = descriptors.SetupPacket;
pub const DescriptorHeader = descriptors.DescriptorHeader;
pub const DeviceDescriptor = descriptors.DeviceDescriptor;
pub const ConfigDescriptor = descriptors.ConfigDescriptor;
pub const InterfaceDescriptor = descriptors.InterfaceDescriptor;
pub const EndpointDescriptor = descriptors.EndpointDescriptor;
pub const IOUsbHC = usbhc.IOUsbHC;

/// How many interfaces of a device the library keeps a driver for.
pub const USB_MAX_INTERFACES = 8;
/// How many buses there can be.
pub const USB_MAX_BUSES = 4;

/// A device on a bus. The library's; a program reads it while it holds
/// the list (ObtainUSBDeviceList) and changes nothing in it.
pub const USBDevice = extern struct {
    /// On the library's list of devices; ln_Name its product's name, or
    /// null if it gave none.
    node: exec.Node = .{},
    /// The bus it is on, from 0.
    bus: u32 = 0,
    /// Its address on that bus, 1 to 127.
    address: u8 = 0,
    /// USB_SPEED_* (sdk/devices/usbhc.zig).
    speed: u8 = 0,
    /// The port of the hub it is plugged into, from 1; 0 for a bus's
    /// root hub.
    port: u8 = 0,
    /// How many hubs are between it and the controller: 0 for the root
    /// hub, 1 for what is plugged into the board's socket.
    depth: u8 = 0,
    /// The hub it is plugged into; null for a root hub.
    hub: ?*USBDevice = null,
    /// USBDF_*.
    flags: u32 = 0,
    /// Its device descriptor.
    descriptor: DeviceDescriptor = .{},
    pad: [2]u8 = .{ 0, 0 },
    /// The configuration it is in, its descriptors as they came; null
    /// while it has none.
    config: ?[*]const u8 = null,
    config_length: u32 = 0,
    /// Its strings, as far as Latin-1 holds them; null where it has none.
    manufacturer: ?[*:0]const u8 = null,
    product: ?[*:0]const u8 = null,
    serial: ?[*:0]const u8 = null,
    /// Who drives each of its interfaces, by bInterfaceNumber: the class
    /// driver's name or the program's (ClaimUSBInterface); null for none.
    drivers: [USB_MAX_INTERFACES]?[*:0]const u8 = @splat(null),
};

/// USBDevice.flags: it is a hub, and the library drives it.
pub const USBDF_HUB: u32 = 1 << 0;
/// It has a configuration set.
pub const USBDF_CONFIGURED: u32 = 1 << 1;
/// It did not answer as it was being set up, and is left as it is.
pub const USBDF_FAILED: u32 = 1 << 2;

/// A pipe to one endpoint (OpenUSBPipe).
pub const USBPipe = extern struct {
    /// The request, filled in for the endpoint: its command, the device's
    /// address and speed, the endpoint and its packet size, the interval,
    /// the hub, the reply port. The caller sets io_Data and io_Length -
    /// and for a control pipe the setup packet - and sends it; the data
    /// toggle stays in it.
    io: IOUsbHC = .{},
    /// The device it reaches.
    device: ?*USBDevice = null,
};

/// What a class driver is handed with USBClassBind and USBClassUnbind.
pub const USBBinding = extern struct {
    /// The device, and the interface offered (in the device's
    /// configuration, which lives as long as the binding).
    device: ?*USBDevice = null,
    interface: ?*const InterfaceDescriptor = null,
    /// The driver's, to keep what it made: the unit it filled (for a
    /// listing), and anything of its own.
    unit: u32 = 0,
    driver_data: ?*anyopaque = null,
};

/// A program told when a device comes or goes (AddUSBNotify): the
/// library's, given back with RemUSBNotify.
pub const USBNotify = opaque {};

// What StartUSB answers: 0, or one of these.
/// There is no such bus on this board.
pub const USBERR_NOBUS: i32 = -1;
/// The bus's controller could not be opened.
pub const USBERR_CONTROLLER: i32 = -2;
/// No memory, or no process could be started.
pub const USBERR_NOMEM: i32 = -3;

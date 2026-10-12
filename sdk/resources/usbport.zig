// SPDX-License-Identifier: MIT
//! usbport.resource: who holds each of the chip's USB ports - a PHY, the
//! transceiver behind a pair of USB pins - and which controller it is
//! given to. On the ESP32-S3 the one port (GPIO19 D-, GPIO20 D+) serves
//! either the USB-Serial-JTAG port - the console and the JTAG, which have
//! it as the chip starts - or the USB OTG controller; one switch chooses,
//! and the resource alone sets it. On the ESP32-P4 each controller has a
//! port of its own, and the resource only records who holds which.
//!
//! A driver that wants a port bids for it with a USBPortHandle: its
//! priority and name in the node, the task and signals it is told by,
//! and which controller the port is to be given to. OwnUSBPort answers
//! true when the port is the driver's at once. Otherwise the driver waits
//! for its signals: the holder, if it is of lower priority, is told that
//! the port is wanted (`USBPORT_WANTED`), finishes what it is doing and
//! lets go with ReleaseUSBPort; the port is then switched to the highest
//! bidder, which is told it holds it (`USBPORT_HELD`). A holder is never
//! made to let go. A driver done with the port leaves with
//! ReleaseUSBPort(USBPORTF_REMOVE), and the port goes to the next bidder,
//! or back to what the chip starts with when there is none.
//!
//! usbserial.device bids at USBPORTPRI_CONSOLE, the lowest there is: it
//! gives the port up whenever anyone else wants it, and has it back when
//! they are done.
//!
//! Get its base with OpenResource(USBPORTNAME); its functions are in
//! sdk/interface/usbport.zig.

const exec = @import("../libs/exec/exec.zig");
const hardware = @import("../hardware/hardware.zig");

/// The resource's name, for OpenResource.
pub const USBPORTNAME = "usbport.resource";

/// The chip's ports: the ESP32-S3's one; the ESP32-P4's two full-speed
/// ports and its high-speed one.
pub const USBPORT_PORTS: u32 = switch (hardware.chip) {
    .esp32s3 => 1,
    .esp32p4 => 3,
};

/// The controllers a port is given to (`USBPortHandle.controller`).
/// The USB-Serial-JTAG port: the console and the JTAG.
pub const USBCTL_SERIALJTAG: u8 = 0;
/// A USB OTG controller, `unit` its PART_BusUnit.
pub const USBCTL_OTG: u8 = 1;

/// What a bidder is to the resource (`USBPortHandle.state`), set by the
/// resource and read by the bidder when its signals come.
/// Not bidding.
pub const USBPORT_IDLE: u8 = 0;
/// Waiting for the port.
pub const USBPORT_WAITING: u8 = 1;
/// Holding it.
pub const USBPORT_HELD: u8 = 2;
/// Holding it, and a bidder of higher priority wants it: let go when
/// what is under way is done.
pub const USBPORT_WANTED: u8 = 3;

/// ReleaseUSBPort's flags.
/// Leave the bidders too; without it the caller stays one, and has the
/// port again once everyone above it is done.
pub const USBPORTF_REMOVE: u32 = 1 << 0;

/// The console's priority, usbserial.device's: below every other.
pub const USBPORTPRI_CONSOLE: i8 = -100;
/// A host controller's, usbotg.device's.
pub const USBPORTPRI_HOST: i8 = 0;

/// A bidder for a port: the caller's, filled in before OwnUSBPort and
/// left alone until ReleaseUSBPort(USBPORTF_REMOVE) has taken it back.
pub const USBPortHandle = extern struct {
    /// `pri` the bid's priority (USBPORTPRI_*); `name` who bids, which
    /// USBPortOwner answers. The resource keeps the node on its list.
    node: exec.Node = .{},
    /// Told by `signals` when it holds the port and when the port is
    /// wanted.
    task: ?*exec.Task = null,
    signals: u32 = 0,
    /// The controller the port is to be given to (USBCTL_*), and which
    /// of the chip's controllers of that kind.
    controller: u8 = USBCTL_OTG,
    unit: u8 = 0,
    /// The controller's role on the port: USBROLE_HOST or USBROLE_DEVICE
    /// (sdk.expansion.systemtags). A host's port has its pull-downs on
    /// D+ and D-; a device's has none.
    role: u8 = 0,
    /// USBPORT_*: the resource's.
    state: u8 = USBPORT_IDLE,
};

/// The resource's base, with its functions.
pub const UsbPortBase = @import("../interface/usbport.zig").UsbPortBase;

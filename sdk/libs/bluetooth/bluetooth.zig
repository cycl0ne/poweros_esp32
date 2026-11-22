// SPDX-License-Identifier: MIT
//! bluetooth.library's structures and constants: a device's address, a
//! controller as the library lists it, and the notification. The calls
//! are in `sdk.interface.bluetooth`; the HCI's commands, events and the
//! fields they carry are `hci.zig`, here as well.
//!
//! **A controller** is a unit of a device that speaks DEVIF_HCI
//! (sdk/devices/hci.zig): a USB dongle, a board's chip on a UART. Its
//! driver offers it with AddBTController once it is ready; the library's
//! task opens it and brings it up - resets it, reads what it is (its
//! address, versions, features, buffers), tells it which events to send
//! and what to call itself - and runs it from then on.
//! ObtainBTControllers lists them as they are at the moment of the call:
//! a copy, the caller's until ReleaseBTControllers.
//!
//! **A change** - a controller added, up, failed or gone - signals every
//! task that asked with AddBTNotify, which then lists them again. The
//! signal says that something changed, not what: two changes before the
//! task looks are one.

const exec = @import("../exec/exec.zig");
pub const hci = @import("hci.zig");

/// The library's name, for OpenLibrary.
pub const BLUETOOTHNAME = "bluetooth.library";

/// BTAddress.kind: what sort of address it is.
/// A BR/EDR device's: the one address it has.
pub const BTADDR_BREDR: u8 = 0;
/// An LE device's public address, its maker's.
pub const BTADDR_LE_PUBLIC: u8 = 1;
/// An LE device's random address: static, or private and changing.
pub const BTADDR_LE_RANDOM: u8 = 2;

/// A device's address.
pub const BTAddress = extern struct {
    /// The six bytes, the least significant first, as the HCI carries
    /// them; written out from the last ("00:1A:7D:DA:71:13" is
    /// `.{ 0x13, 0x71, 0xDA, 0x7D, 0x1A, 0x00 }`).
    bytes: [6]u8 = @splat(0),
    /// BTADDR_*.
    kind: u8 = BTADDR_BREDR,
    pad: u8 = 0,
};

/// BTController.state: where the controller is.
/// Its device being opened.
pub const BTCS_OPENING: u32 = 0;
/// Being brought up: reset, asked what it is, set up.
pub const BTCS_STARTING: u32 = 1;
/// Running.
pub const BTCS_UP: u32 = 2;
/// Not brought up: `failure` says why. The library leaves it so until
/// its driver removes it.
pub const BTCS_FAILED: u32 = 3;

/// A controller, as ObtainBTControllers lists it.
pub const BTController = extern struct {
    /// On the list ObtainBTControllers answers. ln_Name is the device's
    /// name, as OpenDevice takes it ("usb/bluetooth.device").
    node: exec.Node = .{},
    /// The controller's number, from 0; the same for as long as it is
    /// there, and given to the next one after it has gone.
    id: u32 = 0,
    /// The unit of the device it is.
    unit: u32 = 0,
    /// BTCS_*.
    state: u32 = BTCS_OPENING,
    /// Why it failed: BTERR_*, or the status (hci.HCI_ERR_*) the
    /// controller answered the command that did not work; 0 for a
    /// controller that has not failed.
    failure: i32 = 0,
    /// Its own address, BTADDR_BREDR; zeros until it is read.
    address: BTAddress = .{},
    /// The HCI's version (hci.BT_VERSION_*) and revision, the link
    /// manager's version and subversion, and its maker, by the company
    /// identifier the Bluetooth SIG gave it.
    hci_version: u8 = 0,
    lmp_version: u8 = 0,
    hci_revision: u16 = 0,
    lmp_subversion: u16 = 0,
    manufacturer: u16 = 0,
    /// The class of device it shows, 24 bits (hci.COD_*).
    class_of_device: u32 = 0,
    /// The name it shows others, UTF-8; empty until it is set.
    name: [*:0]const u8 = "",
    /// How it is reached (HCIBUS_*) and, on a UART, the line's rate in
    /// bits a second; the device's word for its chip and firmware
    /// (sdk/devices/hci.zig's HCIInfo), null for none.
    bus: u32 = 0,
    baud: u32 = 0,
    chip: ?[*:0]const u8 = null,
    firmware: ?[*:0]const u8 = null,
    /// Its buffers for data sent to it: how long a BR/EDR ACL packet may
    /// be and how many it holds; LE's, which are BR/EDR's for a
    /// controller with none of their own; SCO's.
    acl_mtu: u16 = 0,
    acl_packets: u16 = 0,
    le_mtu: u16 = 0,
    le_packets: u16 = 0,
    sco_mtu: u16 = 0,
    sco_packets: u16 = 0,
    /// Its link manager's features, pages 0 to 2 (hci.LMP_*), and its LE
    /// features (hci.LE_FEATURE_*), as it answered them; zeros for a page
    /// it does not have. Feature `n` of a page is bit `n % 8` of byte
    /// `n / 8`.
    features: [3][8]u8 = @splat(@splat(0)),
    le_features: [8]u8 = @splat(0),
    /// The commands it takes, as it answered Read Local Supported
    /// Commands: the command at `n` (hci.CMDBIT_*) is bit `n % 8` of byte
    /// `n / 8`.
    commands: [64]u8 = @splat(0),
};

/// A task told when the controllers change (AddBTNotify): the library's,
/// given back with RemBTNotify.
pub const BTNotify = opaque {};

// What the calls answer, and BTController.failure: 0, or one of these.
// A positive failure is the controller's own status (hci.HCI_ERR_*).
/// No memory, or the library's task could not be started.
pub const BTERR_NOMEM: i32 = -1;
/// The controller's device would not open.
pub const BTERR_OPENFAIL: i32 = -2;
/// The controller did not answer a command in time.
pub const BTERR_TIMEOUT: i32 = -3;
/// The controller went away.
pub const BTERR_DETACHED: i32 = -4;
/// The controller answered something that cannot be.
pub const BTERR_PROTOCOL: i32 = -5;

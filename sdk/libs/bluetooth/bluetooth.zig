// SPDX-License-Identifier: MIT
//! bluetooth.library's structures and constants: a device's address, a
//! controller as the library lists it and the tags that set it, a device
//! a controller found, a connection, and the notification. The calls are
//! in `sdk.interface.bluetooth`; the HCI's commands, events and the
//! fields they carry are `hci.zig`, L2CAP's `l2cap.zig`, here as well.
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
//! **Its settings** - on or off, its name, whether others find it - are
//! set with SetBTControllerAttrs's tags (BTCA_*). On, its name, and
//! being found until told otherwise are kept for the controller's next
//! start, by its address (`ENVARC:Sys/bluetooth/<address>/`); being found
//! for a time ends at that time, and at a start.
//!
//! **The devices around** are found by StartBTDiscovery - LE's
//! advertising listened to, then an inquiry, then the names not yet heard
//! asked for - and listed by ObtainBTDevices: a copy, as the controllers'
//! list is.
//!
//! **A connection** to a device is made with ConnectBTDevice - a page
//! over BR/EDR, LE's initiating to an advertiser - and ended with
//! DisconnectBTDevice; a device that pages a controller is taken on as
//! well. ObtainBTConnections lists them.
//!
//! **A change** - a controller added, up, failed or gone, a setting, a
//! device found or named, a discovery ended, a connection made or
//! ended - signals every task that
//! asked with AddBTNotify, which then lists again. The signal says that
//! something changed, not what: two changes before the task looks are
//! one.

const exec = @import("../exec/exec.zig");
const utility = @import("../utility/utility.zig");
pub const hci = @import("hci.zig");
pub const l2cap = @import("l2cap.zig");

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

/// BTController.flags: what it does now.
/// On: it answers others as its settings say, and may look for devices.
/// Off, its radio is silent.
pub const BTCF_POWERED: u32 = 1 << 0;
/// Found by others who look (it answers inquiries).
pub const BTCF_VISIBLE: u32 = 1 << 1;
/// Taking connections (it answers pages): on whenever it is.
pub const BTCF_CONNECTABLE: u32 = 1 << 2;
/// Looking for devices (StartBTDiscovery).
pub const BTCF_DISCOVERING: u32 = 1 << 3;

/// BTCA_Visible's and BTController.visible_left's "until told otherwise".
pub const BT_VISIBLE_ALWAYS: u32 = 0xFFFF_FFFF;
/// The calls' controller, where they take one: every controller.
pub const BT_ALL_CONTROLLERS: u32 = 0xFFFF_FFFF;

/// SetBTControllerAttrs's tags.
pub const BTCA_Dummy = utility.TAG_USER + 0x61400;
/// Bool: the controller on, or off.
pub const BTCA_Powered = BTCA_Dummy + 1;
/// [*:0]const u8: the name it shows others, UTF-8, up to 247 bytes; an
/// empty one gives it the machine's again.
pub const BTCA_Name = BTCA_Dummy + 2;
/// u32: found by others for that many seconds, 0 for not at all,
/// BT_VISIBLE_ALWAYS until told otherwise.
pub const BTCA_Visible = BTCA_Dummy + 3;

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
    /// BTCF_*; and how many seconds more it is found by others,
    /// BT_VISIBLE_ALWAYS for no end, 0 while it is not.
    flags: u32 = 0,
    visible_left: u32 = 0,
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

/// BTDevice.flags: how it was heard.
/// It answered an inquiry: a BR/EDR device.
pub const BTDF_BREDR: u32 = 1 << 0;
/// It was heard advertising: an LE device.
pub const BTDF_LE: u32 = 1 << 1;
/// Its advertising takes connections.
pub const BTDF_CONNECTABLE: u32 = 1 << 2;
/// Its name is a shortened one: all of it it has said.
pub const BTDF_SHORT_NAME: u32 = 1 << 3;
/// Its name was asked for and not answered.
pub const BTDF_NO_NAME: u32 = 1 << 4;

/// BTDevice's fields for what it did not say.
pub const BT_RSSI_NONE: i8 = 127;
pub const BT_TX_POWER_NONE: i8 = 127;
pub const BT_COMPANY_NONE: u16 = 0xFFFF;

/// A device a controller found, as ObtainBTDevices lists it.
pub const BTDevice = extern struct {
    /// On the list ObtainBTDevices answers. ln_Name is the device's name,
    /// UTF-8, empty while it has not said one.
    node: exec.Node = .{},
    /// The controller that heard it (BTController.id).
    controller: u32 = 0,
    /// BTDF_*.
    flags: u32 = 0,
    /// Its address: BTADDR_BREDR for a device that answered an inquiry -
    /// also when it advertises from the same address - otherwise its LE
    /// address, public or random.
    address: BTAddress = .{},
    /// Its class of device (hci.COD_*), 0 where it said none.
    class_of_device: u32 = 0,
    /// How long ago it was last heard, in milliseconds.
    age: u32 = 0,
    /// The signal it was last heard with and the power it says it sends
    /// at, both in dBm; BT_RSSI_NONE and BT_TX_POWER_NONE for none.
    rssi: i8 = BT_RSSI_NONE,
    tx_power: i8 = BT_TX_POWER_NONE,
    /// LE: its advertising's flags (hci.AD_FLAG_*).
    ad_flags: u8 = 0,
    /// How many of `uuid16` and `uuid128` it said.
    uuid16_count: u8 = 0,
    /// LE: what it is, as GATT's appearance values have it; 0 for none.
    appearance: u16 = 0,
    /// The maker its own data names, by the company identifier the
    /// Bluetooth SIG gave it; BT_COMPANY_NONE for none.
    company: u16 = BT_COMPANY_NONE,
    /// The services it says it has: up to eight 16-bit UUIDs and two
    /// 128-bit ones, the least significant byte first - a 32-bit one is
    /// kept as the 128-bit UUID it stands for.
    uuid16: [8]u16 = @splat(0),
    uuid128_count: u8 = 0,
    pad: [7]u8 = @splat(0),
    uuid128: [2][16]u8 = @splat(@splat(0)),
};

/// BTConnection.flags: what sort of link it is.
/// Over LE; otherwise over BR/EDR.
pub const BTLF_LE: u32 = 1 << 0;
/// The device made it: it paged the controller, or initiated to it.
pub const BTLF_INCOMING: u32 = 1 << 1;
/// The controller is the link's central - it paged or initiated, or took
/// the role over; otherwise its peripheral.
pub const BTLF_CENTRAL: u32 = 1 << 2;
/// Encrypted.
pub const BTLF_ENCRYPTED: u32 = 1 << 3;

/// A connection, as ObtainBTConnections lists it.
pub const BTConnection = extern struct {
    /// On the list ObtainBTConnections answers. ln_Name is the device's
    /// name, UTF-8, empty while it is not known.
    node: exec.Node = .{},
    /// The controller it is a link of (BTController.id).
    controller: u32 = 0,
    /// BTLF_*.
    flags: u32 = 0,
    /// The device's address: BTADDR_BREDR over BR/EDR, its LE address -
    /// public or random - over LE.
    address: BTAddress = .{},
    /// The controller's number for the link.
    handle: u16 = 0,
    /// LE: the link's interval (units of 1.25 ms), how many of its events
    /// the peripheral may let pass (its latency), and how long the link
    /// lasts unheard (units of 10 ms); 0 over BR/EDR.
    interval: u16 = 0,
    latency: u16 = 0,
    supervision: u16 = 0,
    /// How long it has been up, in milliseconds.
    age: u32 = 0,
    /// The device's class of device (hci.COD_*), as its page or the
    /// discovery gave it; 0 where none is known.
    class_of_device: u32 = 0,
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
/// There is no controller with that number.
pub const BTERR_NOCONTROLLER: i32 = -6;
/// The controller is not up: being brought up, or failed.
pub const BTERR_NOTUP: i32 = -7;
/// The controller is off (BTCA_Powered).
pub const BTERR_OFF: i32 = -8;
/// The controller cannot do it: it has neither BR/EDR nor LE's
/// scanning, or does not take the commands it needs.
pub const BTERR_UNSUPPORTED: i32 = -9;
/// There is no connection to the device.
pub const BTERR_NOTCONNECTED: i32 = -10;
/// The controller is making a connection of that kind already - it pages
/// one device at a time and initiates to one - or is ending this one.
pub const BTERR_BUSY: i32 = -11;

// SPDX-License-Identifier: MIT
//! bluetooth.library's structures and constants: a device's address, a
//! controller as the library lists it and the tags that set it, a device
//! a controller found, a connection, an agent and what it is asked, a
//! bond, a channel and what its owner is told, a service, the attribute
//! protocol to a device and its characteristics, and the notification.
//! The calls are in `sdk.interface.bluetooth`; the HCI's commands, events
//! and the fields they carry are `hci.zig`, L2CAP's `l2cap.zig`, SDP's
//! `sdp.zig`, the attribute protocol's and GATT's `att.zig`, HID over
//! BR/EDR's `hidp.zig`, sound's - A2DP's and AVDTP's - `avdtp.zig`, and
//! a device's controls - AVRCP's and AVCTP's - `avrcp.zig`, here as well.
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
//! **Pairing** makes a bond with a device, over BR/EDR or LE: keys the
//! two keep, which authenticate and encrypt their links from then on.
//! PairBTDevice begins one and returns; what the pairing needs to know -
//! whether a number matches, a passkey, a PIN - and its end are messages
//! to the agent it names (AddBTAgent: a port, and what its user can do).
//! The agent added last also answers the pairings a device begins. The
//! bonds are kept by the controller's address and the device's
//! (`ENVARC:Sys/bluetooth/<controller>/<device>`); ObtainBTBonds lists
//! them, UnpairBTDevice ends one.
//!
//! **A channel** reaches one protocol of a device over a BR/EDR link, by
//! its PSM: OpenBTChannel opens one, and a device opens one to a
//! listener's PSM (AddBTListener). Its frames come as messages to its
//! port; SendBTChannel sends them; CloseBTChannel ends it.
//!
//! **A device's services** are listed by ObtainBTServices: over BR/EDR
//! its SDP records, read over a channel to its PSM 1; over LE its GATT
//! server's services. NextBTDataElement and FindBTServiceAttribute read
//! what a record holds. The library answers SDP itself, with a record of
//! its own and those its programs add (AddBTService).
//!
//! **GATT** is how an LE device offers its data: its attributes, grouped
//! into services, each a set of characteristics - a value, what may be
//! done with it, its descriptors. OpenBTGatt opens the attribute protocol
//! to a device; ObtainBTCharacteristics lists a service's
//! characteristics; ReadBTAttribute and WriteBTAttribute read and write
//! a value; SubscribeBTAttribute has the device send a value as it
//! changes, as messages to the block's port. A block opened with
//! BTGO_WAIT waits for its device instead: the library listens for its
//! advertising and makes the link whenever it is heard, and the block
//! opens each time the link is up. The library serves GATT itself, with
//! the machine's name.
//!
//! **A change** - a controller added, up, failed or gone, a setting, a
//! device found or named, a discovery ended, a connection made or
//! ended, a bond made or ended - signals every task that
//! asked with AddBTNotify, which then lists again. The signal says that
//! something changed, not what: two changes before the task looks are
//! one.

const exec = @import("../exec/exec.zig");
const utility = @import("../utility/utility.zig");
pub const hci = @import("hci.zig");
pub const l2cap = @import("l2cap.zig");
pub const sdp = @import("sdp.zig");
pub const att = @import("att.zig");
pub const hidp = @import("hidp.zig");
pub const avdtp = @import("avdtp.zig");
pub const avrcp = @import("avrcp.zig");

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

/// BTDeviceKind's answer: what a device is, by its class of device or
/// its LE appearance, for a program to name in its own words; BTDK_LAST
/// is the highest there is.
pub const BTDK_NONE: u32 = 0;
pub const BTDK_COMPUTER: u32 = 1;
pub const BTDK_LAPTOP: u32 = 2;
pub const BTDK_HANDHELD: u32 = 3;
pub const BTDK_PHONE: u32 = 4;
pub const BTDK_ACCESS_POINT: u32 = 5;
pub const BTDK_HEADSET: u32 = 6;
pub const BTDK_HANDS_FREE: u32 = 7;
pub const BTDK_MICROPHONE: u32 = 8;
pub const BTDK_LOUDSPEAKER: u32 = 9;
pub const BTDK_HEADPHONES: u32 = 10;
pub const BTDK_PORTABLE_AUDIO: u32 = 11;
pub const BTDK_CAR_AUDIO: u32 = 12;
pub const BTDK_HIFI: u32 = 13;
pub const BTDK_DISPLAY: u32 = 14;
pub const BTDK_GAME_CONSOLE: u32 = 15;
/// Audio or video that says no more.
pub const BTDK_AUDIO_VIDEO: u32 = 16;
pub const BTDK_KEYBOARD: u32 = 17;
pub const BTDK_MOUSE: u32 = 18;
pub const BTDK_KEYBOARD_MOUSE: u32 = 19;
pub const BTDK_JOYSTICK: u32 = 20;
pub const BTDK_GAMEPAD: u32 = 21;
pub const BTDK_REMOTE: u32 = 22;
pub const BTDK_TABLET: u32 = 23;
/// An input device that says no more.
pub const BTDK_PERIPHERAL: u32 = 24;
/// A printer, a scanner or a camera.
pub const BTDK_IMAGING: u32 = 25;
pub const BTDK_WEARABLE: u32 = 26;
pub const BTDK_TOY: u32 = 27;
pub const BTDK_HEALTH: u32 = 28;
pub const BTDK_EARBUDS: u32 = 29;
pub const BTDK_WATCH: u32 = 30;
pub const BTDK_CLOCK: u32 = 31;
pub const BTDK_TAG: u32 = 32;
pub const BTDK_KEYRING: u32 = 33;
pub const BTDK_MEDIA_PLAYER: u32 = 34;
pub const BTDK_THERMOMETER: u32 = 35;
pub const BTDK_HEART_RATE: u32 = 36;
pub const BTDK_SENSOR: u32 = 37;
pub const BTDK_LIGHT: u32 = 38;
pub const BTDK_AUDIO_SOURCE: u32 = 39;
pub const BTDK_HEARING_AID: u32 = 40;
pub const BTDK_LAST: u32 = BTDK_HEARING_AID;

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
/// Authenticated: the two have shown each other the link key of their
/// bond, or of a pairing on this link.
pub const BTLF_AUTHENTICATED: u32 = 1 << 4;
/// To a device the controller has a bond with.
pub const BTLF_BONDED: u32 = 1 << 5;
/// Being paired, or being authenticated and encrypted.
pub const BTLF_PAIRING: u32 = 1 << 6;

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

// --- pairing -----------------------------------------------------------------

/// AddBTAgent's capability: what the agent's user can do, which decides
/// how a pairing is confirmed.
/// Show a number, but answer nothing.
pub const BTIO_DISPLAYONLY: u32 = 0;
/// Show a number and answer yes or no.
pub const BTIO_DISPLAYYESNO: u32 = 1;
/// Type a number, but show nothing.
pub const BTIO_KEYBOARDONLY: u32 = 2;
/// Nothing: a pairing is confirmed by nobody (Just Works).
pub const BTIO_NOINPUTNOOUTPUT: u32 = 3;
/// Show a number, answer yes or no, and type one.
pub const BTIO_KEYBOARDDISPLAY: u32 = 4;

/// An agent added with AddBTAgent: the library's, given back with
/// RemBTAgent.
pub const BTAgent = opaque {};

/// BTAgentMessage.kind: what the agent is asked or told.
/// Whether the device shows `number`; BT_NO_NUMBER when there is none
/// to compare - whether the device may pair at all.
pub const BTAK_CONFIRM: u32 = 1;
/// The passkey the device shows, typed into `passkey`.
pub const BTAK_PASSKEY: u32 = 2;
/// `number`, to be typed on the device: answered at once.
pub const BTAK_SHOW: u32 = 3;
/// The PIN for a device without Secure Simple Pairing, into `pin`.
pub const BTAK_PIN: u32 = 4;
/// The pairing is over: `result` says how. Answered at once.
pub const BTAK_DONE: u32 = 5;

/// BTAgentMessage.number when there is no number.
pub const BT_NO_NUMBER: u32 = 0xFFFF_FFFF;
/// The longest PIN.
pub const BT_PIN_MOST = 16;
/// The most of a device's name a message or a bond carries, its NUL
/// besides.
pub const BT_BOND_NAME_MOST = 127;
/// The most of BTBond.drivers, its NUL besides.
pub const BT_BOND_DRIVERS_MOST = 95;

/// What the library asks an agent, or tells it: sent to the agent's port,
/// and replied by the agent once it has answered. The library makes it
/// and frees it once it is back.
pub const BTAgentMessage = extern struct {
    message: exec.Message = .{},
    /// BTAK_*.
    kind: u32 = 0,
    /// The controller (BTController.id) and the device.
    controller: u32 = 0,
    address: BTAddress = .{},
    /// BTAK_CONFIRM's number to compare, BTAK_SHOW's passkey: six
    /// decimal digits, leading zeros shown; BT_NO_NUMBER for none.
    number: u32 = BT_NO_NUMBER,
    /// BTAK_DONE: 0 for a bond made, else why not - BTERR_*, or the
    /// controller's status (hci.HCI_ERR_*).
    result: i32 = 0,
    /// Whether this machine began the pairing (PairBTDevice); otherwise
    /// the device did.
    ours: u32 = 0,
    /// The agent's answer: whether it agrees (BTAK_CONFIRM, BTAK_PASSKEY,
    /// BTAK_PIN), the passkey typed, and the PIN with its length.
    accept: u32 = 0,
    passkey: u32 = 0,
    pin_length: u32 = 0,
    pin: [BT_PIN_MOST]u8 = @splat(0),
    /// The device's name, UTF-8, ended by a NUL; empty when it is not
    /// known.
    name: [BT_BOND_NAME_MOST + 1]u8 = @splat(0),
};

/// BTBond.flags: what sort of bond it is.
/// Its pairing was confirmed - a number compared, a passkey typed, or a
/// PIN given - so that nobody between the two could have made it.
pub const BTBF_AUTHENTICATED: u32 = 1 << 0;
/// Made with Secure Connections (P-256); otherwise with P-192, or a PIN.
pub const BTBF_SECURE: u32 = 1 << 1;
/// Made with a PIN, by a device without Secure Simple Pairing.
pub const BTBF_LEGACY: u32 = 1 << 2;
/// An LE bond that keeps the device's identity resolving key: the
/// private addresses it makes are known as its own.
pub const BTBF_IDENTITY: u32 = 1 << 3;

/// A bond, as ObtainBTBonds lists it.
pub const BTBond = extern struct {
    /// On the list ObtainBTBonds answers. ln_Name is the device's name as
    /// it was at the pairing, UTF-8; empty when none was known.
    node: exec.Node = .{},
    /// The controller it is a bond of (BTController.id).
    controller: u32 = 0,
    /// BTBF_*.
    flags: u32 = 0,
    address: BTAddress = .{},
    /// The device's class of device, as it was at the pairing; 0 when it
    /// was not known.
    class_of_device: u32 = 0,
    /// The kind of its link key (hci.LINK_KEY_*); 0 for an LE bond.
    key_type: u32 = 0,
    /// The size of its key in bytes: 16 for a link key, an LE key's as
    /// its pairing agreed, from 7 to 16.
    key_size: u32 = 0,
    /// The profile drivers its device's services are bound to, by their
    /// files' names, a comma and a space between two ("bthid.device");
    /// empty for none. Since bluetooth.library 1.9.
    drivers: ?[*:0]const u8 = null,
};

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
/// one device at a time and initiates to one - or is ending this one; or
/// the device is being paired.
pub const BTERR_BUSY: i32 = -11;
/// The controller has a bond with the device already: UnpairBTDevice
/// ends it first.
pub const BTERR_BONDED: i32 = -12;
/// The controller has no bond with the device.
pub const BTERR_NOTBONDED: i32 = -13;
/// The agent said no, or no agent answered in time; or the device
/// refused a channel.
pub const BTERR_REFUSED: i32 = -14;
/// A frame longer than the channel's other end takes; a value longer
/// than the attribute protocol carries.
pub const BTERR_TOOLONG: i32 = -15;
/// The device refused a request of the attribute protocol: its reason
/// (att.ATT_ERR_*) is BTERR_ATT - result - BTERR_ATT - 0x02 a value that
/// may not be read, BTERR_ATT - 0x0F one that needs the link encrypted.
pub const BTERR_ATT: i32 = -256;

// --- channels ----------------------------------------------------------------

/// BTChannel.flags.
/// A device opened it, to a listener's PSM; otherwise OpenBTChannel or
/// StartBTChannel did.
pub const BTCHF_INCOMING: u32 = 1 << 0;
/// It is closed - by the device, or with its link: frames neither come
/// nor go, and CloseBTChannel gives it back.
pub const BTCHF_CLOSED: u32 = 1 << 1;

/// A channel to one protocol of a device - L2CAP's, over a BR/EDR link -
/// as OpenBTChannel, StartBTChannel or a listener's BTCM_OPENED hands it
/// over: its owner's until CloseBTChannel, which frees it. The library keeps its
/// fields up to date; the owner reads them.
pub const BTChannel = extern struct {
    /// The controller (BTController.id) and the device.
    controller: u32 = 0,
    address: BTAddress = .{},
    /// The protocol it reaches, by its PSM (l2cap.PSM_*).
    psm: u16 = 0,
    /// The identifiers of its two ends: this machine's and the device's.
    local_cid: u16 = 0,
    remote_cid: u16 = 0,
    /// The longest frame each end takes: the device's - the most
    /// SendBTChannel sends - and this machine's.
    mtu_out: u16 = 0,
    mtu_in: u16 = 0,
    pad: u16 = 0,
    /// BTCHF_*.
    flags: u32 = 0,
    /// Frames let go because 32 of the channel's messages were out
    /// unreplied.
    dropped: u32 = 0,
    /// Where its messages go.
    port: ?*exec.MsgPort = null,
};

/// BTChannelMessage.kind: what the owner, or a listener, is told.
/// A frame of the channel: `data`, `length` bytes, the library's until
/// the message is replied.
pub const BTCM_DATA: u32 = 1;
/// A device opened `channel` to the listener's PSM: the receiver's from
/// now on, to close with CloseBTChannel. Its frames come to the same
/// port. Or the channel StartBTChannel began is open: its frames come
/// from now on.
pub const BTCM_OPENED: u32 = 2;
/// `channel` is closed - by the device, `result` 0, or with its link or
/// its controller, `result` the link's reason or BTERR_DETACHED - and
/// carries nothing more. One StartBTChannel began that ended before it
/// was open says why, never 0: what OpenBTChannel would have answered.
pub const BTCM_CLOSED: u32 = 3;

/// What the library tells a channel's owner, or a listener: sent to the
/// port, and replied by the receiver once read. The library makes it and
/// frees it once it is back.
pub const BTChannelMessage = extern struct {
    message: exec.Message = .{},
    /// BTCM_*.
    kind: u32 = 0,
    /// BTCM_CLOSED: why - 0, BTERR_*, or the link's reason
    /// (hci.HCI_ERR_*).
    result: i32 = 0,
    /// The channel it is about. CloseBTChannel takes back the messages
    /// about the channel still on the port; one taken before it is
    /// replied without reading this.
    channel: ?*BTChannel = null,
    /// BTCM_DATA: the frame.
    data: ?[*]const u8 = null,
    length: u32 = 0,
};

/// A listener added with AddBTListener: the library's, given back with
/// RemBTListener.
pub const BTListener = opaque {};

/// AddBTListener's flags.
/// A channel taken only over a link encrypted after the two have shown
/// each other the key of their bond: a device without a bond is refused,
/// and one whose link is not so yet waits while it is made so.
pub const BTLSF_SECURE: u32 = 1 << 0;

// --- services ----------------------------------------------------------------

/// A UUID, big-endian, as it is written: 0000110A-0000-1000-8000-
/// 00805F9B34FB is `.{ 0x00, 0x00, 0x11, 0x0A, 0x00, 0x00, 0x10, ... }`.
/// One of 16 or 32 bits stands for the base UUID (sdp.BASE_UUID) with
/// its value in the first four bytes.
pub const BTUUID = extern struct {
    bytes: [16]u8 = @splat(0),
};

/// BTService.flags: how it was found.
/// Its SDP record, read over BR/EDR.
pub const BTSF_SDP: u32 = 1 << 0;
/// A service of the device's GATT server, over LE: its attributes from
/// `handle` to `end_handle`.
pub const BTSF_GATT: u32 = 1 << 1;

/// A service of a device, as ObtainBTServices lists it.
pub const BTService = extern struct {
    /// On the list ObtainBTServices answers. ln_Name is the service's
    /// name as its record gives it, UTF-8; empty where it gives none, as
    /// for every GATT service.
    node: exec.Node = .{},
    /// The controller it was read over (BTController.id), and the
    /// device.
    controller: u32 = 0,
    address: BTAddress = .{},
    /// BTSF_*.
    flags: u32 = 0,
    /// What it is: the first class its record names
    /// (ATTR_SERVICE_CLASS_ID_LIST), or the GATT service's UUID - and as
    /// 16 bits where it is one of those, 0 where not.
    class: BTUUID = .{},
    class16: u16 = 0,
    /// The L2CAP PSM it is reached on, 0 where its record names none - and
    /// for a GATT service, reached over the attribute protocol's channel.
    psm: u16 = 0,
    /// The RFCOMM channel it is over that PSM, 0 for none.
    rfcomm_channel: u8 = 0,
    pad: u8 = 0,
    /// The profile it is (its record's first in
    /// ATTR_PROFILE_DESCRIPTOR_LIST): its UUID of 16 bits - 0 where it
    /// names none - and its version, the major one in the upper byte.
    profile16: u16 = 0,
    profile_version: u16 = 0,
    pad2: u16 = 0,
    /// Its record's handle on the device; for a GATT service the handle
    /// of its declaration, the first of its attributes, and of its last.
    handle: u32 = 0,
    end_handle: u32 = 0,
    /// Its record as the device sent it: the data element sequence of its
    /// attribute ids and their values (sdp.zig), where a profile reads
    /// attributes of its own. The list's, freed with it.
    record: ?[*]const u8 = null,
    record_length: u32 = 0,
};

/// A data element of a record (sdp.zig), as NextBTDataElement and
/// FindBTServiceAttribute read it.
pub const BTDataElement = extern struct {
    /// Its type: sdp.DE_*.
    kind: u32 = 0,
    /// How many bytes it takes where it was read, its descriptor and its
    /// length on: how far on the next element begins.
    whole: u32 = 0,
    /// Its data, past its descriptor and its length: an integer's bytes,
    /// big-endian; a text's or a URL's, with no end of its own; a
    /// sequence's or an alternative's elements, for NextBTDataElement to
    /// read in turn. Within the bytes it was read from.
    data: ?[*]const u8 = null,
    length: u32 = 0,
    pad: u32 = 0,
    /// An unsigned integer's or a boolean's value, a signed integer's with
    /// its sign kept (`@bitCast` to `i64`), for one of up to 8 bytes; 0
    /// for another element.
    value: u64 align(4) = 0,
    /// A UUID's value as 128 bits, one of 16 or 32 on the base UUID;
    /// zeros for another element.
    uuid: BTUUID = .{},
};

/// A record of a program's own, which the library's SDP server answers
/// with (AddBTService): the library's, given back with RemBTService.
pub const BTRecord = opaque {};

// --- profiles ----------------------------------------------------------------

/// A service of a device offered to a profile driver
/// (sdk/devices/btprofile.zig), and kept by the driver that takes it: the
/// library makes it, the driver fills in its part.
pub const BTBinding = extern struct {
    /// The controller (BTController.id) and the device.
    controller: u32 = 0,
    address: BTAddress = .{},
    /// The service, as ObtainBTServices lists it - a BR/EDR one with its
    /// record: the library's, for as long as the binding lasts.
    service: ?*const BTService = null,
    /// The driver's: which of its units drives the service, and what it
    /// keeps of it.
    unit: u32 = 0,
    pad: u32 = 0,
    driver_data: ?*anyopaque = null,
};

/// BTProfileUnbind's flags.
/// The bond with the device is ending (UnpairBTDevice): the driver tells
/// the device to forget it too, where its profile has a way.
pub const BTPU_FORGET: u32 = 1 << 0;

// --- GATT --------------------------------------------------------------------

/// OpenBTGatt's flags.
/// The block waits for its device rather than for its link: OpenBTGatt
/// answers at once, and the block opens whenever the device is reached -
/// a link made each time it advertises, while the block waits - and
/// waits again once the link ends, until CloseBTGatt.
pub const BTGO_WAIT: u32 = 1 << 0;

/// BTGatt.flags.
/// Its link is down, or the device stopped answering: nothing more is
/// asked or comes, and CloseBTGatt gives it back.
pub const BTGF_CLOSED: u32 = 1 << 0;
/// A block opened with BTGO_WAIT that waits for its device now: its calls
/// answer BTERR_NOTCONNECTED until it opens again (BTGM_OPENED).
pub const BTGF_WAITING: u32 = 1 << 1;

/// The attribute protocol to an LE device - GATT's client - as OpenBTGatt
/// hands it over: its owner's until CloseBTGatt, which frees it. The
/// library keeps its fields up to date; the owner reads them.
pub const BTGatt = extern struct {
    /// The controller (BTController.id) and the device.
    controller: u32 = 0,
    address: BTAddress = .{},
    /// The most a PDU carries over the link, as the two sides agreed when
    /// the block was opened (att.ATT_MTU_DEFAULT where they did not): a
    /// value written goes up to mtu - 3 bytes. A waiting block's is its
    /// last link's, 0 before its first.
    mtu: u16 = 0,
    pad: u16 = 0,
    /// BTGF_*.
    flags: u32 = 0,
    /// Values let go because 32 of its messages were out unreplied.
    dropped: u32 = 0,
    /// Where its messages go.
    port: ?*exec.MsgPort = null,
};

/// A characteristic's descriptor: what it is, and where.
pub const BTDescriptor = extern struct {
    /// Its type, and as 16 bits where it is one of those (att.GATT_*), 0
    /// where not.
    uuid: BTUUID = .{},
    uuid16: u16 = 0,
    handle: u16 = 0,
};

/// A characteristic of a GATT service, as ObtainBTCharacteristics lists
/// it.
pub const BTCharacteristic = extern struct {
    /// On the list ObtainBTCharacteristics answers; ln_Name empty.
    node: exec.Node = .{},
    /// What it is, and as 16 bits where it is one of those, 0 where not.
    uuid: BTUUID = .{},
    uuid16: u16 = 0,
    /// What a client may do with its value: att.GATT_PROP_*.
    properties: u16 = 0,
    /// Its declaration's handle; its value's, which ReadBTAttribute and
    /// WriteBTAttribute take; its last, its descriptors between the two.
    handle: u16 = 0,
    value_handle: u16 = 0,
    end_handle: u16 = 0,
    /// Its Client Characteristic Configuration's handle, which
    /// SubscribeBTAttribute writes; 0 where it has none.
    configuration_handle: u16 = 0,
    /// Its descriptors, `descriptor_count` of them, in handle order: the
    /// list's, freed with it.
    descriptors: ?[*]const BTDescriptor = null,
    descriptor_count: u32 = 0,
    pad: u32 = 0,
};

/// WriteBTAttribute's flags.
/// A Write Command: the value sent, the device not asked to answer.
pub const BTGW_NORESPONSE: u32 = 1 << 0;

/// SubscribeBTAttribute's flags.
/// The value indicated - each confirmed to the device - rather than
/// notified.
pub const BTGS_INDICATE: u32 = 1 << 0;

/// BTGattMessage.kind: what a block's owner is told.
/// A value the device sent of the attribute `handle` - notified or
/// indicated, as subscribed: `data`, `length` bytes, the library's until
/// the message is replied.
pub const BTGM_VALUE: u32 = 1;
/// The block is closed - its link down, `result` the link's reason;
/// BTERR_DETACHED with its controller; BTERR_TIMEOUT for a device that
/// stopped answering - and carries nothing more.
pub const BTGM_CLOSED: u32 = 2;
/// A waiting block (BTGO_WAIT) is open: its link is up - made secure with
/// the bond's key where there is one - and its calls go to the device.
pub const BTGM_OPENED: u32 = 3;
/// A waiting block's link ended - `result` why, as BTGM_CLOSED's - and the
/// block waits for its device again; what it subscribed to stays.
pub const BTGM_WAITING: u32 = 4;

/// What the library tells a block's owner: sent to the block's port, and
/// replied by the receiver once read. The library makes it and frees it
/// once it is back.
pub const BTGattMessage = extern struct {
    message: exec.Message = .{},
    /// BTGM_*.
    kind: u32 = 0,
    /// BTGM_CLOSED: why - BTERR_*, or the link's reason (hci.HCI_ERR_*).
    result: i32 = 0,
    /// The block it is about. CloseBTGatt takes back the messages about
    /// the block still on the port; one taken before it is replied
    /// without reading this.
    gatt: ?*BTGatt = null,
    /// BTGM_VALUE: the attribute - a characteristic's value_handle - and
    /// its value.
    handle: u32 = 0,
    length: u32 = 0,
    data: ?[*]const u8 = null,
};

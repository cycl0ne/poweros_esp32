// SPDX-License-Identifier: MIT
//! HID over BR/EDR, and over GATT: the Human Interface Device profile's
//! numbers - its service's class, the attributes its record has, and the
//! transactions on its two channels, control and interrupt
//! (l2cap.PSM_HID_CONTROL, l2cap.PSM_HID_INTERRUPT); over LE the GATT
//! service's characteristics. The reports themselves are laid out as a
//! device's report descriptor says, as over USB (sdk.hid).
//!
//! **A frame** on either channel begins with a byte: the transaction's
//! type in its upper four bits (HIDP_*), a parameter in its lower four.
//! A report is DATA with its kind as the parameter, then the report's ID
//! where the device's reports have IDs, then its bytes: an input report
//! comes on the interrupt channel, and an output report goes there. A
//! request on the control channel - SET_PROTOCOL, GET_REPORT, SET_REPORT -
//! is answered there, by a HANDSHAKE or by DATA; HID_CONTROL is not
//! answered.
//!
//! **The record** names the control channel's PSM in its protocol
//! descriptor list and the interrupt channel's in its additional ones,
//! each after L2CAP with HIDP; its descriptor list holds the report
//! descriptor.
//!
//! **Over GATT** the service (UUID_HID_SERVICE) holds the report
//! descriptor as its Report Map, read in parts, and each report as a
//! Report characteristic, whose Report Reference descriptor
//! (att.GATT_REPORT_REFERENCE) says which: its ID, then its kind
//! (HIDP_REPORT_*). An input report is notified, an output report
//! written - neither with its ID. Each link begins in the report
//! protocol, and the Protocol Mode characteristic says which is used
//! (HIDP_PROTOCOL_*, written as a Write Command).

/// The service's class (BTService.class16), and the protocol its record
/// names after L2CAP.
pub const UUID_HID: u16 = 0x1124;
pub const UUID_HIDP: u16 = 0x0011;

/// The attributes of a HID service's record.
pub const ATTR_HID_PARSER_VERSION: u16 = 0x0201;
/// HID_SUBCLASS_*.
pub const ATTR_HID_DEVICE_SUBCLASS: u16 = 0x0202;
pub const ATTR_HID_COUNTRY_CODE: u16 = 0x0203;
/// Booleans: the host and the device are one another's alone, and the
/// device opens the channels again itself.
pub const ATTR_HID_VIRTUAL_CABLE: u16 = 0x0204;
pub const ATTR_HID_RECONNECT_INITIATE: u16 = 0x0205;
/// A sequence of sequences, a descriptor each: its type
/// (HID_DESCRIPTOR_*, an 8-bit integer) and its bytes, as a text.
pub const ATTR_HID_DESCRIPTOR_LIST: u16 = 0x0206;
/// A sequence of sequences: a language's id and its attributes' base.
pub const ATTR_HID_LANGID_BASE_LIST: u16 = 0x0207;
pub const ATTR_HID_BATTERY_POWER: u16 = 0x0209;
pub const ATTR_HID_REMOTE_WAKE: u16 = 0x020A;
pub const ATTR_HID_PROFILE_VERSION: u16 = 0x020B;
pub const ATTR_HID_SUPERVISION_TIMEOUT: u16 = 0x020C;
pub const ATTR_HID_NORMALLY_CONNECTABLE: u16 = 0x020D;
/// A boolean: the device has the boot protocol.
pub const ATTR_HID_BOOT_DEVICE: u16 = 0x020E;

/// ATTR_HID_DEVICE_SUBCLASS: the upper bits of the class of device's
/// minor peripheral class.
pub const HID_SUBCLASS_KEYBOARD: u8 = 0x40;
pub const HID_SUBCLASS_POINTING: u8 = 0x80;
pub const HID_SUBCLASS_COMBO: u8 = 0xC0;

/// A descriptor's type in ATTR_HID_DESCRIPTOR_LIST.
pub const HID_DESCRIPTOR_REPORT: u8 = 0x22;
pub const HID_DESCRIPTOR_PHYSICAL: u8 = 0x23;

/// A frame's first byte: the transaction's type, and its parameter.
pub const HIDP_TYPE_MASK: u8 = 0xF0;
pub const HIDP_PARAM_MASK: u8 = 0x0F;
pub const HIDP_HANDSHAKE: u8 = 0x00;
pub const HIDP_CONTROL: u8 = 0x10;
pub const HIDP_GET_REPORT: u8 = 0x40;
pub const HIDP_SET_REPORT: u8 = 0x50;
pub const HIDP_GET_PROTOCOL: u8 = 0x60;
pub const HIDP_SET_PROTOCOL: u8 = 0x70;
pub const HIDP_DATA: u8 = 0xA0;

/// HANDSHAKE's parameter: how a request went.
pub const HIDP_HSHK_SUCCESSFUL: u8 = 0x0;
pub const HIDP_HSHK_NOT_READY: u8 = 0x1;
pub const HIDP_HSHK_ERR_INVALID_REPORT_ID: u8 = 0x2;
pub const HIDP_HSHK_ERR_UNSUPPORTED_REQUEST: u8 = 0x3;
pub const HIDP_HSHK_ERR_INVALID_PARAMETER: u8 = 0x4;
pub const HIDP_HSHK_ERR_UNKNOWN: u8 = 0xE;
pub const HIDP_HSHK_ERR_FATAL: u8 = 0xF;

/// HID_CONTROL's parameter. VIRTUAL_CABLE_UNPLUG: the other side forgets
/// the bond, and both close the channels.
pub const HIDP_CTRL_SUSPEND: u8 = 0x3;
pub const HIDP_CTRL_EXIT_SUSPEND: u8 = 0x4;
pub const HIDP_CTRL_VIRTUAL_CABLE_UNPLUG: u8 = 0x5;

/// The kind of report: DATA's, GET_REPORT's and SET_REPORT's parameter.
pub const HIDP_REPORT_OTHER: u8 = 0x0;
pub const HIDP_REPORT_INPUT: u8 = 0x1;
pub const HIDP_REPORT_OUTPUT: u8 = 0x2;
pub const HIDP_REPORT_FEATURE: u8 = 0x3;

/// SET_PROTOCOL's parameter, and GET_PROTOCOL's answer; over GATT,
/// Protocol Mode's value.
pub const HIDP_PROTOCOL_BOOT: u8 = 0x0;
pub const HIDP_PROTOCOL_REPORT: u8 = 0x1;

// --- over GATT --------------------------------------------------------------------

/// The GATT service (BTService.class16), and its characteristics: what
/// the device is (bcdHID, country, flags), its report descriptor, suspend
/// and exit suspend (HIDP_CTRL_*'s values), a report, the protocol in
/// use, and the boot protocol's own reports.
pub const UUID_HID_SERVICE: u16 = 0x1812;
pub const GATT_HID_INFORMATION: u16 = 0x2A4A;
pub const GATT_REPORT_MAP: u16 = 0x2A4B;
pub const GATT_HID_CONTROL_POINT: u16 = 0x2A4C;
pub const GATT_REPORT: u16 = 0x2A4D;
pub const GATT_PROTOCOL_MODE: u16 = 0x2A4E;
pub const GATT_BOOT_KEYBOARD_INPUT: u16 = 0x2A22;
pub const GATT_BOOT_KEYBOARD_OUTPUT: u16 = 0x2A32;
pub const GATT_BOOT_MOUSE_INPUT: u16 = 0x2A33;

// SPDX-License-Identifier: MIT
//! The Host Controller Interface's numbers: the commands' opcodes, the
//! events' codes, the controller's status codes, the bits of its feature
//! pages and of its supported-commands mask, the class of device, and the
//! sizes of the packets' headers. A packet's layout is the Bluetooth Core
//! Specification's (volume 4, part E); every field is little-endian.
//!
//! **A command** is its opcode (2 bytes: the group in the top 6 bits, the
//! command in the low 10), the length of its parameters (1 byte) and the
//! parameters. **An event** is its code (1 byte), the length of its
//! parameters (1 byte) and the parameters; Command Complete and Command
//! Status answer the commands, each naming the opcode it answers and how
//! many more commands the controller takes now. **An ACL packet** is its
//! connection handle with two flags above it (2 bytes), its data's
//! length (2 bytes) and the data.

/// The headers' sizes: a command's, an event's, an ACL packet's.
pub const HCI_COMMAND_HDR: usize = 3;
pub const HCI_EVENT_HDR: usize = 2;
pub const HCI_ACL_HDR: usize = 4;
/// The most parameters a command or an event has.
pub const HCI_MAX_PARAMS: usize = 255;
/// The longest event: its header and its parameters.
pub const HCI_MAX_EVENT: usize = HCI_EVENT_HDR + HCI_MAX_PARAMS;
/// The longest name a controller shows, in bytes of UTF-8.
pub const HCI_MAX_NAME: usize = 248;

/// An opcode from its group (OGF) and its command (OCF).
pub const OGF_LINK_CONTROL: u16 = 0x01;
pub const OGF_LINK_POLICY: u16 = 0x02;
pub const OGF_CONTROLLER: u16 = 0x03;
pub const OGF_INFORMATIONAL: u16 = 0x04;
pub const OGF_STATUS: u16 = 0x05;
pub const OGF_LE: u16 = 0x08;
/// The group a chip's maker has for its own commands.
pub const OGF_VENDOR: u16 = 0x3F;

// --- the commands' opcodes ---------------------------------------------------

// Link control.
pub const HCI_OP_INQUIRY: u16 = 0x0401;
pub const HCI_OP_INQUIRY_CANCEL: u16 = 0x0402;
pub const HCI_OP_CREATE_CONNECTION: u16 = 0x0405;
pub const HCI_OP_DISCONNECT: u16 = 0x0406;
pub const HCI_OP_ACCEPT_CONNECTION: u16 = 0x0409;
pub const HCI_OP_REJECT_CONNECTION: u16 = 0x040A;
pub const HCI_OP_REMOTE_NAME_REQUEST: u16 = 0x0419;
pub const HCI_OP_REMOTE_NAME_REQUEST_CANCEL: u16 = 0x041A;
// Controller and baseband.
pub const HCI_OP_SET_EVENT_MASK: u16 = 0x0C01;
pub const HCI_OP_RESET: u16 = 0x0C03;
pub const HCI_OP_WRITE_LOCAL_NAME: u16 = 0x0C13;
pub const HCI_OP_READ_LOCAL_NAME: u16 = 0x0C14;
pub const HCI_OP_WRITE_SCAN_ENABLE: u16 = 0x0C1A;
pub const HCI_OP_READ_CLASS_OF_DEVICE: u16 = 0x0C23;
pub const HCI_OP_WRITE_CLASS_OF_DEVICE: u16 = 0x0C24;
pub const HCI_OP_WRITE_INQUIRY_SCAN_TYPE: u16 = 0x0C43;
pub const HCI_OP_WRITE_INQUIRY_MODE: u16 = 0x0C45;
pub const HCI_OP_WRITE_EXTENDED_INQUIRY_RESPONSE: u16 = 0x0C52;
pub const HCI_OP_WRITE_SIMPLE_PAIRING_MODE: u16 = 0x0C56;
pub const HCI_OP_SET_EVENT_MASK_PAGE_2: u16 = 0x0C63;
pub const HCI_OP_WRITE_LE_HOST_SUPPORTED: u16 = 0x0C6D;
pub const HCI_OP_WRITE_SECURE_CONNECTIONS_HOST_SUPPORT: u16 = 0x0C7A;
// Informational.
pub const HCI_OP_READ_LOCAL_VERSION: u16 = 0x1001;
pub const HCI_OP_READ_LOCAL_COMMANDS: u16 = 0x1002;
pub const HCI_OP_READ_LOCAL_FEATURES: u16 = 0x1003;
pub const HCI_OP_READ_LOCAL_EXT_FEATURES: u16 = 0x1004;
pub const HCI_OP_READ_BUFFER_SIZE: u16 = 0x1005;
pub const HCI_OP_READ_BD_ADDR: u16 = 0x1009;
// LE.
pub const HCI_OP_LE_SET_EVENT_MASK: u16 = 0x2001;
pub const HCI_OP_LE_READ_BUFFER_SIZE: u16 = 0x2002;
pub const HCI_OP_LE_READ_LOCAL_FEATURES: u16 = 0x2003;
pub const HCI_OP_LE_SET_SCAN_PARAMETERS: u16 = 0x200B;
pub const HCI_OP_LE_SET_SCAN_ENABLE: u16 = 0x200C;
pub const HCI_OP_LE_CREATE_CONNECTION: u16 = 0x200D;

// --- the events' codes -------------------------------------------------------

pub const HCI_EV_INQUIRY_COMPLETE: u8 = 0x01;
pub const HCI_EV_INQUIRY_RESULT: u8 = 0x02;
pub const HCI_EV_CONNECTION_COMPLETE: u8 = 0x03;
pub const HCI_EV_CONNECTION_REQUEST: u8 = 0x04;
pub const HCI_EV_DISCONNECTION_COMPLETE: u8 = 0x05;
pub const HCI_EV_AUTHENTICATION_COMPLETE: u8 = 0x06;
pub const HCI_EV_REMOTE_NAME_REQUEST_COMPLETE: u8 = 0x07;
pub const HCI_EV_ENCRYPTION_CHANGE: u8 = 0x08;
pub const HCI_EV_COMMAND_COMPLETE: u8 = 0x0E;
pub const HCI_EV_COMMAND_STATUS: u8 = 0x0F;
pub const HCI_EV_HARDWARE_ERROR: u8 = 0x10;
pub const HCI_EV_NUMBER_OF_COMPLETED_PACKETS: u8 = 0x13;
pub const HCI_EV_DATA_BUFFER_OVERFLOW: u8 = 0x1A;
pub const HCI_EV_INQUIRY_RESULT_WITH_RSSI: u8 = 0x22;
pub const HCI_EV_EXTENDED_INQUIRY_RESULT: u8 = 0x2F;
pub const HCI_EV_LE_META: u8 = 0x3E;
/// LE Meta's subevents: the first parameter.
pub const HCI_LE_EV_ADVERTISING_REPORT: u8 = 0x02;
/// A chip maker's own events.
pub const HCI_EV_VENDOR: u8 = 0xFF;

// --- the controller's status codes -------------------------------------------

pub const HCI_SUCCESS: u8 = 0x00;
pub const HCI_ERR_UNKNOWN_COMMAND: u8 = 0x01;
pub const HCI_ERR_UNKNOWN_CONNECTION: u8 = 0x02;
pub const HCI_ERR_HARDWARE_FAILURE: u8 = 0x03;
pub const HCI_ERR_PAGE_TIMEOUT: u8 = 0x04;
pub const HCI_ERR_AUTHENTICATION_FAILURE: u8 = 0x05;
pub const HCI_ERR_PIN_OR_KEY_MISSING: u8 = 0x06;
pub const HCI_ERR_MEMORY_EXCEEDED: u8 = 0x07;
pub const HCI_ERR_CONNECTION_TIMEOUT: u8 = 0x08;
pub const HCI_ERR_COMMAND_DISALLOWED: u8 = 0x0C;
pub const HCI_ERR_REJECTED_LIMITED_RESOURCES: u8 = 0x0D;
pub const HCI_ERR_REJECTED_SECURITY: u8 = 0x0E;
pub const HCI_ERR_UNSUPPORTED_FEATURE: u8 = 0x11;
pub const HCI_ERR_INVALID_PARAMETERS: u8 = 0x12;
pub const HCI_ERR_REMOTE_USER_TERMINATED: u8 = 0x13;
pub const HCI_ERR_LOCAL_HOST_TERMINATED: u8 = 0x16;
pub const HCI_ERR_PAIRING_NOT_ALLOWED: u8 = 0x18;
pub const HCI_ERR_UNSPECIFIED: u8 = 0x1F;

// --- versions ----------------------------------------------------------------

/// The HCI's and the link manager's versions, as Read Local Version
/// Information answers them.
pub const BT_VERSION_1_0B: u8 = 0;
pub const BT_VERSION_1_1: u8 = 1;
pub const BT_VERSION_1_2: u8 = 2;
pub const BT_VERSION_2_0: u8 = 3;
pub const BT_VERSION_2_1: u8 = 4;
pub const BT_VERSION_3_0: u8 = 5;
pub const BT_VERSION_4_0: u8 = 6;
pub const BT_VERSION_4_1: u8 = 7;
pub const BT_VERSION_4_2: u8 = 8;
pub const BT_VERSION_5_0: u8 = 9;
pub const BT_VERSION_5_1: u8 = 10;
pub const BT_VERSION_5_2: u8 = 11;
pub const BT_VERSION_5_3: u8 = 12;
pub const BT_VERSION_5_4: u8 = 13;
pub const BT_VERSION_6_0: u8 = 14;

// --- the feature pages -------------------------------------------------------
//
// Feature `n` of a page is bit `n % 8` of its byte `n / 8`.

// Page 0: the controller's.
pub const LMP_ENCRYPTION: u8 = 2;
pub const LMP_ROLE_SWITCH: u8 = 5;
pub const LMP_SNIFF: u8 = 7;
pub const LMP_EDR_ACL_2M: u8 = 25;
pub const LMP_EDR_ACL_3M: u8 = 26;
pub const LMP_INTERLACED_INQUIRY_SCAN: u8 = 28;
pub const LMP_RSSI_INQUIRY: u8 = 30;
pub const LMP_ESCO: u8 = 31;
pub const LMP_BREDR_NOT_SUPPORTED: u8 = 37;
pub const LMP_LE: u8 = 38;
pub const LMP_SNIFF_SUBRATING: u8 = 41;
pub const LMP_PAUSE_ENCRYPTION: u8 = 42;
pub const LMP_EXTENDED_INQUIRY: u8 = 48;
pub const LMP_SIMULTANEOUS_LE_BREDR: u8 = 49;
pub const LMP_SIMPLE_PAIRING: u8 = 51;
pub const LMP_NON_FLUSHABLE: u8 = 54;
pub const LMP_SUPERVISION_TIMEOUT_EVENT: u8 = 56;
pub const LMP_INQUIRY_TX_POWER: u8 = 57;
pub const LMP_EXTENDED_FEATURES: u8 = 63;
// Page 1: what the host has switched on.
pub const LMP_HOST_SIMPLE_PAIRING: u8 = 0;
pub const LMP_HOST_LE: u8 = 1;
pub const LMP_HOST_SECURE_CONNECTIONS: u8 = 3;
// Page 2.
pub const LMP_SECURE_CONNECTIONS: u8 = 8;
pub const LMP_PING: u8 = 9;

// The LE features.
pub const LE_FEATURE_ENCRYPTION: u8 = 0;
pub const LE_FEATURE_CONNECTION_PARAMETERS_REQUEST: u8 = 1;
pub const LE_FEATURE_PING: u8 = 4;
pub const LE_FEATURE_DATA_LENGTH: u8 = 5;
pub const LE_FEATURE_PRIVACY: u8 = 6;
pub const LE_FEATURE_2M_PHY: u8 = 8;
pub const LE_FEATURE_CODED_PHY: u8 = 11;
pub const LE_FEATURE_EXTENDED_ADVERTISING: u8 = 12;
pub const LE_FEATURE_PERIODIC_ADVERTISING: u8 = 13;

// --- the supported commands --------------------------------------------------
//
// The command at `n` is bit `n % 8` of byte `n / 8` of what Read Local
// Supported Commands answers.

pub const CMDBIT_INQUIRY: u16 = 0;
pub const CMDBIT_INQUIRY_CANCEL: u16 = 1;
pub const CMDBIT_DISCONNECT: u16 = 5;
pub const CMDBIT_REMOTE_NAME_REQUEST: u16 = 19;
pub const CMDBIT_REMOTE_NAME_REQUEST_CANCEL: u16 = 20;
pub const CMDBIT_SET_EVENT_MASK: u16 = 46;
pub const CMDBIT_RESET: u16 = 47;
pub const CMDBIT_WRITE_LOCAL_NAME: u16 = 56;
pub const CMDBIT_READ_LOCAL_NAME: u16 = 57;
pub const CMDBIT_WRITE_SCAN_ENABLE: u16 = 63;
pub const CMDBIT_WRITE_CLASS_OF_DEVICE: u16 = 73;
pub const CMDBIT_WRITE_INQUIRY_SCAN_TYPE: u16 = 101;
pub const CMDBIT_WRITE_INQUIRY_MODE: u16 = 103;
pub const CMDBIT_READ_LOCAL_VERSION: u16 = 115;
pub const CMDBIT_READ_LOCAL_COMMANDS: u16 = 116;
pub const CMDBIT_READ_LOCAL_FEATURES: u16 = 117;
pub const CMDBIT_READ_LOCAL_EXT_FEATURES: u16 = 118;
pub const CMDBIT_READ_BUFFER_SIZE: u16 = 119;
pub const CMDBIT_READ_BD_ADDR: u16 = 121;
pub const CMDBIT_WRITE_EXTENDED_INQUIRY_RESPONSE: u16 = 137;
pub const CMDBIT_WRITE_SIMPLE_PAIRING_MODE: u16 = 142;
pub const CMDBIT_SET_EVENT_MASK_PAGE_2: u16 = 178;
pub const CMDBIT_WRITE_LE_HOST_SUPPORTED: u16 = 198;
pub const CMDBIT_LE_SET_EVENT_MASK: u16 = 200;
pub const CMDBIT_LE_READ_BUFFER_SIZE: u16 = 201;
pub const CMDBIT_LE_READ_LOCAL_FEATURES: u16 = 202;
pub const CMDBIT_LE_SET_SCAN_PARAMETERS: u16 = 210;
pub const CMDBIT_LE_SET_SCAN_ENABLE: u16 = 211;
pub const CMDBIT_LE_CREATE_CONNECTION: u16 = 212;
pub const CMDBIT_WRITE_SECURE_CONNECTIONS_HOST_SUPPORT: u16 = 259;

// --- finding devices ---------------------------------------------------------

/// The inquiry access code every device that is visible answers: the
/// general one (GIAC), its LAP the least significant byte first.
pub const LAP_GIAC = [3]u8{ 0x33, 0x8B, 0x9E };
/// Inquiry's length is in units of 1.28 s, from 1 to 0x30.
pub const INQUIRY_UNIT_MS: u32 = 1280;
pub const INQUIRY_LENGTH_MAX: u8 = 0x30;
/// Write Inquiry Mode's modes: results with RSSI, and extended results
/// (with RSSI and the device's own data).
pub const INQUIRY_MODE_RSSI: u8 = 1;
pub const INQUIRY_MODE_EXTENDED: u8 = 2;
/// Write Inquiry Scan Type's: a frequency of each train listened on in
/// every interval, rather than one.
pub const INQUIRY_SCAN_INTERLACED: u8 = 1;
/// Write Scan Enable's bits: answering inquiries (visible), answering
/// pages (connectable).
pub const SCAN_INQUIRY: u8 = 1 << 0;
pub const SCAN_PAGE: u8 = 1 << 1;
/// A Clock_Offset that is valid has this bit set when it is handed back.
pub const CLOCK_OFFSET_VALID: u16 = 0x8000;
/// The extended inquiry response's room, after FEC_Required.
pub const EIR_SIZE: usize = 240;

/// LE scanning's types, and its intervals and windows in units of 0.625
/// ms.
pub const LE_SCAN_PASSIVE: u8 = 0;
pub const LE_SCAN_ACTIVE: u8 = 1;
pub const LE_SCAN_UNIT_US: u32 = 625;
/// An advertising report's event type.
pub const LE_ADV_IND: u8 = 0x00;
pub const LE_ADV_DIRECT_IND: u8 = 0x01;
pub const LE_ADV_SCAN_IND: u8 = 0x02;
pub const LE_ADV_NONCONN_IND: u8 = 0x03;
pub const LE_SCAN_RSP: u8 = 0x04;
/// An LE address's type, as a report carries it: public, random, and
/// either resolved from a private address.
pub const LE_ADDR_PUBLIC: u8 = 0x00;
pub const LE_ADDR_RANDOM: u8 = 0x01;
pub const LE_ADDR_PUBLIC_IDENTITY: u8 = 0x02;
pub const LE_ADDR_RANDOM_IDENTITY: u8 = 0x03;
/// A report's RSSI when the controller has none.
pub const LE_RSSI_NONE: i8 = 127;

/// What an advertisement and an extended inquiry response carry: a run
/// of structures, each its length (1 byte, its type and data), its type
/// and its data.
pub const AD_FLAGS: u8 = 0x01;
pub const AD_UUID16_SOME: u8 = 0x02;
pub const AD_UUID16_ALL: u8 = 0x03;
pub const AD_UUID32_SOME: u8 = 0x04;
pub const AD_UUID32_ALL: u8 = 0x05;
pub const AD_UUID128_SOME: u8 = 0x06;
pub const AD_UUID128_ALL: u8 = 0x07;
pub const AD_NAME_SHORT: u8 = 0x08;
pub const AD_NAME_COMPLETE: u8 = 0x09;
pub const AD_TX_POWER: u8 = 0x0A;
pub const AD_CLASS_OF_DEVICE: u8 = 0x0D;
pub const AD_APPEARANCE: u8 = 0x19;
pub const AD_MANUFACTURER_DATA: u8 = 0xFF;
/// AD_FLAGS' bits.
pub const AD_FLAG_LIMITED: u8 = 1 << 0;
pub const AD_FLAG_GENERAL: u8 = 1 << 1;
pub const AD_FLAG_NO_BREDR: u8 = 1 << 2;

/// The base every short UUID stands for, the least significant byte
/// first: a 16- or 32-bit one goes in its bytes 12 to 15.
pub const UUID_BASE = [16]u8{ 0xFB, 0x34, 0x9B, 0x5F, 0x80, 0x00, 0x00, 0x80, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

// --- the class of device -----------------------------------------------------
//
// 24 bits: the services in the top 11, the major class in bits 8 to 12,
// the minor class in bits 2 to 7.

pub const COD_SERVICE_LIMITED: u32 = 1 << 13;
pub const COD_SERVICE_POSITIONING: u32 = 1 << 16;
pub const COD_SERVICE_NETWORKING: u32 = 1 << 17;
pub const COD_SERVICE_RENDERING: u32 = 1 << 18;
pub const COD_SERVICE_CAPTURING: u32 = 1 << 19;
pub const COD_SERVICE_OBJECT_TRANSFER: u32 = 1 << 20;
pub const COD_SERVICE_AUDIO: u32 = 1 << 21;
pub const COD_SERVICE_TELEPHONY: u32 = 1 << 22;
pub const COD_SERVICE_INFORMATION: u32 = 1 << 23;
/// The major class, `(cod >> 8) & 0x1F`.
pub const COD_MAJOR_MISC: u32 = 0x00;
pub const COD_MAJOR_COMPUTER: u32 = 0x01;
pub const COD_MAJOR_PHONE: u32 = 0x02;
pub const COD_MAJOR_NETWORK: u32 = 0x03;
pub const COD_MAJOR_AUDIO_VIDEO: u32 = 0x04;
pub const COD_MAJOR_PERIPHERAL: u32 = 0x05;
pub const COD_MAJOR_IMAGING: u32 = 0x06;
pub const COD_MAJOR_WEARABLE: u32 = 0x07;
pub const COD_MAJOR_TOY: u32 = 0x08;
pub const COD_MAJOR_HEALTH: u32 = 0x09;
pub const COD_MAJOR_UNCATEGORIZED: u32 = 0x1F;
/// A computer's minor class, `(cod >> 2) & 0x3F`.
pub const COD_COMPUTER_DESKTOP: u32 = 0x01;
pub const COD_COMPUTER_SERVER: u32 = 0x02;
pub const COD_COMPUTER_LAPTOP: u32 = 0x03;
pub const COD_COMPUTER_HANDHELD: u32 = 0x04;

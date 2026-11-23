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
pub const HCI_OP_CREATE_CONNECTION_CANCEL: u16 = 0x0408;
pub const HCI_OP_ACCEPT_CONNECTION: u16 = 0x0409;
pub const HCI_OP_REJECT_CONNECTION: u16 = 0x040A;
pub const HCI_OP_LINK_KEY_REPLY: u16 = 0x040B;
pub const HCI_OP_LINK_KEY_NEGATIVE_REPLY: u16 = 0x040C;
pub const HCI_OP_PIN_CODE_REPLY: u16 = 0x040D;
pub const HCI_OP_PIN_CODE_NEGATIVE_REPLY: u16 = 0x040E;
pub const HCI_OP_AUTHENTICATION_REQUESTED: u16 = 0x0411;
pub const HCI_OP_SET_CONNECTION_ENCRYPTION: u16 = 0x0413;
pub const HCI_OP_REMOTE_NAME_REQUEST: u16 = 0x0419;
pub const HCI_OP_REMOTE_NAME_REQUEST_CANCEL: u16 = 0x041A;
pub const HCI_OP_READ_REMOTE_FEATURES: u16 = 0x041B;
pub const HCI_OP_IO_CAPABILITY_REPLY: u16 = 0x042B;
pub const HCI_OP_USER_CONFIRMATION_REPLY: u16 = 0x042C;
pub const HCI_OP_USER_CONFIRMATION_NEGATIVE_REPLY: u16 = 0x042D;
pub const HCI_OP_USER_PASSKEY_REPLY: u16 = 0x042E;
pub const HCI_OP_USER_PASSKEY_NEGATIVE_REPLY: u16 = 0x042F;
pub const HCI_OP_IO_CAPABILITY_NEGATIVE_REPLY: u16 = 0x0434;
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
pub const HCI_OP_READ_ENCRYPTION_KEY_SIZE: u16 = 0x1408;
// LE.
pub const HCI_OP_LE_SET_EVENT_MASK: u16 = 0x2001;
pub const HCI_OP_LE_READ_BUFFER_SIZE: u16 = 0x2002;
pub const HCI_OP_LE_READ_LOCAL_FEATURES: u16 = 0x2003;
pub const HCI_OP_LE_SET_SCAN_PARAMETERS: u16 = 0x200B;
pub const HCI_OP_LE_SET_SCAN_ENABLE: u16 = 0x200C;
pub const HCI_OP_LE_CREATE_CONNECTION: u16 = 0x200D;
pub const HCI_OP_LE_CREATE_CONNECTION_CANCEL: u16 = 0x200E;
pub const HCI_OP_LE_CONNECTION_UPDATE: u16 = 0x2013;
pub const HCI_OP_LE_ENABLE_ENCRYPTION: u16 = 0x2019;
pub const HCI_OP_LE_REMOTE_PARAMETERS_REPLY: u16 = 0x2020;
pub const HCI_OP_LE_REMOTE_PARAMETERS_NEGATIVE_REPLY: u16 = 0x2021;

// --- the events' codes -------------------------------------------------------

pub const HCI_EV_INQUIRY_COMPLETE: u8 = 0x01;
pub const HCI_EV_INQUIRY_RESULT: u8 = 0x02;
pub const HCI_EV_CONNECTION_COMPLETE: u8 = 0x03;
pub const HCI_EV_CONNECTION_REQUEST: u8 = 0x04;
pub const HCI_EV_DISCONNECTION_COMPLETE: u8 = 0x05;
pub const HCI_EV_AUTHENTICATION_COMPLETE: u8 = 0x06;
pub const HCI_EV_REMOTE_NAME_REQUEST_COMPLETE: u8 = 0x07;
pub const HCI_EV_ENCRYPTION_CHANGE: u8 = 0x08;
pub const HCI_EV_READ_REMOTE_FEATURES_COMPLETE: u8 = 0x0B;
pub const HCI_EV_COMMAND_COMPLETE: u8 = 0x0E;
pub const HCI_EV_COMMAND_STATUS: u8 = 0x0F;
pub const HCI_EV_HARDWARE_ERROR: u8 = 0x10;
pub const HCI_EV_ROLE_CHANGE: u8 = 0x12;
pub const HCI_EV_NUMBER_OF_COMPLETED_PACKETS: u8 = 0x13;
pub const HCI_EV_PIN_CODE_REQUEST: u8 = 0x16;
pub const HCI_EV_LINK_KEY_REQUEST: u8 = 0x17;
pub const HCI_EV_LINK_KEY_NOTIFICATION: u8 = 0x18;
pub const HCI_EV_DATA_BUFFER_OVERFLOW: u8 = 0x1A;
pub const HCI_EV_INQUIRY_RESULT_WITH_RSSI: u8 = 0x22;
pub const HCI_EV_EXTENDED_INQUIRY_RESULT: u8 = 0x2F;
pub const HCI_EV_ENCRYPTION_KEY_REFRESH_COMPLETE: u8 = 0x30;
pub const HCI_EV_IO_CAPABILITY_REQUEST: u8 = 0x31;
pub const HCI_EV_IO_CAPABILITY_RESPONSE: u8 = 0x32;
pub const HCI_EV_USER_CONFIRMATION_REQUEST: u8 = 0x33;
pub const HCI_EV_USER_PASSKEY_REQUEST: u8 = 0x34;
pub const HCI_EV_SIMPLE_PAIRING_COMPLETE: u8 = 0x36;
pub const HCI_EV_USER_PASSKEY_NOTIFICATION: u8 = 0x3B;
pub const HCI_EV_KEYPRESS_NOTIFICATION: u8 = 0x3C;
pub const HCI_EV_REMOTE_HOST_FEATURES: u8 = 0x3D;
pub const HCI_EV_LE_META: u8 = 0x3E;
/// LE Meta's subevents: the first parameter.
pub const HCI_LE_EV_CONNECTION_COMPLETE: u8 = 0x01;
pub const HCI_LE_EV_ADVERTISING_REPORT: u8 = 0x02;
pub const HCI_LE_EV_CONNECTION_UPDATE_COMPLETE: u8 = 0x03;
pub const HCI_LE_EV_READ_REMOTE_FEATURES_COMPLETE: u8 = 0x04;
pub const HCI_LE_EV_LONG_TERM_KEY_REQUEST: u8 = 0x05;
pub const HCI_LE_EV_REMOTE_PARAMETERS_REQUEST: u8 = 0x06;
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
pub const HCI_ERR_CONNECTION_EXISTS: u8 = 0x0B;
pub const HCI_ERR_COMMAND_DISALLOWED: u8 = 0x0C;
pub const HCI_ERR_REJECTED_LIMITED_RESOURCES: u8 = 0x0D;
pub const HCI_ERR_REJECTED_SECURITY: u8 = 0x0E;
pub const HCI_ERR_REJECTED_ADDRESS: u8 = 0x0F;
pub const HCI_ERR_UNSUPPORTED_FEATURE: u8 = 0x11;
pub const HCI_ERR_INVALID_PARAMETERS: u8 = 0x12;
pub const HCI_ERR_REMOTE_USER_TERMINATED: u8 = 0x13;
pub const HCI_ERR_REMOTE_LOW_RESOURCES: u8 = 0x14;
pub const HCI_ERR_REMOTE_POWER_OFF: u8 = 0x15;
pub const HCI_ERR_LOCAL_HOST_TERMINATED: u8 = 0x16;
pub const HCI_ERR_REPEATED_ATTEMPTS: u8 = 0x17;
pub const HCI_ERR_PAIRING_NOT_ALLOWED: u8 = 0x18;
pub const HCI_ERR_LMP_RESPONSE_TIMEOUT: u8 = 0x22;
pub const HCI_ERR_INSUFFICIENT_SECURITY: u8 = 0x2F;
pub const HCI_ERR_UNSPECIFIED: u8 = 0x1F;
pub const HCI_ERR_INSTANT_PASSED: u8 = 0x28;
pub const HCI_ERR_UNACCEPTABLE_PARAMETERS: u8 = 0x3B;
pub const HCI_ERR_FAILED_TO_ESTABLISH: u8 = 0x3E;

// --- pairing -----------------------------------------------------------------

/// IO Capability Request Reply's IO capability: what the host's user can
/// do (Secure Simple Pairing; KeyboardDisplay is LE's alone).
pub const IO_DISPLAY_ONLY: u8 = 0x00;
pub const IO_DISPLAY_YES_NO: u8 = 0x01;
pub const IO_KEYBOARD_ONLY: u8 = 0x02;
pub const IO_NO_INPUT_OUTPUT: u8 = 0x03;
/// Its authentication requirements: the bit for protection from a man in
/// the middle, and what is to be bonded - nothing, this device on its
/// own (dedicated), or in passing (general).
pub const AUTH_MITM: u8 = 0x01;
pub const AUTH_NO_BONDING: u8 = 0x00;
pub const AUTH_DEDICATED_BONDING: u8 = 0x02;
pub const AUTH_GENERAL_BONDING: u8 = 0x04;
/// Link Key Notification's key types.
pub const LINK_KEY_COMBINATION: u8 = 0x00;
pub const LINK_KEY_LOCAL_UNIT: u8 = 0x01;
pub const LINK_KEY_REMOTE_UNIT: u8 = 0x02;
pub const LINK_KEY_DEBUG: u8 = 0x03;
pub const LINK_KEY_UNAUTHENTICATED_P192: u8 = 0x04;
pub const LINK_KEY_AUTHENTICATED_P192: u8 = 0x05;
pub const LINK_KEY_CHANGED_COMBINATION: u8 = 0x06;
pub const LINK_KEY_UNAUTHENTICATED_P256: u8 = 0x07;
pub const LINK_KEY_AUTHENTICATED_P256: u8 = 0x08;
/// A link key's length, and the shortest encryption key a link is kept
/// with: one shorter is open to being guessed.
pub const LINK_KEY_SIZE = 16;
pub const MIN_ENCRYPTION_KEY_SIZE: u8 = 7;

// --- connections -------------------------------------------------------------

/// Link Type, in Connection Request and Connection Complete.
pub const LINK_SCO: u8 = 0x00;
pub const LINK_ACL: u8 = 0x01;
pub const LINK_ESCO: u8 = 0x02;
/// A connection's role: the central's, which pages or initiates, and the
/// peripheral's. Accept Connection Request's role: 0 to take the
/// central's, 1 to stay the peripheral.
pub const ROLE_CENTRAL: u8 = 0x00;
pub const ROLE_PERIPHERAL: u8 = 0x01;
/// Create Connection's packet types: every ACL packet of one, three and
/// five slots, with and without FEC.
pub const ACL_PACKET_TYPES: u16 = 0xCC18;
/// Create Connection's role switch: allowed.
pub const ALLOW_ROLE_SWITCH: u8 = 0x01;
/// A page scan repetition mode: how often a device listens for pages -
/// all the time, every 1.28 s, every 2.56 s.
pub const PAGE_SCAN_R0: u8 = 0x00;
pub const PAGE_SCAN_R1: u8 = 0x01;
pub const PAGE_SCAN_R2: u8 = 0x02;

/// An ACL packet's first two bytes: its connection handle in the low 12
/// bits, the packet boundary flag in the two above.
pub const ACL_HANDLE_MASK: u16 = 0x0FFF;
pub const ACL_BOUNDARY_SHIFT: u4 = 12;
/// The packet boundary flag: the first fragment of an L2CAP frame the
/// controller may not flush (what the host sends on LE), a fragment that
/// goes on one, the first fragment of one it may flush (what the host
/// sends on BR/EDR, and what a controller hands up first).
pub const ACL_START_NO_FLUSH: u16 = 0x00;
pub const ACL_CONTINUING: u16 = 0x01;
pub const ACL_START: u16 = 0x02;

/// LE Create Connection's: the scan's interval and window, the
/// connection's interval, latency and supervision time-out, the times a
/// connection event takes - in 0.625 ms, 1.25 ms and 10 ms units.
pub const LE_CONNECT_SCAN_INTERVAL: u16 = 0x0060;
pub const LE_CONNECT_SCAN_WINDOW: u16 = 0x0060;
pub const LE_CONNECT_INTERVAL_MIN: u16 = 0x0018;
pub const LE_CONNECT_INTERVAL_MAX: u16 = 0x0028;
pub const LE_CONNECT_LATENCY: u16 = 0x0000;
pub const LE_CONNECT_SUPERVISION: u16 = 0x002A;

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
pub const CMDBIT_CREATE_CONNECTION: u16 = 4;
pub const CMDBIT_DISCONNECT: u16 = 5;
pub const CMDBIT_CREATE_CONNECTION_CANCEL: u16 = 7;
pub const CMDBIT_ACCEPT_CONNECTION: u16 = 8;
pub const CMDBIT_REJECT_CONNECTION: u16 = 9;
pub const CMDBIT_LINK_KEY_REPLY: u16 = 10;
pub const CMDBIT_LINK_KEY_NEGATIVE_REPLY: u16 = 11;
pub const CMDBIT_PIN_CODE_REPLY: u16 = 12;
pub const CMDBIT_PIN_CODE_NEGATIVE_REPLY: u16 = 13;
pub const CMDBIT_AUTHENTICATION_REQUESTED: u16 = 15;
pub const CMDBIT_SET_CONNECTION_ENCRYPTION: u16 = 16;
pub const CMDBIT_REMOTE_NAME_REQUEST: u16 = 19;
pub const CMDBIT_REMOTE_NAME_REQUEST_CANCEL: u16 = 20;
pub const CMDBIT_READ_REMOTE_FEATURES: u16 = 21;
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
pub const CMDBIT_IO_CAPABILITY_REPLY: u16 = 151;
pub const CMDBIT_USER_CONFIRMATION_REPLY: u16 = 152;
pub const CMDBIT_USER_CONFIRMATION_NEGATIVE_REPLY: u16 = 153;
pub const CMDBIT_USER_PASSKEY_REPLY: u16 = 154;
pub const CMDBIT_USER_PASSKEY_NEGATIVE_REPLY: u16 = 155;
pub const CMDBIT_IO_CAPABILITY_NEGATIVE_REPLY: u16 = 163;
pub const CMDBIT_READ_ENCRYPTION_KEY_SIZE: u16 = 164;
pub const CMDBIT_SET_EVENT_MASK_PAGE_2: u16 = 178;
pub const CMDBIT_WRITE_LE_HOST_SUPPORTED: u16 = 198;
pub const CMDBIT_LE_SET_EVENT_MASK: u16 = 200;
pub const CMDBIT_LE_READ_BUFFER_SIZE: u16 = 201;
pub const CMDBIT_LE_READ_LOCAL_FEATURES: u16 = 202;
pub const CMDBIT_LE_SET_SCAN_PARAMETERS: u16 = 210;
pub const CMDBIT_LE_SET_SCAN_ENABLE: u16 = 211;
pub const CMDBIT_LE_CREATE_CONNECTION: u16 = 212;
pub const CMDBIT_LE_CREATE_CONNECTION_CANCEL: u16 = 213;
pub const CMDBIT_LE_CONNECTION_UPDATE: u16 = 218;
pub const CMDBIT_LE_ENABLE_ENCRYPTION: u16 = 224;
pub const CMDBIT_LE_REMOTE_PARAMETERS_REPLY: u16 = 268;
pub const CMDBIT_LE_REMOTE_PARAMETERS_NEGATIVE_REPLY: u16 = 269;
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

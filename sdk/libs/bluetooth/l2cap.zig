// SPDX-License-Identifier: MIT
//! L2CAP's numbers: the channels' identifiers, the signalling commands
//! and what they answer, the information a device is asked for. A
//! frame's layout is the Bluetooth Core Specification's (volume 3, part
//! A); every field is little-endian.
//!
//! **A frame** is its payload's length (2 bytes), its channel's
//! identifier (2 bytes) and the payload, carried in one ACL packet or in
//! several: the first with ACL_START (or ACL_START_NO_FLUSH), the rest
//! with ACL_CONTINUING. **A signalling command** - on the signalling
//! channel, CID_SIGNALING over BR/EDR and CID_LE_SIGNALING over LE - is
//! its code (1 byte), an identifier its answer repeats (1 byte, never 0),
//! its data's length (2 bytes) and the data.

/// A frame's header: its length and its channel.
pub const L2CAP_HDR: usize = 4;
/// A signalling command's header: code, identifier, length.
pub const L2CAP_COMMAND_HDR: usize = 4;

/// The fixed channels' identifiers.
pub const CID_SIGNALING: u16 = 0x0001;
pub const CID_CONNECTIONLESS: u16 = 0x0002;
pub const CID_ATT: u16 = 0x0004;
pub const CID_LE_SIGNALING: u16 = 0x0005;
pub const CID_SMP: u16 = 0x0006;
pub const CID_SMP_BREDR: u16 = 0x0007;
/// The first a dynamic channel may have.
pub const CID_DYNAMIC_FIRST: u16 = 0x0040;

/// The protocols a dynamic channel reaches, by their PSM: odd, the low
/// bit of its upper byte clear. From PSM_DYNAMIC_FIRST on they are no
/// protocol's own, for a program to serve.
pub const PSM_SDP: u16 = 0x0001;
pub const PSM_RFCOMM: u16 = 0x0003;
pub const PSM_HID_CONTROL: u16 = 0x0011;
pub const PSM_HID_INTERRUPT: u16 = 0x0013;
pub const PSM_AVCTP: u16 = 0x0017;
pub const PSM_AVDTP: u16 = 0x0019;
pub const PSM_ATT: u16 = 0x001F;
pub const PSM_DYNAMIC_FIRST: u16 = 0x1001;

/// The MTU a channel has where its configuration says none, and the
/// least a BR/EDR channel may say.
pub const MTU_DEFAULT: u16 = 672;
pub const MTU_LEAST_BREDR: u16 = 48;

/// The smallest MTU a signalling channel takes: what a device can always
/// be sent, over BR/EDR and over LE.
pub const MTU_SIGNALING_BREDR: u16 = 48;
pub const MTU_SIGNALING_LE: u16 = 23;

// --- signalling commands -----------------------------------------------------

pub const COMMAND_REJECT: u8 = 0x01;
pub const CONNECTION_REQUEST: u8 = 0x02;
pub const CONNECTION_RESPONSE: u8 = 0x03;
pub const CONFIGURE_REQUEST: u8 = 0x04;
pub const CONFIGURE_RESPONSE: u8 = 0x05;
pub const DISCONNECTION_REQUEST: u8 = 0x06;
pub const DISCONNECTION_RESPONSE: u8 = 0x07;
pub const ECHO_REQUEST: u8 = 0x08;
pub const ECHO_RESPONSE: u8 = 0x09;
pub const INFORMATION_REQUEST: u8 = 0x0A;
pub const INFORMATION_RESPONSE: u8 = 0x0B;
pub const CONNECTION_PARAMETER_UPDATE_REQUEST: u8 = 0x12;
pub const CONNECTION_PARAMETER_UPDATE_RESPONSE: u8 = 0x13;
pub const LE_CREDIT_CONNECTION_REQUEST: u8 = 0x14;
pub const LE_CREDIT_CONNECTION_RESPONSE: u8 = 0x15;

/// Command Reject's reasons.
pub const REJECT_NOT_UNDERSTOOD: u16 = 0x0000;
pub const REJECT_MTU_EXCEEDED: u16 = 0x0001;
pub const REJECT_INVALID_CID: u16 = 0x0002;

/// Connection Response's results.
pub const CONNECTION_SUCCESS: u16 = 0x0000;
pub const CONNECTION_PENDING: u16 = 0x0001;
pub const CONNECTION_PSM_NOT_SUPPORTED: u16 = 0x0002;
pub const CONNECTION_SECURITY_BLOCK: u16 = 0x0003;
pub const CONNECTION_NO_RESOURCES: u16 = 0x0004;
pub const CONNECTION_INVALID_SOURCE_CID: u16 = 0x0006;
pub const CONNECTION_SOURCE_CID_TAKEN: u16 = 0x0007;
/// LE Credit Based Connection Response's for a PSM there is not.
pub const LE_CONNECTION_PSM_NOT_SUPPORTED: u16 = 0x0002;
/// Connection Response's status, with CONNECTION_PENDING.
pub const STATUS_NONE: u16 = 0x0000;
pub const STATUS_AUTHENTICATION_PENDING: u16 = 0x0001;
pub const STATUS_AUTHORIZATION_PENDING: u16 = 0x0002;

/// A Configure Request's or Response's flags: more of it follows.
pub const CONFIGURE_CONTINUATION: u16 = 0x0001;
/// Configure Response's results.
pub const CONFIGURE_SUCCESS: u16 = 0x0000;
pub const CONFIGURE_UNACCEPTABLE: u16 = 0x0001;
pub const CONFIGURE_REJECTED: u16 = 0x0002;
pub const CONFIGURE_UNKNOWN_OPTIONS: u16 = 0x0003;
pub const CONFIGURE_PENDING: u16 = 0x0004;
/// A configuration option: its type (1 byte), its length (1 byte) and
/// its value. A type with OPTION_HINT set may be passed over by a side
/// that does not know it.
pub const OPTION_MTU: u8 = 0x01;
pub const OPTION_FLUSH_TIMEOUT: u8 = 0x02;
pub const OPTION_QOS: u8 = 0x03;
pub const OPTION_RETRANSMISSION: u8 = 0x04;
pub const OPTION_FCS: u8 = 0x05;
pub const OPTION_FLOW_SPEC: u8 = 0x06;
pub const OPTION_WINDOW: u8 = 0x07;
pub const OPTION_HINT: u8 = 0x80;
/// OPTION_RETRANSMISSION's length, and its mode: basic, a frame as it is.
pub const OPTION_RETRANSMISSION_LENGTH: u8 = 9;
pub const MODE_BASIC: u8 = 0x00;

/// Connection Parameter Update Response's results.
pub const PARAMETERS_ACCEPTED: u16 = 0x0000;
pub const PARAMETERS_REJECTED: u16 = 0x0001;

/// Information Request's types, and its answer's results.
pub const INFO_CONNECTIONLESS_MTU: u16 = 0x0001;
pub const INFO_EXTENDED_FEATURES: u16 = 0x0002;
pub const INFO_FIXED_CHANNELS: u16 = 0x0003;
pub const INFO_SUCCESS: u16 = 0x0000;
pub const INFO_NOT_SUPPORTED: u16 = 0x0001;

/// The extended features' bits (INFO_EXTENDED_FEATURES' 4 bytes).
pub const FEATURE_FLOW_CONTROL: u32 = 1 << 0;
pub const FEATURE_RETRANSMISSION: u32 = 1 << 1;
pub const FEATURE_ENHANCED_RETRANSMISSION: u32 = 1 << 3;
pub const FEATURE_STREAMING: u32 = 1 << 4;
pub const FEATURE_FCS: u32 = 1 << 5;
pub const FEATURE_FIXED_CHANNELS: u32 = 1 << 7;
pub const FEATURE_UNICAST_DATA: u32 = 1 << 9;

/// The fixed channels' bits (INFO_FIXED_CHANNELS' 8 bytes): bit `n` for
/// channel `n`.
pub const FIXED_SIGNALING: u64 = 1 << CID_SIGNALING;
pub const FIXED_CONNECTIONLESS: u64 = 1 << CID_CONNECTIONLESS;
pub const FIXED_SMP_BREDR: u64 = 1 << CID_SMP_BREDR;

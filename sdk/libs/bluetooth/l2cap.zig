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
/// LE Credit Based Connection Response's for a PSM there is not.
pub const LE_CONNECTION_PSM_NOT_SUPPORTED: u16 = 0x0002;

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

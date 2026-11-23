// SPDX-License-Identifier: MIT
//! A device's controls over BR/EDR: the Audio/Video Remote Control
//! Profile's numbers - its services' classes and the categories of their
//! features, its own commands and events - and those of the protocol under
//! it, AVCTP, and of the AV/C frames that carries. Its channel opens to
//! l2cap.PSM_AVCTP. A controller sends the commands; a target - the
//! device that plays, for its volume - answers them.
//!
//! **An AVCTP packet** begins with a byte: the transaction label in its
//! upper four bits - a command's, which its response carries back - the
//! packet type in the next two (AVCTP_PACKET_*), AVCTP_RESPONSE where it is
//! a response and, in one, AVCTP_IPID where the device has no profile of
//! that identifier; then the profile's identifier in two bytes, AVRCP_PID,
//! big-endian.
//!
//! **An AV/C frame** follows: a command's type or a response's (AVC_CTYPE_*,
//! AVC_RESPONSE_*) in the lower four bits of its first byte, the subunit -
//! a panel, AVC_SUBUNIT_PANEL - in its second and the opcode in its third.
//! The profile's own commands are AVC_OP_VENDOR_DEPENDENT: after the
//! opcode the Bluetooth SIG's company ID in three bytes, the PDU's ID, a
//! byte whose lower two bits are the packet type - a single one,
//! AVRCP_PACKET_SINGLE - and the length of the parameters in two bytes,
//! big-endian.
//!
//! **Absolute volume** is a value of 0 to AVRCP_VOLUME_MAX, the device's
//! loudest, in a byte's lower seven bits: set on the target with
//! SetAbsoluteVolume, a CONTROL, whose ACCEPTED response holds the volume
//! it took; followed with RegisterNotification of
//! AVRCP_EVENT_VOLUME_CHANGED, a NOTIFY, whose INTERIM response holds the
//! volume now and whose CHANGED response comes once the device changes it,
//! the event registered again after each. GetCapabilities with
//! AVRCP_CAPABILITY_EVENTS lists the events a target has.

/// The services' classes (BTService.class16): a target's record; the
/// profile, which a controller's record names as well as its own class.
pub const UUID_REMOTE_CONTROL_TARGET: u16 = 0x110C;
pub const UUID_REMOTE_CONTROL: u16 = 0x110E;
pub const UUID_REMOTE_CONTROL_CONTROLLER: u16 = 0x110F;
/// The protocol a record names after L2CAP.
pub const UUID_AVCTP: u16 = 0x0017;

/// The versions a record names: AVCTP's after its UUID, the profile's
/// after UUID_REMOTE_CONTROL - 1.3 and 1.4, which has absolute volume.
pub const AVCTP_VERSION: u16 = 0x0103;
pub const AVRCP_VERSION: u16 = 0x0104;

/// A record's supported features (avdtp.ATTR_SUPPORTED_FEATURES, the same
/// attribute): the categories of target a controller controls, or a
/// target is - a player, an amplifier with its volume, a tuner, a menu.
pub const AVRCP_CATEGORY_PLAYER: u16 = 1 << 0;
pub const AVRCP_CATEGORY_AMPLIFIER: u16 = 1 << 1;
pub const AVRCP_CATEGORY_TUNER: u16 = 1 << 2;
pub const AVRCP_CATEGORY_MENU: u16 = 1 << 3;

/// AVCTP's first byte: the label's place, the packet types, a response,
/// a profile the device has not got.
pub const AVCTP_LABEL_SHIFT = 4;
pub const AVCTP_PACKET_SINGLE: u8 = 0 << 2;
pub const AVCTP_PACKET_START: u8 = 1 << 2;
pub const AVCTP_PACKET_CONTINUE: u8 = 2 << 2;
pub const AVCTP_PACKET_END: u8 = 3 << 2;
pub const AVCTP_PACKET_MASK: u8 = 3 << 2;
pub const AVCTP_RESPONSE: u8 = 1 << 1;
pub const AVCTP_IPID: u8 = 1 << 0;
/// The bytes of a single packet's header: the first byte and the PID.
pub const AVCTP_HEADER = 3;
/// The profile's identifier in the header.
pub const AVRCP_PID: u16 = UUID_REMOTE_CONTROL;

/// AV/C's command types.
pub const AVC_CTYPE_CONTROL: u8 = 0x0;
pub const AVC_CTYPE_STATUS: u8 = 0x1;
pub const AVC_CTYPE_NOTIFY: u8 = 0x3;
/// AV/C's response types.
pub const AVC_RESPONSE_NOT_IMPLEMENTED: u8 = 0x8;
pub const AVC_RESPONSE_ACCEPTED: u8 = 0x9;
pub const AVC_RESPONSE_REJECTED: u8 = 0xA;
pub const AVC_RESPONSE_STABLE: u8 = 0xC;
pub const AVC_RESPONSE_CHANGED: u8 = 0xD;
pub const AVC_RESPONSE_INTERIM: u8 = 0xF;
/// The type's bits of the first byte.
pub const AVC_TYPE_MASK: u8 = 0x0F;
/// The subunit every frame of the profile names: a panel, its ID 0.
pub const AVC_SUBUNIT_PANEL: u8 = 0x09 << 3;
/// The opcodes.
pub const AVC_OP_VENDOR_DEPENDENT: u8 = 0x00;
pub const AVC_OP_UNIT_INFO: u8 = 0x30;
pub const AVC_OP_SUBUNIT_INFO: u8 = 0x31;
pub const AVC_OP_PASS_THROUGH: u8 = 0x7C;
/// The bytes of an AV/C frame's header: the type, the subunit, the opcode.
pub const AVC_HEADER = 3;

/// The profile's commands after the opcode: the company ID, the PDU, the
/// packet type and the parameters' length - this many bytes.
pub const AVRCP_COMPANY_ID = [3]u8{ 0x00, 0x19, 0x58 };
pub const AVRCP_PDU_HEADER = 7;
pub const AVRCP_PACKET_SINGLE: u8 = 0;
pub const AVRCP_PACKET_MASK: u8 = 3;
/// The PDUs.
pub const AVRCP_PDU_GET_CAPABILITIES: u8 = 0x10;
pub const AVRCP_PDU_REGISTER_NOTIFICATION: u8 = 0x31;
pub const AVRCP_PDU_SET_ABSOLUTE_VOLUME: u8 = 0x50;
/// What GetCapabilities asks for: the company IDs a target has, or the
/// events.
pub const AVRCP_CAPABILITY_COMPANY_ID: u8 = 0x02;
pub const AVRCP_CAPABILITY_EVENTS: u8 = 0x03;
/// The events a controller registers for.
pub const AVRCP_EVENT_PLAYBACK_STATUS_CHANGED: u8 = 0x01;
pub const AVRCP_EVENT_TRACK_CHANGED: u8 = 0x02;
pub const AVRCP_EVENT_VOLUME_CHANGED: u8 = 0x0D;
/// The loudest absolute volume; a volume's highest bit is reserved.
pub const AVRCP_VOLUME_MAX: u8 = 0x7F;

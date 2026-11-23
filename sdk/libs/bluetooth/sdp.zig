// SPDX-License-Identifier: MIT
//! The Service Discovery Protocol's numbers: its requests and answers,
//! its errors, the data elements a record is made of, the attributes and
//! UUIDs the library reads. The layout is the Bluetooth Core
//! Specification's (volume 3, part B); unlike L2CAP's, every field is
//! big-endian.
//!
//! **A PDU** - on a channel to PSM 1 - is its id (1 byte), a
//! transaction id its answer repeats (2 bytes), its parameters' length
//! (2 bytes) and the parameters. A request that is answered in parts
//! ends with a continuation state, its length first (1 byte, 0 for
//! none): the next request repeats the state its answer ended with.
//!
//! **A data element** is a descriptor (1 byte: its type in the upper 5
//! bits, its size index in the lower 3), then for the size indexes 5, 6
//! and 7 its length in 1, 2 or 4 bytes, then its data. Size indexes 0 to
//! 4 are 1, 2, 4, 8 and 16 bytes of data; NIL has none. **A record** is a
//! sequence of attribute ids (each a 16-bit unsigned integer) each
//! followed by its value, the ids rising.

/// A PDU's header: id, transaction id, length.
pub const SDP_HDR: usize = 5;

/// The PDUs.
pub const SDP_ERROR_RESPONSE: u8 = 0x01;
pub const SDP_SERVICE_SEARCH_REQUEST: u8 = 0x02;
pub const SDP_SERVICE_SEARCH_RESPONSE: u8 = 0x03;
pub const SDP_SERVICE_ATTRIBUTE_REQUEST: u8 = 0x04;
pub const SDP_SERVICE_ATTRIBUTE_RESPONSE: u8 = 0x05;
pub const SDP_SERVICE_SEARCH_ATTRIBUTE_REQUEST: u8 = 0x06;
pub const SDP_SERVICE_SEARCH_ATTRIBUTE_RESPONSE: u8 = 0x07;

/// SDP_ERROR_RESPONSE's codes.
pub const SDP_ERR_UNSUPPORTED_VERSION: u16 = 0x0001;
pub const SDP_ERR_INVALID_HANDLE: u16 = 0x0002;
pub const SDP_ERR_INVALID_SYNTAX: u16 = 0x0003;
pub const SDP_ERR_INVALID_PDU_SIZE: u16 = 0x0004;
pub const SDP_ERR_INVALID_CONTINUATION: u16 = 0x0005;
pub const SDP_ERR_INSUFFICIENT_RESOURCES: u16 = 0x0006;

/// The longest continuation state, its length byte besides.
pub const SDP_CONTINUATION_MOST: usize = 16;
/// The most UUIDs a search pattern holds.
pub const SDP_PATTERN_MOST: usize = 12;

/// A data element's types (the descriptor's upper 5 bits).
pub const DE_NIL: u8 = 0;
pub const DE_UINT: u8 = 1;
pub const DE_INT: u8 = 2;
pub const DE_UUID: u8 = 3;
pub const DE_TEXT: u8 = 4;
pub const DE_BOOL: u8 = 5;
pub const DE_SEQUENCE: u8 = 6;
pub const DE_ALTERNATIVE: u8 = 7;
pub const DE_URL: u8 = 8;
/// Its size indexes (the lower 3 bits) whose length follows the
/// descriptor, in 1, 2 or 4 bytes.
pub const DE_SIZE_LENGTH8: u8 = 5;
pub const DE_SIZE_LENGTH16: u8 = 6;
pub const DE_SIZE_LENGTH32: u8 = 7;

/// The attributes every record may have.
pub const ATTR_SERVICE_RECORD_HANDLE: u16 = 0x0000;
pub const ATTR_SERVICE_CLASS_ID_LIST: u16 = 0x0001;
pub const ATTR_SERVICE_RECORD_STATE: u16 = 0x0002;
pub const ATTR_SERVICE_ID: u16 = 0x0003;
pub const ATTR_PROTOCOL_DESCRIPTOR_LIST: u16 = 0x0004;
pub const ATTR_BROWSE_GROUP_LIST: u16 = 0x0005;
pub const ATTR_LANGUAGE_BASE_LIST: u16 = 0x0006;
pub const ATTR_PROFILE_DESCRIPTOR_LIST: u16 = 0x0009;
/// The primary language's name of the service, at the language base
/// 0x0100.
pub const ATTR_SERVICE_NAME: u16 = 0x0100;
/// The SDP server's record's: the versions it speaks, and a number that
/// changes with its records.
pub const ATTR_VERSION_NUMBER_LIST: u16 = 0x0200;
pub const ATTR_SERVICE_DATABASE_STATE: u16 = 0x0201;

/// The SDP server's own record's handle.
pub const SDP_SERVER_HANDLE: u32 = 0x0000_0000;
/// The version of the protocol: 1.1.
pub const SDP_VERSION: u16 = 0x0100;

/// UUIDs of 16 bits: the protocols.
pub const UUID_SDP: u16 = 0x0001;
pub const UUID_RFCOMM: u16 = 0x0003;
pub const UUID_L2CAP: u16 = 0x0100;
/// And the classes the library's own record names.
pub const UUID_SERVICE_DISCOVERY_SERVER: u16 = 0x1000;
pub const UUID_PUBLIC_BROWSE_ROOT: u16 = 0x1002;

/// The base a UUID of 16 or 32 bits stands for, big-endian: the shorter
/// one's value in its first four bytes.
pub const BASE_UUID = [16]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB };

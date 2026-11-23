// SPDX-License-Identifier: MIT
//! The attribute protocol's numbers and GATT's: the PDUs a client and a
//! server exchange, their errors, the declarations a server's attributes
//! are grouped by, the descriptors and the characteristics the library
//! reads and keeps. The layout is the Bluetooth Core Specification's
//! (volume 3, parts F and G); every field is little-endian, a UUID too.
//!
//! **A PDU** - on LE's fixed channel l2cap.CID_ATT - is its opcode (1
//! byte) and its parameters, the whole of it at most the bearer's MTU:
//! ATT_MTU_DEFAULT until the two have exchanged theirs, then the smaller
//! of the two. A client has one request out at a time and the server
//! answers it, with the request's answer or ATT_ERROR_RSP; a
//! notification wants no answer, an indication its confirmation.
//!
//! **A server's attributes** each have a handle (1 to 0xFFFF), a type (a
//! UUID) and a value. A service is a declaration (GATT_PRIMARY_SERVICE,
//! its value the service's UUID) and the attributes up to the next one; a
//! characteristic is a declaration (GATT_CHARACTERISTIC: its properties,
//! its value's handle, its UUID), its value, and its descriptors up to
//! the next declaration.

/// The most an ATT PDU carries until the two have exchanged their MTUs,
/// over LE.
pub const ATT_MTU_DEFAULT: u16 = 23;
/// The longest value an attribute has.
pub const ATT_VALUE_MOST: u16 = 512;

/// The PDUs, by opcode: each request and its answer, the commands, the
/// notifications and indications.
pub const ATT_ERROR_RSP: u8 = 0x01;
pub const ATT_EXCHANGE_MTU_REQ: u8 = 0x02;
pub const ATT_EXCHANGE_MTU_RSP: u8 = 0x03;
pub const ATT_FIND_INFORMATION_REQ: u8 = 0x04;
pub const ATT_FIND_INFORMATION_RSP: u8 = 0x05;
pub const ATT_FIND_BY_TYPE_VALUE_REQ: u8 = 0x06;
pub const ATT_FIND_BY_TYPE_VALUE_RSP: u8 = 0x07;
pub const ATT_READ_BY_TYPE_REQ: u8 = 0x08;
pub const ATT_READ_BY_TYPE_RSP: u8 = 0x09;
pub const ATT_READ_REQ: u8 = 0x0A;
pub const ATT_READ_RSP: u8 = 0x0B;
pub const ATT_READ_BLOB_REQ: u8 = 0x0C;
pub const ATT_READ_BLOB_RSP: u8 = 0x0D;
pub const ATT_READ_MULTIPLE_REQ: u8 = 0x0E;
pub const ATT_READ_MULTIPLE_RSP: u8 = 0x0F;
pub const ATT_READ_BY_GROUP_TYPE_REQ: u8 = 0x10;
pub const ATT_READ_BY_GROUP_TYPE_RSP: u8 = 0x11;
pub const ATT_WRITE_REQ: u8 = 0x12;
pub const ATT_WRITE_RSP: u8 = 0x13;
pub const ATT_PREPARE_WRITE_REQ: u8 = 0x16;
pub const ATT_PREPARE_WRITE_RSP: u8 = 0x17;
pub const ATT_EXECUTE_WRITE_REQ: u8 = 0x18;
pub const ATT_EXECUTE_WRITE_RSP: u8 = 0x19;
pub const ATT_HANDLE_VALUE_NTF: u8 = 0x1B;
pub const ATT_HANDLE_VALUE_IND: u8 = 0x1D;
pub const ATT_HANDLE_VALUE_CFM: u8 = 0x1E;
pub const ATT_READ_MULTIPLE_VARIABLE_REQ: u8 = 0x20;
pub const ATT_READ_MULTIPLE_VARIABLE_RSP: u8 = 0x21;
pub const ATT_MULTIPLE_HANDLE_VALUE_NTF: u8 = 0x23;
pub const ATT_WRITE_CMD: u8 = 0x52;
pub const ATT_SIGNED_WRITE_CMD: u8 = 0xD2;

/// ATT_ERROR_RSP's reasons.
pub const ATT_ERR_INVALID_HANDLE: u8 = 0x01;
pub const ATT_ERR_READ_NOT_PERMITTED: u8 = 0x02;
pub const ATT_ERR_WRITE_NOT_PERMITTED: u8 = 0x03;
pub const ATT_ERR_INVALID_PDU: u8 = 0x04;
pub const ATT_ERR_INSUFFICIENT_AUTHENTICATION: u8 = 0x05;
pub const ATT_ERR_REQUEST_NOT_SUPPORTED: u8 = 0x06;
pub const ATT_ERR_INVALID_OFFSET: u8 = 0x07;
pub const ATT_ERR_INSUFFICIENT_AUTHORIZATION: u8 = 0x08;
pub const ATT_ERR_PREPARE_QUEUE_FULL: u8 = 0x09;
pub const ATT_ERR_ATTRIBUTE_NOT_FOUND: u8 = 0x0A;
pub const ATT_ERR_ATTRIBUTE_NOT_LONG: u8 = 0x0B;
pub const ATT_ERR_ENCRYPTION_KEY_SIZE: u8 = 0x0C;
pub const ATT_ERR_INVALID_VALUE_LENGTH: u8 = 0x0D;
pub const ATT_ERR_UNLIKELY: u8 = 0x0E;
pub const ATT_ERR_INSUFFICIENT_ENCRYPTION: u8 = 0x0F;
pub const ATT_ERR_UNSUPPORTED_GROUP_TYPE: u8 = 0x10;
pub const ATT_ERR_INSUFFICIENT_RESOURCES: u8 = 0x11;
pub const ATT_ERR_DATABASE_OUT_OF_SYNC: u8 = 0x12;
pub const ATT_ERR_VALUE_NOT_ALLOWED: u8 = 0x13;

/// ATT_FIND_INFORMATION_RSP's format: its UUIDs of 16 bits, or of 128.
pub const ATT_FORMAT_UUID16: u8 = 0x01;
pub const ATT_FORMAT_UUID128: u8 = 0x02;

/// The services every LE device has: GAP's and GATT's.
pub const GATT_SERVICE_GAP: u16 = 0x1800;
pub const GATT_SERVICE_GATT: u16 = 0x1801;

/// The declarations a server's attributes are grouped by.
pub const GATT_PRIMARY_SERVICE: u16 = 0x2800;
pub const GATT_SECONDARY_SERVICE: u16 = 0x2801;
pub const GATT_INCLUDE: u16 = 0x2802;
pub const GATT_CHARACTERISTIC: u16 = 0x2803;

/// A characteristic's descriptors.
pub const GATT_EXTENDED_PROPERTIES: u16 = 0x2900;
pub const GATT_USER_DESCRIPTION: u16 = 0x2901;
/// The Client Characteristic Configuration: GATT_CCC_* - whether the
/// characteristic's value is notified to this client, or indicated.
pub const GATT_CLIENT_CONFIGURATION: u16 = 0x2902;
pub const GATT_SERVER_CONFIGURATION: u16 = 0x2903;
pub const GATT_PRESENTATION_FORMAT: u16 = 0x2904;
pub const GATT_AGGREGATE_FORMAT: u16 = 0x2905;
/// HID's: which report a characteristic is, and of which kind.
pub const GATT_REPORT_REFERENCE: u16 = 0x2908;

/// GATT_CLIENT_CONFIGURATION's bits.
pub const GATT_CCC_NOTIFY: u16 = 0x0001;
pub const GATT_CCC_INDICATE: u16 = 0x0002;

/// The characteristics of GAP's and GATT's services the library serves:
/// the device's name (UTF-8), its appearance (16 bits), and the range
/// of handles whose attributes changed.
pub const GATT_DEVICE_NAME: u16 = 0x2A00;
pub const GATT_APPEARANCE: u16 = 0x2A01;
pub const GATT_SERVICE_CHANGED: u16 = 0x2A05;

/// A characteristic's properties, its declaration's first byte: what a
/// client may do with its value.
pub const GATT_PROP_BROADCAST: u8 = 0x01;
pub const GATT_PROP_READ: u8 = 0x02;
pub const GATT_PROP_WRITE_NO_RESPONSE: u8 = 0x04;
pub const GATT_PROP_WRITE: u8 = 0x08;
pub const GATT_PROP_NOTIFY: u8 = 0x10;
pub const GATT_PROP_INDICATE: u8 = 0x20;
pub const GATT_PROP_SIGNED_WRITE: u8 = 0x40;
pub const GATT_PROP_EXTENDED: u8 = 0x80;

/// The appearances (GAP's 0x2A01, LE advertising's AD_APPEARANCE): a
/// category in the upper ten bits, a kind of it in the lower six.
pub const APPEARANCE_COMPUTER: u16 = 0x0080;
pub const APPEARANCE_DESKTOP: u16 = 0x0081;
pub const APPEARANCE_KEYBOARD: u16 = 0x03C1;
pub const APPEARANCE_MOUSE: u16 = 0x03C2;

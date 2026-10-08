// SPDX-License-Identifier: MIT
//! slip.device: IP over a serial line (RFC 1055), as a network device
//! (network.zig) whose frames are the packets themselves - IPv4 or IPv6,
//! told apart by their version - between two ends that have no addresses
//! on the link. S2_DEVICEQUERY says `S2WireType_SLIP`, an address of 0
//! bits and an MTU of `SLIP_MTU`.
//!
//! **The line** is the one the first opener of a unit names, in the tag
//! list OpenDevice is handed in ios2_BufferManagement beside
//! S2_CopyToBuff: a device with serial.device's API, its unit and its
//! speed. Later openers of the unit share that line, and what their tags
//! say of it counts for nothing. AddInterfaceTagList hands these tags on
//! from IFA_DeviceTags; an interface file says them as `SerialDevice`,
//! `SerialUnit` and `Baud`. The line is opened at the unit's first
//! OpenDevice - which fails if it does not open - and given back at its
//! last CloseDevice.

const TAG_USER = @import("../libs/utility/tagitem.zig").TAG_USER;

/// The device's name, for OpenDevice.
pub const SLIPNAME = "networks/slip.device";

/// The units: a line each.
pub const SLIP_UNITS = 2;

/// The most bytes one packet carries, RFC 1055's.
pub const SLIP_MTU: u32 = 1006;

/// The tags of ios2_BufferManagement at OpenDevice that name the line.
pub const SLIP_Dummy: u32 = TAG_USER + 0xB5000;
/// ti_Data: the serial device, a C string; "serial.device" unless given.
pub const SLIP_SerialDevice: u32 = SLIP_Dummy + 1;
/// ti_Data: its unit; 1 unless given.
pub const SLIP_SerialUnit: u32 = SLIP_Dummy + 2;
/// ti_Data: the line's speed in bits per second; 115200 unless given.
pub const SLIP_Baud: u32 = SLIP_Dummy + 3;

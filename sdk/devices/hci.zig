// SPDX-License-Identifier: MIT
//! A Bluetooth controller (`DEVIF_HCI`): a device whose unit is one
//! controller, spoken to in HCI packets - commands and data out, events
//! and data in - whatever carries them, USB or a UART. bluetooth.library
//! opens each such unit and is its one user; the HCI itself - the
//! commands, the events, their numbers - is `sdk.bluetooth.hci`.
//!
//! **A request is one packet**: an `IOHciReq` whose `packet_type` says
//! which kind (HCI_COMMAND_PKT, HCI_ACLDATA_PKT, ...), and whose io_Data
//! holds the packet from its own header on - a command's opcode, an
//! event's code, an ACL packet's handle - without the framing its
//! transport adds (a UART's type byte). CMD_WRITE sends one. CMD_READ
//! takes the next one the controller sent, whatever its kind, and says
//! which in `packet_type`; it waits until one comes. Several reads may be
//! queued, and are answered in the order they came. A packet longer than
//! a read's io_Length is kept for the next read: this one is answered
//! HCIERR_TOOLONG, with io_Actual the length the packet needs.
//!
//! **The unit opens once its controller is ready** - its firmware in, its
//! line at the rate it works at, its address its own - so that every
//! controller looks alike from the stack: what getting there takes is the
//! device's. A controller that goes away, unplugged, answers every request
//! HCIERR_DETACHED from then on, and those it held are answered so too.
//! A controller on the board (PARTKIND_BLUETOOTH) is set up from the time
//! its device is loaded: opened before it is ready, its unit answers
//! HCIERR_NOTREADY, and the device offers it to the stack itself
//! (AddBTController) once it is - or once it could not be, its unit
//! answering IOERR_OPENFAIL from then on.
//!
//! The commands:
//!
//!   CMD_READ      the next packet the controller sent: io_Data, io_Length
//!                 the room for it; io_Actual its length, packet_type its
//!                 kind.
//!   CMD_WRITE     a packet sent: io_Data, io_Length, packet_type.
//!                 Answered once the transport has taken it - a command's
//!                 answer is an event of its own, read like any other.
//!   CMD_FLUSH     every read waiting answered IOERR_ABORTED.
//!   HCICMD_QUERY  io_Data an `HCIInfo`, filled in: how the controller is
//!                 reached and what the device knows of it. Answered at
//!                 once, in the caller's task: the stack asks it while the
//!                 device's own task may be waiting for the stack.

const exec = @import("../libs/exec/exec.zig");

/// The kinds of HCI packet, as `packet_type` says them (and as a UART's
/// type byte does).
pub const HCI_COMMAND_PKT: u8 = 0x01;
pub const HCI_ACLDATA_PKT: u8 = 0x02;
pub const HCI_SCODATA_PKT: u8 = 0x03;
pub const HCI_EVENT_PKT: u8 = 0x04;
pub const HCI_ISODATA_PKT: u8 = 0x05;

/// What a controller's unit is asked: one packet, out or in.
pub const IOHciReq = extern struct {
    /// io_Data and io_Length: the packet, or the room for one; io_Actual
    /// the bytes moved.
    std: exec.IOStdReq = .{},
    /// HCI_*_PKT: what CMD_WRITE sends, what CMD_READ took.
    packet_type: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
};

/// The command beside exec's that a controller's unit takes.
pub const HCICMD_QUERY: u16 = exec.CMD_NONSTD;

/// HCIInfo.bus: how the controller is reached.
pub const HCIBUS_USB: u32 = 1;
pub const HCIBUS_UART: u32 = 2;

/// What HCICMD_QUERY fills in.
pub const HCIInfo = extern struct {
    /// HCIBUS_*.
    bus: u32 = 0,
    /// The line's rate in bits a second for a UART; 0 for USB.
    baud: u32 = 0,
    /// The chip, as the device knows it ("MediaTek MT7922"); null when it
    /// does not. The device's, as long as the unit is open.
    chip: ?[*:0]const u8 = null,
    /// The firmware the device gave the controller - its file and its
    /// build - or null for none.
    firmware: ?[*:0]const u8 = null,
};

// The device's own errors in io_Error, beside exec's IOERR_*.
/// A read too short for the packet waiting; io_Actual is what it needs.
pub const HCIERR_TOOLONG: i8 = 1;
/// The controller has gone.
pub const HCIERR_DETACHED: i8 = 2;
/// A packet kind the transport does not carry, or a packet too long for
/// it.
pub const HCIERR_PACKET: i8 = 3;
/// The transport could not send the packet.
pub const HCIERR_SEND: i8 = 4;
/// The unit's controller is being set up: its device offers it with
/// AddBTController once it is ready.
pub const HCIERR_NOTREADY: i8 = 5;

// SPDX-License-Identifier: MIT
//! rs485.device: the board's RS-485 port, in frames. It is in DEVS: and
//! exists only on a board that has the port; unit 0 is the port. A unit
//! is exclusive: a second OpenDevice fails with RS485ERR_DEVBUSY.
//!
//! What goes over the wire is frames: bytes sent one after the other,
//! each frame ended by the line being quiet. The device keeps to that
//! both ways, so a protocol on top sees whole frames and never a byte
//! stream to cut up.
//!
//!   CMD_WRITE           io_Length bytes from io_Data as one frame. It is
//!                       replied once the last bit is on the wire, so
//!                       the line is free when the caller hears back.
//!   CMD_READ            one frame into io_Data, at most io_Length bytes;
//!                       io_Actual is its length. It waits for a whole
//!                       frame - one that ended with the line quiet for
//!                       the unit's gap - for `timeout` µs, or for ever
//!                       when that is 0. Frames that come in while no
//!                       read waits are kept, oldest first, for the reads
//!                       to come.
//!   CMD_CLEAR           drops the frames no read has taken yet.
//!   CMD_FLUSH           aborts the reads that wait (IOERR_ABORTED).
//!   RS485CMD_SETPARAMS  the line and the gap from the request: rate,
//!                       data bits, parity, stop bits, gap.
//!   RS485CMD_QUERY      the line and the gap into the request; io_Actual
//!                       is the frames kept.
//!
//! The port is half-duplex: while the device sends, it hears nothing, so
//! its own frame never comes back as one received.
//!
//! A request that has to wait needs a reply port; without one it fails
//! with IOERR_NOREPLYPORT.

const exec = @import("../libs/exec/exec.zig");

/// The device's name, for OpenDevice.
pub const RS485NAME = "rs485.device";

/// The longest frame the device sends or keeps, in bytes.
pub const RS485_MAX_FRAME: u32 = 512;

/// IORS485: an IOStdReq with the port's parameters. OpenDevice fills the
/// parameters in; RS485CMD_SETPARAMS takes them from it.
pub const IORS485 = extern struct {
    /// The standard request: io_Data, io_Length, io_Actual.
    std: exec.IOStdReq = .{},
    /// CMD_READ: how long to wait for a whole frame, in µs; 0 for ever.
    timeout: u32 = 0,
    /// Bits per second.
    baud: u32 = 0,
    /// The quiet time that ends a frame, in tenths of a character: 35 is
    /// three and a half characters. At most 1023 bit times.
    gap: u32 = 0,
    /// Data bits, 5 to 8.
    data_bits: u8 = 0,
    /// RS485_PARITY_*.
    parity: u8 = 0,
    /// 1 or 2.
    stop_bits: u8 = 0,
    pad: u8 = 0,
};

/// IORS485.parity.
pub const RS485_PARITY_NONE: u8 = 0;
pub const RS485_PARITY_EVEN: u8 = 1;
pub const RS485_PARITY_ODD: u8 = 2;

/// The line a unit has when it is first opened: 9600 8N1, a gap of 3.5
/// characters.
pub const RS485_DEFAULT_BAUD: u32 = 9600;
pub const RS485_DEFAULT_GAP: u32 = 35;

/// The device's own commands.
pub const RS485CMD_SETPARAMS: u16 = exec.CMD_NONSTD + 0;
pub const RS485CMD_QUERY: u16 = exec.CMD_NONSTD + 1;

/// io_Error: the device's own errors.
/// The unit is open already.
pub const RS485ERR_DEVBUSY: i8 = 1;
/// SETPARAMS asked for a line or gap the port cannot have.
pub const RS485ERR_BADPARAMS: i8 = 2;
/// CMD_READ waited its time-out and no whole frame came.
pub const RS485ERR_TIMEOUT: i8 = 3;
/// The frame was longer than io_Length (or RS485_MAX_FRAME): io_Actual
/// bytes of it are in io_Data, the rest is gone.
pub const RS485ERR_OVERFLOW: i8 = 4;
/// A character of the frame came with a wrong parity bit.
pub const RS485ERR_PARITY: i8 = 5;
/// A character of the frame had no stop bit where it belonged.
pub const RS485ERR_FRAMING: i8 = 6;
/// CMD_WRITE: io_Length is 0 or past RS485_MAX_FRAME.
pub const RS485ERR_BADLENGTH: i8 = 7;

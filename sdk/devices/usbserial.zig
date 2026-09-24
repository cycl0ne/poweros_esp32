// SPDX-License-Identifier: MIT
//! usbserial.device: the USB-Serial-JTAG port as a serial line, with
//! serial.device's API (sdk/devices/serial.zig: IOExtSer, the commands,
//! io_Status, the errors) on one unit, 0.
//!
//! The port has no line of its own: SDCMD_SETPARAMS keeps the parameters
//! (the buffer size and termination characters count), SDCMD_BREAK is
//! IOERR_NOCMD, and io_Status's lines are always active.

/// The device's name, for OpenDevice.
pub const USBSERIALNAME = "usbserial.device";

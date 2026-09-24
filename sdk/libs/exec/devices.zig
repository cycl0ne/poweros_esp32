// SPDX-License-Identifier: MIT
//! Devices and I/O requests (exec/devices.h, exec/io.h, exec/errors.h). A
//! device is a library on the device list with two more standard vectors,
//! BeginIO and AbortIO. It is opened with an IORequest: OpenDevice fills
//! in io_Device, and the device's Open vector picks the unit (io_Unit).
//!
//!   jump table: Open, Close, Expunge, ExtFunc, BeginIO, AbortIO, ...

const libraries = @import("libraries.zig");
const ports = @import("ports.zig");

/// struct Device: a Library with ln_Type NT_DEVICE.
pub const Device = libraries.Library;

/// Vectors after Open, Close, Expunge and ExtFunc.
pub const DEV_BEGINIO = libraries.lvo(4);
pub const DEV_ABORTIO = libraries.lvo(5);
/// First device-specific vector.
pub const DEV_USERDEF = libraries.lvo(6);
pub const standard_vectors = 6;

/// io_Error
pub const IOERR_OPENFAIL: i8 = -1;
pub const IOERR_ABORTED: i8 = -2;
pub const IOERR_NOCMD: i8 = -3;
pub const IOERR_BADLENGTH: i8 = -4;
pub const IOERR_BADADDRESS: i8 = -5;
pub const IOERR_UNITBUSY: i8 = -6;
pub const IOERR_SELFTEST: i8 = -7;
/// WaitIO on a request without a reply port.
pub const IOERR_NOREPLYPORT: i8 = -8;

/// io_Command: the standard commands.
pub const CMD_INVALID: u16 = 0;
pub const CMD_RESET: u16 = 1;
pub const CMD_READ: u16 = 2;
pub const CMD_WRITE: u16 = 3;
pub const CMD_UPDATE: u16 = 4;
pub const CMD_CLEAR: u16 = 5;
pub const CMD_STOP: u16 = 6;
pub const CMD_START: u16 = 7;
pub const CMD_FLUSH: u16 = 8;
/// First device-specific command.
pub const CMD_NONSTD: u16 = 9;

/// io_Flags: the caller can take the result without a reply message.
pub const IOF_QUICK: u8 = 1 << 0;
// A device that keeps a queue of requests marks each one with where it
// stands. They are the device's own bookkeeping - a caller sets none of
// them and reads none of them - but they live here because every queued
// device wants the same four, and because AbortIO has to be able to tell
// a request that has already finished from one that has not.
/// Waiting behind another request on the unit's list.
pub const IOF_QUEUED: u8 = 1 << 4;
/// At the head of the list: this is the request the hardware is on.
pub const IOF_CURRENT: u8 = 1 << 5;
/// Being worked on, for a device that can be re-entered while it works.
pub const IOF_SERVICING: u8 = 1 << 6;
/// Finished. Set once, so ending a request twice (a reply racing an
/// AbortIO) does nothing the second time.
pub const IOF_DONE: u8 = 1 << 7;

/// unit_flags
pub const UNITF_ACTIVE: u8 = 1 << 0;
pub const UNITF_INTASK: u8 = 1 << 1;

/// struct Unit: a device's unit, with a port for its queued requests.
pub const Unit = extern struct {
    /// unit_MsgPort
    msg_port: ports.MsgPort = .{},
    /// unit_flags: UNITF_ACTIVE, UNITF_INTASK.
    flags: u8 = 0,
    pad: u8 = 0,
    /// unit_OpenCnt
    open_cnt: u16 = 0,
};

/// struct IORequest: a message to a device.
pub const IORequest = extern struct {
    /// io_Message: its reply port gets the request back when it is done.
    message: ports.Message = .{},
    /// io_Device: set by OpenDevice; null when not open.
    device: ?*Device = null,
    /// io_Unit: set by the device's Open.
    unit: ?*Unit = null,
    /// io_Command
    command: u16 = 0,
    /// io_Flags: IOF_QUICK, device flags.
    flags: u8 = 0,
    /// io_Error: 0 or an IOERR_* / device error.
    err: i8 = 0,
};

/// struct IOStdReq: an IORequest with the standard data fields.
pub const IOStdReq = extern struct {
    req: IORequest = .{},
    /// io_Actual: bytes transferred. 64 bits.
    actual: u64 align(4) = 0,
    /// io_Length: bytes requested. 64 bits.
    length: u64 align(4) = 0,
    /// io_Data
    data: ?*anyopaque = null,
    /// io_Offset: where on the medium, in bytes for block devices. 64 bits,
    /// so a medium may be larger than 4 GiB.
    offset: u64 align(4) = 0,
};

/// The device's Open vector: sets io.unit and returns 0, or returns an
/// error (IOERR_* or the device's own), which OpenDevice passes on.
pub const DevOpenFn = *const fn (dev: *Device, io: *IORequest, unit: u32, flags: u32) callconv(.c) i32;
/// The device's Close vector; returns a seglist to unload after an
/// expunge, else null.
pub const DevCloseFn = *const fn (dev: *Device, io: *IORequest) callconv(.c) ?*anyopaque;
pub const BeginIOFn = *const fn (dev: *Device, io: *IORequest) callconv(.c) void;
pub const AbortIOFn = *const fn (dev: *Device, io: *IORequest) callconv(.c) i32;

// SPDX-License-Identifier: MIT
//! i2c.device: the two I2C controllers as units 0 and 1.
//!
//! A request is an `IOExtI2C`: an `IOStdReq` with the slave's address and,
//! for the combined command, a second buffer. `io_Offset` is not used - a
//! device on an I2C bus has no medium and no position.
//!
//! The commands that move bytes on the bus:
//!
//!   CMD_WRITE          START, the address with the write bit, io_Length
//!                      bytes from io_Data, STOP.
//!   CMD_READ           START, the address with the read bit, io_Length
//!                      bytes into io_Data, STOP. The last byte is left
//!                      unacknowledged, as the bus asks.
//!   I2CCMD_WRITEREAD   the two in one go: io_WrLength bytes from io_WrData,
//!                      a repeated START, then io_Length bytes into
//!                      io_Data, STOP. It is one request so that nothing
//!                      else can take the bus in between - which is what
//!                      reading a register out of a chip needs.
//!
//! and the ones that do not:
//!
//!   I2CCMD_PROBE       START, the address, STOP. io_Actual is 1 if
//!                      something answered and 0 if nothing did. A silent
//!                      address is an answer, not a failure, so io_Error
//!                      stays 0 and a scan is a plain loop.
//!   I2CCMD_SETPARAMS   io_Speed and the two pins become the unit's, and
//!                      the controller is set up again.
//!   I2CCMD_GETPARAMS   the unit's speed and pins into the same fields.
//!   CMD_CLEAR          free a bus a slave is holding: nine SCL pulses and
//!                      a STOP, then the controller is set up again.
//!   CMD_STOP           the unit takes requests but starts none.
//!   CMD_START          it starts them again, head of the queue first.
//!   CMD_FLUSH          every request that has not begun comes back with
//!                      IOERR_ABORTED.
//!   CMD_RESET          stop, flush, start, and the controller set up
//!                      again with the unit's own parameters.
//!
//! The four that use the bus - the three above and PROBE - wait on the
//! unit's queue, one at a time, and the queue is what keeps two callers
//! from interleaving on the wire. The rest are done in BeginIO and come
//! straight back.
//!
//! Addresses are 7-bit. A unit takes SCL and SDA on any two pads;
//! unit 0 comes up on the pair the board's own bus is wired to and unit 1
//! comes up with none, so it answers a bus command with I2CErr_InvParam
//! until SETPARAMS gives it a pair.

const devices = @import("../libs/exec/devices.zig");

pub const DEVICE_NAME = "i2c.device";

/// The controllers, and so the unit numbers.
pub const UNIT_COUNT: u32 = 2;

pub const I2CCMD_WRITEREAD: u16 = devices.CMD_NONSTD + 0;
pub const I2CCMD_PROBE: u16 = devices.CMD_NONSTD + 1;
pub const I2CCMD_SETPARAMS: u16 = devices.CMD_NONSTD + 2;
pub const I2CCMD_GETPARAMS: u16 = devices.CMD_NONSTD + 3;

/// io_Error values of i2c.device, past exec's (which are negative).
/// No slave acknowledged the address, or one stopped acknowledging data.
pub const I2CErr_NoAck: i8 = 1;
/// Another master had the bus.
pub const I2CErr_ArbLost: i8 = 2;
/// A slave held SCL down past the controller's timeout.
pub const I2CErr_Timeout: i8 = 3;
/// The bus was still busy when the transfer should have started.
pub const I2CErr_BusBusy: i8 = 4;
/// A speed, an address or a pin the controller cannot have.
pub const I2CErr_InvParam: i8 = 5;

/// The lowest and highest SCL frequency a unit will take.
pub const SPEED_MIN: u32 = 1_000;
pub const SPEED_MAX: u32 = 1_000_000;
/// What a unit comes up at.
pub const SPEED_DEFAULT: u32 = 400_000;

/// A pin number that means "leave this one as it is" in SETPARAMS.
pub const PIN_KEEP: u8 = 0xFF;

/// struct IOExtI2C: a request to i2c.device.
pub const IOExtI2C = extern struct {
    /// io_Length bytes to or from io_Data; io_Actual is what moved.
    /// io_Offset is unused.
    req: devices.IOStdReq = .{},
    /// io_I2CAddress: the slave, right-aligned. A 7-bit address is 0..0x7F
    /// and holds no read/write bit - the command says which way the bytes
    /// go.
    address: u16 = 0,
    /// io_I2CFlags: no bits are defined; zero.
    flags: u16 = 0,
    /// io_WrData: what I2CCMD_WRITEREAD sends before the repeated START.
    wr_data: ?*anyopaque = null,
    /// io_WrLength: how many bytes of it.
    wr_length: u32 = 0,
    /// io_Speed: SCL in Hz, for SETPARAMS and GETPARAMS.
    speed: u32 = 0,
    /// io_SclPin: the GPIO SCL is on, for SETPARAMS and GETPARAMS.
    scl_pin: u8 = 0,
    /// io_SdaPin: the GPIO SDA is on, likewise.
    sda_pin: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
};

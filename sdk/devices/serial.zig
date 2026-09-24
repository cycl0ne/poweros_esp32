// SPDX-License-Identifier: MIT
//! serial.device (devices/serial.h): the chip's UARTs, raw, one unit per
//! UART. usbserial.device has the same API on the USB-Serial-JTAG port.
//! Every request is an IOExtSer: OpenDevice fills in the unit's
//! parameters, SDCMD_SETPARAMS takes new ones from it. A unit is
//! exclusive: a second open fails with SerErr_DevBusy, unless every opener
//! sets SERF_SHARED in io_SerFlags.
//!
//!   CMD_READ         reads io_Length bytes into io_Data; it waits for all
//!                    of them, or in EOF mode for a termination character.
//!   CMD_WRITE        writes io_Length bytes from io_Data (-1: up to a NUL),
//!                    as they are.
//!   CMD_STOP         pauses both directions: reads get no input, writes
//!                    wait.
//!   CMD_START        does the writes that waited, then serves the reads.
//!   CMD_CLEAR        drops the input that no CMD_READ took yet.
//!   CMD_FLUSH        aborts the queued requests (IOERR_ABORTED), not the
//!                    active ones.
//!   CMD_RESET        aborts all requests, clears the input, and goes back
//!                    to the boot-up parameters.
//!   SDCMD_QUERY      io_Actual: the bytes waiting; io_Status: the lines.
//!   SDCMD_BREAK      holds the line low for io_BrkTime µs.
//!   SDCMD_SETPARAMS  sets the parameters in the IOExtSer.
//!
//! A request that has to wait needs a reply port; without one it fails
//! with IOERR_NOREPLYPORT.

const exec = @import("../libs/exec/exec.zig");

/// The device's name, for OpenDevice.
pub const SERIALNAME = "serial.device";

/// The units: UART0 (the ROM's pins), UART1 and UART2 (no pins routed
/// yet).
pub const UNIT_UART0: u32 = 0;
pub const UNIT_UART1: u32 = 1;
pub const UNIT_UART2: u32 = 2;

/// io_CtlChar's default: xON 0x11, xOFF 0x13.
pub const SER_DEFAULT_CTLCHAR: u32 = 0x1113_0000;

/// struct IOExtSer: an IOStdReq with the port's parameters. Every request
/// to serial.device must be one ("you MUST use an IOExtSer-sized
/// structure"), cleared except for what the caller sets.
pub const IOExtSer = extern struct {
    /// IOSer: the standard request.
    io_ser: exec.IOStdReq = .{},
    /// io_CtlChar: xON, xOFF, INQ and ACK, from the high byte down (INQ and
    /// ACK are not used).
    ctl_char: u32 = 0,
    /// io_RBufLen: the input buffer's size in bytes, at least 64.
    rbuf_len: u32 = 0,
    /// io_ExtFlags: SEXTF_*, zero if not used.
    ext_flags: u32 = 0,
    /// io_Baud: bits per second, for reading and writing.
    baud: u32 = 0,
    /// io_BrkTime: how long SDCMD_BREAK holds the line low, in µs.
    brk_time: u32 = 0,
    /// io_TermArray: EOF mode's termination characters, in descending
    /// order, the unused ones filled out with the lowest: 8 bytes, in order.
    term_array: [8]u8 = @splat(0),
    /// io_ReadLen, io_WriteLen: bits per character, without the parity bit.
    read_len: u8 = 0,
    write_len: u8 = 0,
    /// io_StopBits
    stop_bits: u8 = 0,
    /// io_SerFlags: SERF_*.
    ser_flags: u8 = 0,
    /// io_Status: IO_STATF_*, set by SDCMD_QUERY.
    status: u16 = 0,
};

/// io_SerFlags. EOFMODE and QUEUEDBRK count per request, SHARED and 7WIRE
/// at OpenDevice, the rest only through SDCMD_SETPARAMS.
pub const SERB_XDISABLED = 7;
pub const SERF_XDISABLED: u8 = 1 << SERB_XDISABLED;
pub const SERB_EOFMODE = 6;
pub const SERF_EOFMODE: u8 = 1 << SERB_EOFMODE;
pub const SERB_SHARED = 5;
pub const SERF_SHARED: u8 = 1 << SERB_SHARED;
pub const SERB_RAD_BOOGIE = 4;
pub const SERF_RAD_BOOGIE: u8 = 1 << SERB_RAD_BOOGIE;
pub const SERB_QUEUEDBRK = 3;
pub const SERF_QUEUEDBRK: u8 = 1 << SERB_QUEUEDBRK;
pub const SERB_7WIRE = 2;
pub const SERF_7WIRE: u8 = 1 << SERB_7WIRE;
pub const SERB_PARTY_ODD = 1;
pub const SERF_PARTY_ODD: u8 = 1 << SERB_PARTY_ODD;
pub const SERB_PARTY_ON = 0;
pub const SERF_PARTY_ON: u8 = 1 << SERB_PARTY_ON;

/// io_ExtFlags: mark or space parity instead of odd or even.
pub const SEXTB_MSPON = 1;
pub const SEXTF_MSPON: u32 = 1 << SEXTB_MSPON;
pub const SEXTB_MARK = 0;
pub const SEXTF_MARK: u32 = 1 << SEXTB_MARK;

/// io_Status: the modem lines, a bit clear while the line is active
/// (serial.h leaves these unnamed)...
pub const IO_STATB_DSR = 3;
pub const IO_STATF_DSR: u16 = 1 << IO_STATB_DSR;
pub const IO_STATB_CTS = 4;
pub const IO_STATF_CTS: u16 = 1 << IO_STATB_CTS;
pub const IO_STATB_CD = 5;
pub const IO_STATF_CD: u16 = 1 << IO_STATB_CD;
pub const IO_STATB_RTS = 6;
pub const IO_STATF_RTS: u16 = 1 << IO_STATB_RTS;
pub const IO_STATB_DTR = 7;
pub const IO_STATF_DTR: u16 = 1 << IO_STATB_DTR;
/// ...and the port's state, a bit set while it holds.
pub const IO_STATB_OVERRUN = 8;
pub const IO_STATF_OVERRUN: u16 = 1 << IO_STATB_OVERRUN;
pub const IO_STATB_WROTEBREAK = 9;
pub const IO_STATF_WROTEBREAK: u16 = 1 << IO_STATB_WROTEBREAK;
pub const IO_STATB_READBREAK = 10;
pub const IO_STATF_READBREAK: u16 = 1 << IO_STATB_READBREAK;
pub const IO_STATB_XOFFWRITE = 11;
pub const IO_STATF_XOFFWRITE: u16 = 1 << IO_STATB_XOFFWRITE;
pub const IO_STATB_XOFFREAD = 12;
pub const IO_STATF_XOFFREAD: u16 = 1 << IO_STATB_XOFFREAD;

/// The commands after the standard ones.
pub const SDCMD_QUERY: u16 = exec.CMD_NONSTD;
pub const SDCMD_BREAK: u16 = exec.CMD_NONSTD + 1;
pub const SDCMD_SETPARAMS: u16 = exec.CMD_NONSTD + 2;

/// io_Error values of serial.device (serial.h's SerErr_*).
pub const SerErr_DevBusy: i8 = 1;
pub const SerErr_BaudMismatch: i8 = 2;
pub const SerErr_BufErr: i8 = 4;
pub const SerErr_InvParam: i8 = 5;
pub const SerErr_LineErr: i8 = 6;
pub const SerErr_ParityErr: i8 = 9;
pub const SerErr_TimerErr: i8 = 11;
pub const SerErr_BufOverflow: i8 = 12;
pub const SerErr_NoDSR: i8 = 13;
pub const SerErr_DetectedBreak: i8 = 15;

/// io_Length for CMD_WRITE: the text in io_Data ends at a NUL.
pub const LENGTH_NUL_TERMINATED: u64 = 0xFFFF_FFFF_FFFF_FFFF;

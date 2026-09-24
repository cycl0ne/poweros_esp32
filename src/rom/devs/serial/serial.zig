// SPDX-License-Identifier: MPL-2.0
//! serial.device: the chip's UARTs, raw, one unit per UART (uart.zig).
//! Its API is IOExtSer requests, their commands, parameters and errors
//! (sdk/devices/serial.zig). The USB-Serial-JTAG port is usbserial.device.
//!
//!   unit 0  UART0 (the ROM's pins, GPIO43 TX and GPIO44 RX)
//!   unit 1  UART1 (no pins routed yet)
//!   unit 2  UART2 (no pins routed yet)
//!
//!   CMD_READ         io_Length bytes: it waits for all of them,
//!                    or in EOF mode (SERF_EOFMODE) for a termination
//!                    character of io_TermArray.
//!   CMD_WRITE        io_Length bytes, or up to a NUL for -1, as they are.
//!                    Done inside BeginIO, so DoIO gets it as quick I/O.
//!   CMD_STOP         pauses both directions: reads get no input, writes
//!                    (and breaks with SERF_QUEUEDBRK) wait.
//!   CMD_START        does what waited, then serves the reads.
//!   CMD_CLEAR        drops the buffered input.
//!   CMD_FLUSH        aborts the queued requests, not the active ones.
//!   CMD_RESET        aborts all, clears the input, and goes back to the
//!                    boot-up parameters and buffer.
//!   SDCMD_QUERY      io_Actual: the bytes waiting; io_Status: the lines
//!                    and the port's state.
//!   SDCMD_BREAK      holds the line low for io_BrkTime µs.
//!   SDCMD_SETPARAMS  the IOExtSer's parameters, checked (unit.zig).
//!
//! The device sets its UARTs up itself: bus clock, reset, the crystal as
//! their clock, 115200 8N1 (uart.setUp). UART0 may be up already: exec's
//! RawIOInit sets it up for kprintf.
//!
//! - A unit is exclusive: a second OpenDevice fails with SerErr_DevBusy,
//!   unless all its openers set SERF_SHARED in io_SerFlags.
//! - The first opener gets a fresh input buffer of io_RBufLen bytes; it is
//!   freed at the last close. The parameters stay with the unit.
//! - SDCMD_SETPARAMS answers SerErr_DevBusy while requests are active or
//!   queued, and then only takes the xON/xOFF switch.
//! - A receive error (break, parity, framing, overrun) ends the read in
//!   progress with its SerErr_*, or the next one.
//! - The break is timed by timer.device (opened at the first break, closed
//!   at the unit's last close); its reply ends the break in a software
//!   interrupt.
//!
//! xON/xOFF is off at boot, since the kernel's polled
//! output (kprintf) shares UART0 and an xOFF would stall it; a UART takes
//! one frame for both directions (5 to 8 bits, 1 or 2 stop bits, no mark
//! or space parity); there is no 7-wire handshaking (no RTS/CTS pins); a
//! write that comes during a break waits for its end inside BeginIO;
//! CloseDevice aborts what still waits.
//!
//! The kernel's own output (kprintf: log, panic, Guru) doesn't go through
//! here; exec's RawPutChar writes it to UART0, polled: CMD_STOP doesn't
//! hold it, and during a break it is sent inverted.
//!
//! The units' code is unit.zig, which usbserial.device shares.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const unit = @import("unit.zig");

pub const DEVICE_NAME = sdk.devices.serial.SERIALNAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 1;
const BUILD_DATE = "15.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The units' ports, by unit number.
const ports = [_]unit.Port{ .uart0, .uart1, .uart2 };

/// exec has copied the tag's name, version and ID string into the base.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    dev.revision = DEVICE_REVISION;
    unit.initDevice(dev, sys_base, &ports);
    return dev;
}

const init_table = exec.InitTable{
    .data_size = unit.dataSize(ports.len),
    .vectors = &unit.vectors,
    .vector_count = unit.vectors.len,
    .init = &init,
};

export const serial_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &serial_device_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};

// SPDX-License-Identifier: MIT
//! cyw43455bt.device's own state: the base, with its one unit - the
//! board's controller - the line it is on, the requests it holds, and
//! the buffers its bytes go through.
//!
//! **The bytes in** are the interrupt's to take from the receive FIFO
//! and the worker's to put together into packets: a ring of `RX_BYTES`
//! between them, the interrupt moving `rx_in` and the worker `rx_out`,
//! each only its own, so that neither waits for the other. A ring that
//! fills has the interrupt turn the receive interrupt off (`rx_held`)
//! and the worker turn it on again once it has made room: meanwhile the
//! mini UART's FIFO fills and its RTS holds the controller back.
//!
//! **The bytes out** are one packet at a time: the worker sets it -
//! its kind byte, its bytes, where it is up to - while the transmit
//! interrupt is off, and turns it on; the interrupt fills the FIFO from
//! it, and once the last byte is in turns itself off and wakes the
//! worker (`tx_busy` cleared).
//!
//! The mini UART's interrupt enables are the worker's to change inside
//! Disable and the interrupt's to change where it runs, which Disable
//! keeps out: `rx_on` and `tx_on` say what they are.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const hci = sdk.bluetooth.hci;
const hcidev = sdk.devices.hci;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const BluetoothBase = sdk.interface.bluetooth.BluetoothBase;
const h4 = @import("h4.zig");
const miniuart = @import("miniuart.zig");

pub const DEVICE_NAME = "cyw43455bt.device";
/// The name it is opened by: its place under DEVS:.
pub const OPEN_NAME = "bluetooth/" ++ DEVICE_NAME;

/// The rate the line runs at once the controller is set up: 921600 bit/s
/// is 919117 from the mini UART's 500 MHz, within 0.3 %.
pub const WORK_BAUD: u32 = 921600;

/// The receive FIFO's bytes kept for the worker: a power of two.
pub const RX_BYTES = 4096;

/// What the worker has made of the bytes in, and the room for the
/// setup's commands: a block of its own, kept with the device.
pub const Buffers = struct {
    rx: [RX_BYTES]u8 = undefined,
    parser: h4.Parser = .{},
    ring: h4.Ring = .{},
    /// A command the setup sends, from its opcode on.
    command: [hci.HCI_COMMAND_HDR + hci.HCI_MAX_PARAMS]u8 = undefined,
    /// What Command Complete answered the setup's last command: its
    /// parameters after the opcode, the status first.
    answer: [hci.HCI_MAX_PARAMS]u8 = undefined,
    answer_length: usize = 0,
};

pub const BtBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// What the device was loaded from.
    seg_list: ?*anyopaque = null,
    dos_base: ?*DosBase = null,
    /// bluetooth.library, opened by the worker to offer the controller,
    /// and kept.
    bt_base: ?*BluetoothBase = null,
    /// The opener's unit: its port is the worker's queue of requests.
    unit: exec.Unit = .{},
    /// The worker: a DOS process, since the patch is read from a file.
    worker: ?*exec.Task = null,
    work_mask: u32 = 0,
    /// The task that started the worker, and the signal it waits on until
    /// the worker runs.
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    /// The worker runs; the controller is set up and the unit opens; the
    /// setup failed and the unit never will.
    running: u8 = 0,
    ready: u8 = 0,
    failed: u8 = 0,
    timer_open: u8 = 0,
    int_hooked: u8 = 0,
    /// The interrupts on, the receive one held off by a full ring, and a
    /// packet going out (the interrupt clears it once all is sent).
    rx_on: u8 = 0,
    tx_on: u8 = 0,
    rx_held: u8 = 0,
    tx_busy: u8 = 0,
    pad: [6]u8 = @splat(0),
    /// The line, the interrupt it raises, and the controller's address
    /// as the board gives it (all 0 for none).
    line: miniuart.Line = .{},
    /// The memory the line's mailbox messages are in, as it was
    /// allocated: two buffers' room, for the alignment.
    mail_memory: ?*anyopaque = null,
    irq: u32 = 0,
    address: [6]u8 = @splat(0),
    pad2: [2]u8 = .{ 0, 0 },
    /// The rate the line runs at.
    baud: u32 = 0,
    interrupt: exec.Interrupt = .{},
    /// The bytes in: the interrupt's place in the ring and the worker's,
    /// counted on past its end.
    rx_in: u32 = 0,
    rx_out: u32 = 0,
    /// The packet going out: its kind byte, its bytes, and how many of
    /// both are sent.
    tx_kind: u8 = 0,
    pad3: [7]u8 = @splat(0),
    tx_data: ?[*]const u8 = null,
    tx_length: usize = 0,
    tx_at: usize = 0,
    /// The opener's reads waiting for a packet, its writes waiting for
    /// the line, and the one going out: AbortIO takes the waiting ones
    /// off too, under Disable.
    reads: exec.List = .{},
    writes: exec.List = .{},
    sending: ?*exec.IORequest = null,
    buffers: ?*Buffers = null,
    /// The worker's pauses and time-outs, on a port of its own.
    timer_io: timer.TimeRequest = .{},
    timer_port: ?*exec.MsgPort = null,
    /// What HCICMD_QUERY answers: the chip and the patch it was given.
    chip: [48]u8 = @splat(0),
    firmware: [64]u8 = @splat(0),
};

pub fn btBase(dev: *exec.Device) *BtBase {
    return @fieldParentPtr("dev", dev);
}

pub fn hciReq(io: *exec.IORequest) *hcidev.IOHciReq {
    return @ptrCast(@alignCast(io));
}

/// The request a message on a port belongs to.
pub fn requestOf(message: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", message);
}

/// A string kept in a fixed field, cut to fit.
pub fn copyInto(into: []u8, text: []const u8) void {
    const length = @min(text.len, into.len - 1);
    @memcpy(into[0..length], text[0..length]);
    into[length] = 0;
}

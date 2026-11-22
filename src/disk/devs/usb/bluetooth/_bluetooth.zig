// SPDX-License-Identifier: MIT
//! usb/bluetooth.device's own state: the base, and a unit for each
//! controller plugged in - its USB device and pipes, the requests it
//! holds, and the buffers its packets are put together in.
//!
//! **A unit per controller.** A bind (on the bus's process) takes a free
//! unit under the base's `lock`, opens the controller's pipes and hands
//! the unit to the worker, which owns it from then on: it gives the chip
//! what it needs (mediatek.zig), offers the unit to bluetooth.library,
//! and runs its transfers (worker.zig). `leaving`, set by the unbind,
//! keeps the worker from sending anything more and has every request
//! that comes answered HCIERR_DETACHED.
//!
//! **The buffers** - the transfers' rooms, the packets on their way in,
//! the ring of those nobody has read yet (transport.zig) - are a block
//! the worker allocates for a unit's first controller and the unit keeps:
//! the device is never expunged, and a controller plugged in again finds
//! them there.

const sdk = @import("sdk");
const exec = sdk.exec;
const usb = sdk.usb;
const timer = sdk.devices.timer;
const hcidev = sdk.devices.hci;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UsbBase = sdk.interface.usb.UsbBase;
const BluetoothBase = sdk.interface.bluetooth.BluetoothBase;
const transport = @import("transport.zig");

pub const DEVICE_NAME = "bluetooth.device";
/// The name it is opened by: its place under DEVS:.
pub const OPEN_NAME = "usb/" ++ DEVICE_NAME;

/// How many controllers it drives at once.
pub const UNITS = 4;

/// A command from a bind or an unbind to the worker.
pub const Command = extern struct {
    message: exec.Message = .{},
    kind: Kind = .start,
    unit: u32 = 0,

    pub const Kind = enum(u32) { start, let_go };
};

/// Who made the controller's chip, for its setup.
pub const VENDOR_NONE: u8 = 0;
pub const VENDOR_MEDIATEK: u8 = 1;

pub const Unit = extern struct {
    /// The exec unit the opener's requests name; its port is the worker's
    /// queue of them.
    unit: exec.Unit = .{},
    /// Which of the base's units it is.
    number: u32 = 0,
    /// Spoken for by a bind; set up, its endpoints read and open to the
    /// stack; being let go of; offered to bluetooth.library.
    bound: u8 = 0,
    ready: u8 = 0,
    leaving: u8 = 0,
    added: u8 = 0,
    /// VENDOR_*: whose setup the chip gets.
    vendor: u8 = VENDOR_NONE,
    /// Endpoint errors in a row: the controller is given up past a few.
    errors: u8 = 0,
    pad: [2]u8 = .{ 0, 0 },
    device: ?*usb.USBDevice = null,
    /// Commands out on the control endpoint, events in, ACL data in and
    /// out.
    control: ?*usb.USBPipe = null,
    events_in: ?*usb.USBPipe = null,
    acl_in: ?*usb.USBPipe = null,
    acl_out: ?*usb.USBPipe = null,
    /// The opener's reads waiting for a packet, and its writes waiting for
    /// their pipe: taken off by AbortIO too, under Disable.
    reads: exec.List = .{},
    writes: exec.List = .{},
    /// The write being sent as a command, and the one being sent as ACL
    /// data.
    command_out: ?*exec.IORequest = null,
    acl_sending: ?*exec.IORequest = null,
    /// The unit's buffers.
    buffers: ?*transport.Buffers = null,
    /// The command that started it.
    start: Command = .{},
    /// What HCICMD_QUERY answers: the chip and the firmware it was given.
    chip: [48]u8 = @splat(0),
    firmware: [96]u8 = @splat(0),
};

pub const BtBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// What the device was loaded from.
    seg_list: ?*anyopaque = null,
    usb_base: ?*UsbBase = null,
    dos_base: ?*DosBase = null,
    /// bluetooth.library, opened by the worker for the first controller it
    /// offers, and kept.
    bt_base: ?*BluetoothBase = null,
    /// The worker: a DOS process, since the firmware is read from files.
    worker: ?*exec.Task = null,
    /// The binds' commands, and the pipes' answers: the worker's, on one
    /// signal with the units' ports.
    commands: exec.MsgPort = .{},
    pipes: exec.MsgPort = .{},
    work_mask: u32 = 0,
    /// The task that started the worker, and the signal it waits on until
    /// the worker is ready.
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    ready: u8 = 0,
    timer_open: u8 = 0,
    pad: [1]u8 = .{0},
    /// The setup's pauses: the worker's, on a port of its own.
    timer_io: timer.TimeRequest = .{},
    timer_port: ?*exec.MsgPort = null,
    /// Which units are bound: taken by the binds and the worker.
    lock: exec.SignalSemaphore = .{},
    units: [UNITS]Unit = @splat(.{}),

    pub fn ub(base: *BtBase) *UsbBase {
        return base.usb_base.?;
    }
};

pub fn btBase(dev: *exec.Device) *BtBase {
    return @fieldParentPtr("dev", dev);
}

/// The unit an opener's request names.
pub fn unitOf(io: *exec.IORequest) *Unit {
    return @fieldParentPtr("unit", io.unit.?);
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
    for (text[0..length], 0..) |char, index| into[index] = char;
    into[length] = 0;
}

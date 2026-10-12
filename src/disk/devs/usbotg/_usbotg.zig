// SPDX-License-Identifier: MIT
//! What usbotg.device's files share: the device's base, a controller's
//! block - its unit, its task, its channels, its root hub - and the small
//! helpers every file uses.
//!
//! **A unit is a controller.** Unit n is the chip's controller n
//! (`PART_BusUnit`), there when the board has a `PARTKIND_USB` part for
//! it that may be a host. The first OpenDevice of a unit makes its block
//! and starts it - the controller powered and reset, its root port
//! powered, its task running - and the last CloseDevice stops it again,
//! so a bus nobody has started costs nothing.
//!
//! **Everything happens on the unit's task.** BeginIO puts a transfer on
//! the unit's port and the task takes it: a root hub request is answered
//! there (roothub.zig), a transfer waits for a free channel and is put on
//! the wire (host.zig). The interrupt only reads and clears what the
//! controller says and leaves it for the task, which takes it inside
//! Disable; nothing waits in it, and it takes no lock - a lock an
//! interrupt took would come after whatever lock the task it interrupted
//! holds, exec's own among them.

const sdk = @import("sdk");
const exec = sdk.exec;
const usbhc = sdk.devices.usbhc;
const usb = sdk.usb;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const usb_otg = sdk.hardware.usb_otg;
const usbport = sdk.resources.usbport;

pub const DEVICE_NAME = "usbotg.device";

/// How many controllers the device drives at most: the P4 has two.
pub const max_units = 2;
/// How many channels a controller has at most: the P4's high-speed one.
pub const max_channels = 16;
/// A channel's buffer on a full-speed controller, in internal memory,
/// which its DMA reaches and the transfer passes through: a whole number
/// of every packet size there is at full speed, and of cache lines.
pub const bounce_bytes: u32 = 512;
/// A channel's buffer on the high-speed controller: eight packets of a
/// high-speed bulk endpoint. In internal memory too: the ESP32-P4's
/// controller writing a long transfer into PSRAM was seen to stop partway,
/// its packets received and never written.
pub const hs_bounce_bytes: u32 = 4 * 1024;
/// How the channels' buffers are aligned: the caches' line.
pub const bounce_align: usize = 128;
/// A complete-split of a periodic transfer that hears NYET this many
/// times has nothing this interval.
pub const max_nyets = 3;
/// A transaction error is tried again this many times before the
/// transfer fails.
pub const max_errors = 3;

/// usbotg.device's base: what MakeLibrary allocated, and a block per
/// started controller.
pub const UsbOtgBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    /// The controllers the board has as hosts: a bit per unit.
    present: u32 = 0,
    /// A board's hub reset line for each unit (`PART_PinReset`), as a
    /// BoardPin's data; 0 for none.
    hub_reset: [max_units]usize = @splat(0),
    /// The line that gives a unit's socket its lines (`PART_PinSwitch`),
    /// as a BoardPin's data; 0 for none.
    socket_switch: [max_units]usize = @splat(0),
    /// usbport.resource, which gives a controller its port; null without
    /// it, and the port is taken as it is.
    port_base: ?*usbport.UsbPortBase = null,
    /// The IO expander, where a socket's switch is on it.
    expander: ?*sdk.interface.expander.ExpanderBase = null,
    /// Each started controller's block, null while it is stopped.
    hosts: [max_units]?*Host = @splat(null),
    /// Who may start and stop a unit: one opener at a time.
    open_lock: exec.SignalSemaphore = .{},
};

/// Where a transfer is in a control transfer's three stages, or in a
/// bulk or interrupt transfer's one.
pub const Stage = enum(u8) { idle, setup, data, status };

/// A channel of the controller, and the transfer on it.
pub const Channel = struct {
    request: ?*usbhc.IOUsbHC = null,
    stage: Stage = .idle,
    /// What this round asked for: bytes and packets.
    round_bytes: u32 = 0,
    round_packets: u32 = 0,
    /// The transfer's data stage moved so far.
    done: u32 = 0,
    /// Transaction errors in a row.
    errors: u8 = 0,
    /// The empty packet that ends an OUT transfer of whole packets has
    /// gone.
    zero_sent: bool = false,
    /// The transfer goes as split transactions, through a high-speed
    /// hub's transaction translator: a packet a round, each a start-split
    /// and then complete-splits (`complete`) until the hub has the answer.
    split: bool = false,
    complete: bool = false,
    /// A periodic complete-split's NYETs in a row.
    nyets: u8 = 0,
    /// The channel's buffer (`Host.bounce_bytes` of it).
    bounce: [*]u8 = undefined,
};

/// The root hub's state: its address, its configuration, and its one
/// port as a hub's port status says it.
pub const RootHub = struct {
    /// The address it answers at: 0 until SET_ADDRESS gave it one.
    address: u8 = 0,
    configuration: u8 = 0,
    /// wPortStatus and wPortChange.
    status: u16 = 0,
    change: u16 = 0,
    /// The interrupt transfer on its endpoint 1 that waits for a change.
    waiting: ?*usbhc.IOUsbHC = null,
};

/// A started controller: everything its task, its interrupt and BeginIO
/// share. Internal memory, since the interrupt reads it.
pub const Host = struct {
    dev_base: *UsbOtgBase,
    sys: *ExecBase,
    number: u32,
    controller: usb_otg.Controller,
    /// Where its registers start.
    regs: usize,
    /// Transfers come in on its port.
    unit: exec.Unit = .{},
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    int: exec.Interrupt = .{},
    /// What each channel's HCINT said since the task last looked: written
    /// by the interrupt, taken by the task inside Disable.
    chan_events: [max_channels]u32 = @splat(0),
    /// HPRT's change bits since the task last looked, and
    /// `event_disconnect`.
    port_events: u32 = 0,
    /// The task's signals: the interrupt, an abort, a command from an
    /// opener (start the controller, or stop it).
    int_signal: u32 = 0,
    abort_signal: u32 = 0,
    command_signal: u32 = 0,
    /// The task has its signals and takes commands.
    alive: u8 = 0,
    /// The controller is stopped.
    stopped: u8 = 0,
    /// It came up: the controller answered and its root port is powered.
    ready: u8 = 0,
    /// Its PHY is the high-speed UTMI one.
    utmi: u8 = 0,
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    channels: [max_channels]Channel = @splat(.{}),
    channel_count: u32 = 0,
    /// The FIFO's depth, in 32-bit words.
    fifo_words: u32 = 0,
    /// Transfers waiting for a channel, and interrupt transfers waiting
    /// for their next turn: message nodes of their requests.
    waiting: exec.List = .{},
    parked: exec.List = .{},
    /// The task's own port, for its timer.
    port: ?*exec.MsgPort = null,
    /// The bid for the USB port the controller is on, and the task's
    /// signal it is told by.
    port_bid: usbport.USBPortHandle = .{},
    port_signal: u32 = 0,
    /// The wake-up for parked transfers and timeouts, and a delay.
    tick_io: timer.TimeRequest = .{},
    tick_armed: u8 = 0,
    delay_io: timer.TimeRequest = .{},
    /// When the tick is due, in the task's milliseconds.
    tick_due: u32 = 0,
    root: RootHub = .{},
    /// The memory the channels' buffers are in, and each channel's share.
    bounce_memory: ?*anyopaque = null,
    bounce_bytes: u32 = bounce_bytes,
};

/// `port_events`: the device on the root port went.
pub const event_disconnect: u32 = 1 << 31;

/// hc_private[0]: the request's flags.
pub const PRIV_FLAGS = 0;
/// hc_private[1]: a parked transfer's next turn; a transfer's deadline
/// when it has a NAK timeout. In the task's milliseconds.
pub const PRIV_DUE = 1;
/// hc_private[2]: an interrupt transfer's earliest next turn, set as it
/// is answered and kept for the next transfer on the same request (a
/// pipe's): an endpoint is asked at most once per interval, also one
/// that always has something to say.
pub const PRIV_NEXT = 2;
/// hc_private[3]: AbortIO asked for it - a word of its own, written by
/// BeginIO and AbortIO only, so the task never writes over it.
pub const PRIV_ABORT = 3;
/// The flags: it has a deadline.
pub const PRIVF_DEADLINE: usize = 1 << 1;

pub fn baseOf(dev: *exec.Device) *UsbOtgBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

/// The block of the unit a request was opened on.
pub fn hostOf(io: *exec.IORequest) *Host {
    return @alignCast(@fieldParentPtr("unit", io.unit.?));
}

pub fn hcOf(io: *exec.IORequest) *usbhc.IOUsbHC {
    return @ptrCast(@alignCast(io));
}

pub fn requestOf(msg: *exec.Message) *usbhc.IOUsbHC {
    return @ptrCast(@alignCast(msg));
}

pub fn nodeOf(req: *usbhc.IOUsbHC) *exec.Node {
    return &req.std.req.message.node;
}

pub fn requestOfNode(node: *exec.Node) *usbhc.IOUsbHC {
    const msg: *exec.Message = @fieldParentPtr("node", node);
    return requestOf(msg);
}

/// The register at `offset` from the controller's base.
pub inline fn reg(host: *const Host, offset: usize) *volatile u32 {
    return sdk.hardware.mmio.reg(host.regs + offset);
}

/// The task's clock: milliseconds since the system started, wrapping.
pub fn now(host: *Host) u32 {
    var t: timer.TimeVal = .{};
    const tmb: *sdk.interface.timer.TimerBase = @ptrCast(host.delay_io.node.device.?);
    tmb.GetSysTime(&t);
    return @truncate(t.toMicros() / 1000);
}

/// Whether `a` is at or after `b` on the wrapping clock.
pub fn reached(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

/// `ms` milliseconds waited out on the task.
pub fn delay(host: *Host, ms: u32) void {
    host.delay_io.node.command = timer.TR_ADDREQUEST;
    host.delay_io.time = timer.TimeVal.fromMicros(@as(u64, ms) * 1000);
    _ = host.sys.DoIO(&host.delay_io.node);
}

/// A request answered: its error, and replied.
pub fn reply(host: *Host, req: *usbhc.IOUsbHC, err: i8) void {
    req.std.req.err = err;
    host.sys.ReplyIO(&req.std.req);
}

/// What USB calls a speed, as the request carries it.
pub fn isLow(req: *const usbhc.IOUsbHC) bool {
    return req.speed == usbhc.USB_SPEED_LOW;
}

pub const usb_descriptors = usb.descriptors;

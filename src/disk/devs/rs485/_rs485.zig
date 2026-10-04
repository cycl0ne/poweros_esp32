// SPDX-License-Identifier: MIT
//! rs485.device's base, and the block its interrupt reaches: the frames
//! received and kept, the one being received, and the one being sent.
//!
//! **Frames are kept in slots.** A slot holds one whole frame, up to
//! RS485_MAX_FRAME bytes; the interrupt fills the slot after the last
//! kept one and closes it when the line goes quiet, the task hands the
//! oldest to a read and frees it. With every slot full a frame that
//! comes is dropped whole, so what is kept is always whole frames in the
//! order they came.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const rs485 = sdk.devices.rs485;
const ExecBase = sdk.interface.exec.ExecBase;

pub const DEVICE_NAME = rs485.RS485NAME;

/// Frames kept while no read waits.
pub const slot_count = 4;

/// What went wrong with a frame while it came in.
pub const FRAME_PARITY: u8 = 1 << 0;
pub const FRAME_FRAMING: u8 = 1 << 1;
/// Longer than a slot: the rest is gone.
pub const FRAME_OVERFLOW: u8 = 1 << 2;

pub const Slot = extern struct {
    length: u32 = 0,
    flags: u8 = 0,
    pad: [3]u8 = @splat(0),
    bytes: [rs485.RS485_MAX_FRAME]u8 = undefined,
};

/// What the interrupt touches: internal memory, out of the base, which
/// is wherever MakeLibrary put it.
pub const Work = extern struct {
    int: exec.Interrupt = .{},
    /// The oldest kept frame, and how many are kept.
    first: u32 = 0,
    kept: u32 = 0,
    /// Whether a frame is coming in, into slot (first + kept) % slot_count;
    /// `dropping` while one comes that has no slot.
    receiving: u8 = 0,
    dropping: u8 = 0,
    pad: [2]u8 = @splat(0),
    /// Frames dropped for want of a slot, since the unit was opened.
    dropped: u32 = 0,
    /// The frame being sent: what is left of it.
    send_data: ?[*]const u8 = null,
    send_left: u32 = 0,
    /// EVENT_*: what the interrupt has to tell the task.
    events: u32 = 0,
    slots: [slot_count]Slot = @splat(.{}),
};

/// A frame was closed.
pub const EVENT_FRAME: u32 = 1 << 0;
/// The frame being sent is on the wire, the last bit too.
pub const EVENT_SENT: u32 = 1 << 1;

/// The line, as a unit has it.
pub const Line = extern struct {
    baud: u32 = rs485.RS485_DEFAULT_BAUD,
    gap: u32 = rs485.RS485_DEFAULT_GAP,
    data_bits: u8 = 8,
    parity: u8 = rs485.RS485_PARITY_NONE,
    stop_bits: u8 = 1,
    pad: u8 = 0,
};

pub const RS485Base = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    /// The reads and the writes the task keeps, which AbortIO and a flush
    /// take from too: a spinlock, held a few lines at a time.
    lock: exec.Lock = .{},
    seg_list: ?*anyopaque = null,
    /// The one unit; its port is the task's queue.
    unit: exec.Unit = .{},
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    work_memory: ?*anyopaque = null,
    work: ?*Work = null,
    /// The pads the port is on.
    tx_pad: u8 = 0,
    rx_pad: u8 = 0,
    /// Whether the port's part was found and the task runs.
    ready: u8 = 0,
    pad: u8 = 0,
    line: Line = .{},
    /// The interrupt's signal to the task.
    int_mask: u32 = 0,
    /// The reads that wait, the first being served; the writes (and the
    /// SETPARAMS) that wait, in order, and the one being sent.
    reads: exec.List = .{},
    writes: exec.List = .{},
    sending: ?*exec.IORequest = null,
    /// The task's timer, for a read's time-out: which read it was armed
    /// for, or null when it is not armed.
    timer_port: ?*exec.MsgPort = null,
    timer_io: timer.TimeRequest = .{},
    timed: ?*exec.IORequest = null,
    /// Who waits for the task to have started, and on which signal.
    starter: ?*exec.Task = null,
    start_signal: u8 = 0,
    pad2: [3]u8 = @splat(0),
};

pub fn rs485Base(dev: *exec.Device) *RS485Base {
    return @fieldParentPtr("dev", dev);
}

pub fn baseOf(io: *exec.IORequest) *RS485Base {
    return @fieldParentPtr("unit", io.unit.?);
}

pub fn request(io: *exec.IORequest) *rs485.IORS485 {
    return @alignCast(@fieldParentPtr("std", stdReq(io)));
}

pub fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a message or a list node belongs to.
pub fn requestOf(msg: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", msg);
}

pub fn requestOfNode(node: *exec.Node) *exec.IORequest {
    return requestOf(@fieldParentPtr("node", node));
}

/// Whether a request is large enough to hold the port's parameters.
pub fn hasParams(io: *exec.IORequest) bool {
    return io.message.length >= @sizeOf(rs485.IORS485);
}

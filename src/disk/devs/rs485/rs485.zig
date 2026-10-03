// SPDX-License-Identifier: MIT
//! rs485.device: the board's RS-485 port, in frames. Unit 0 is the port.
//! Its API is IORS485 requests (sdk/devices/rs485.zig).
//!
//!   CMD_WRITE           one frame, replied when its last bit is out.
//!   CMD_READ            one frame, ended by a quiet line, within the
//!                       request's time-out.
//!   CMD_CLEAR           the kept frames dropped.
//!   CMD_FLUSH           the waiting reads aborted.
//!   RS485CMD_SETPARAMS  the line and the gap, in turn with the writes.
//!   RS485CMD_QUERY      the line and the gap, and the frames kept.
//!
//! **Where the port is.** The board's RS-485 part (expansion.library,
//! PARTKIND_RS485) gives the pads the transceiver's data lines are on; a
//! board without one gets no device at all, and the file goes again. The
//! port runs on UART1 (`port.zig`), which serial.device's unit 1 would
//! use too: the two are not opened together.
//!
//! **Every request that waits is the device's task's.** BeginIO answers
//! CMD_CLEAR and RS485CMD_QUERY where it stands and puts the rest on the
//! unit's port. The task keeps the reads in one list and the writes in
//! another, so a read that waits for an answer does not hold up the
//! write that asks the question: the first write is sent while the
//! others wait their turn, and the first read gets the oldest frame kept
//! or waits for the next, its time-out on the task's timer. The
//! interrupt moves the bytes and signals the task when a frame is kept
//! or sent.
//!
//! A unit is exclusive. Its line stays as it was set when it is closed
//! and opened again; frames that came while it was closed are dropped
//! at the open.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const rs485 = sdk.devices.rs485;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const expansion = sdk.expansion;
const st = expansion.systemtags;
const BoardPin = expansion.BoardPin;
const gpio_resource = sdk.resources.gpio;
const GpioBase = gpio_resource.GpioBase;
const _rs485 = @import("_rs485.zig");
const port = @import("port.zig");
const RS485Base = _rs485.RS485Base;
const Work = _rs485.Work;

pub const DEVICE_NAME = _rs485.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "03.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Enough for the task's loop; nothing here recurses.
const stack_size = 4096;
/// Above dos's processes: a protocol's answer is due within milliseconds.
const task_pri = 5;

// --- the task -------------------------------------------------------------------

/// The task's signal to whoever waits for it to start.
fn started(base: *RS485Base) void {
    if (base.starter) |starter| base.sys_base.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
}

/// What the interrupt has said since the task last asked, taken.
fn takeEvents(base: *RS485Base) u32 {
    const sys = base.sys_base;
    sys.Disable();
    defer sys.Enable();
    const events = base.work.?.events;
    base.work.?.events = 0;
    return events;
}

/// The oldest kept frame into a read, and its slot freed.
fn deliver(base: *RS485Base, io: *exec.IORequest) void {
    const sys = base.sys_base;
    const work = base.work.?;
    const slot = &work.slots[work.first];
    const req = _rs485.stdReq(io);
    const room: u32 = @intCast(@min(req.length, rs485.RS485_MAX_FRAME));
    const length: u32 = @min(slot.length, room);
    if (length > 0) @memcpy(@as([*]u8, @ptrCast(req.data.?))[0..length], slot.bytes[0..length]);
    req.actual = length;
    io.err = 0;
    if (slot.flags & _rs485.FRAME_PARITY != 0) io.err = rs485.RS485ERR_PARITY;
    if (slot.flags & _rs485.FRAME_FRAMING != 0) io.err = rs485.RS485ERR_FRAMING;
    if (slot.flags & _rs485.FRAME_OVERFLOW != 0 or slot.length > room) io.err = rs485.RS485ERR_OVERFLOW;
    sys.Disable();
    work.first = (work.first + 1) % _rs485.slot_count;
    work.kept -= 1;
    sys.Enable();
}

/// The timer let go of, if it was armed.
fn disarm(base: *RS485Base) void {
    if (base.timed == null) return;
    const sys = base.sys_base;
    _ = sys.AbortIO(&base.timer_io.node);
    _ = sys.WaitIO(&base.timer_io.node);
    base.timed = null;
}

/// The reads served while frames are kept; the first one left armed
/// with its time-out.
fn serveReads(base: *RS485Base) void {
    const sys = base.sys_base;
    const work = base.work.?;
    while (true) {
        sys.Forbid();
        const head = base.reads.first();
        if (head == null or work.kept == 0) {
            sys.Permit();
            break;
        }
        sys.Remove(head.?);
        sys.Permit();
        const io = _rs485.requestOfNode(head.?);
        if (base.timed == io) disarm(base);
        deliver(base, io);
        sys.ReplyIO(io);
    }
    sys.Forbid();
    const head: ?*exec.IORequest = if (base.reads.first()) |node| _rs485.requestOfNode(node) else null;
    sys.Permit();
    if (base.timed != null and base.timed != head) disarm(base);
    const io = head orelse return;
    if (base.timed != null) return;
    const timeout = _rs485.request(io).timeout;
    if (timeout == 0) return;
    base.timer_io.node.command = timer.TR_ADDREQUEST;
    base.timer_io.time = timer.TimeVal.fromMicros(timeout);
    sys.SendIO(&base.timer_io.node);
    base.timed = io;
}

/// The read the timer was armed for, timed out - if it still waits.
fn timedOut(base: *RS485Base) void {
    const sys = base.sys_base;
    if (sys.CheckIO(&base.timer_io.node) == null) return;
    _ = sys.WaitIO(&base.timer_io.node);
    const io = base.timed orelse return;
    base.timed = null;
    sys.Forbid();
    const head = base.reads.first();
    const still = head != null and _rs485.requestOfNode(head.?) == io;
    if (still) sys.Remove(head.?);
    sys.Permit();
    if (!still) return;
    _rs485.stdReq(io).actual = 0;
    io.err = rs485.RS485ERR_TIMEOUT;
    sys.ReplyIO(io);
}

/// The next write sent, or SETPARAMS done, while nothing is being sent.
fn serveWrites(base: *RS485Base) void {
    const sys = base.sys_base;
    while (base.sending == null) {
        sys.Forbid();
        const node = sys.RemHead(&base.writes);
        sys.Permit();
        const io = _rs485.requestOfNode(node orelse return);
        if (io.command == rs485.RS485CMD_SETPARAMS) {
            setParams(base, io);
            sys.ReplyIO(io);
            continue;
        }
        const req = _rs485.stdReq(io);
        base.sending = io;
        port.send(base.work.?, sys, @ptrCast(req.data.?), @intCast(req.length));
    }
}

fn setParams(base: *RS485Base, io: *exec.IORequest) void {
    const req = _rs485.request(io);
    const line: _rs485.Line = .{
        .baud = req.baud,
        .gap = req.gap,
        .data_bits = req.data_bits,
        .parity = req.parity,
        .stop_bits = req.stop_bits,
    };
    if (!port.setLine(line)) {
        io.err = rs485.RS485ERR_BADPARAMS;
        return;
    }
    base.line = line;
}

fn rs485Task(sys: *ExecBase) callconv(.c) void {
    const base: *RS485Base = @fieldParentPtr("task", sys.FindTask(null).?);
    const queue_port = &base.unit.msg_port;
    const queue_signal = sys.AllocSignal(-1);
    const int_signal = sys.AllocSignal(-1);
    base.timer_port = sys.CreateMsgPort();
    if (queue_signal < 0 or int_signal < 0 or base.timer_port == null) return started(base);
    base.timer_io = .{};
    base.timer_io.node.message.reply_port = base.timer_port;
    base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.timer_io.node, 0) != 0) return started(base);
    base.int_mask = @as(u32, 1) << @intCast(int_signal);
    sys.Disable();
    queue_port.sig_bit = @intCast(queue_signal);
    queue_port.sig_task = &base.task;
    queue_port.flags = exec.PA_SIGNAL;
    sys.Enable();
    base.ready = 1;
    started(base);

    const timer_mask = base.timer_port.?.sigMask();
    while (true) {
        const got = sys.Wait(queue_port.sigMask() | base.int_mask | timer_mask);
        while (sys.GetMsg(queue_port)) |msg| {
            const io = _rs485.requestOf(msg);
            sys.Forbid();
            if (io.command == exec.CMD_READ) sys.AddTail(&base.reads, &io.message.node) else sys.AddTail(&base.writes, &io.message.node);
            sys.Permit();
        }
        if (got & base.int_mask != 0) {
            const events = takeEvents(base);
            if (events & _rs485.EVENT_SENT != 0) {
                if (base.sending) |io| {
                    _rs485.stdReq(io).actual = _rs485.stdReq(io).length;
                    base.sending = null;
                    sys.ReplyIO(io);
                }
            }
        }
        if (got & timer_mask != 0) timedOut(base);
        serveWrites(base);
        serveReads(base);
    }
}

// --- the device's vectors -------------------------------------------------------

fn canWait(io: *exec.IORequest) bool {
    if (io.message.reply_port != null) return true;
    io.err = exec.IOERR_NOREPLYPORT;
    io.flags |= exec.IOF_QUICK;
    return false;
}

/// Onto the task's queue; it will be replied, so not quick I/O.
fn queue(base: *RS485Base, io: *exec.IORequest) void {
    if (!canWait(io)) return base.sys_base.ReplyIO(io);
    io.flags &= ~exec.IOF_QUICK;
    base.sys_base.PutMsg(&base.unit.msg_port, &io.message);
}

/// The reads that wait, each aborted.
fn flushReads(base: *RS485Base) void {
    const sys = base.sys_base;
    while (true) {
        sys.Forbid();
        const node = sys.RemHead(&base.reads);
        sys.Permit();
        const io = _rs485.requestOfNode(node orelse return);
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
    }
}

fn clearFrames(base: *RS485Base) void {
    const sys = base.sys_base;
    const work = base.work.?;
    sys.Disable();
    defer sys.Enable();
    work.first = (work.first + work.kept) % _rs485.slot_count;
    work.kept = 0;
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    _ = dev;
    const base = _rs485.baseOf(io);
    const req = _rs485.stdReq(io);
    io.err = 0;
    req.actual = 0;
    switch (io.command) {
        exec.CMD_READ => {
            if (req.data == null) io.err = exec.IOERR_BADADDRESS else return queue(base, io);
        },
        exec.CMD_WRITE => {
            if (req.length == 0 or req.length > rs485.RS485_MAX_FRAME) {
                io.err = rs485.RS485ERR_BADLENGTH;
            } else if (req.data == null) {
                io.err = exec.IOERR_BADADDRESS;
            } else return queue(base, io);
        },
        rs485.RS485CMD_SETPARAMS => {
            if (!_rs485.hasParams(io)) io.err = exec.IOERR_BADLENGTH else return queue(base, io);
        },
        rs485.RS485CMD_QUERY => {
            if (!_rs485.hasParams(io)) {
                io.err = exec.IOERR_BADLENGTH;
            } else {
                fillParams(base, io);
                req.actual = base.work.?.kept;
            }
        },
        exec.CMD_CLEAR => clearFrames(base),
        exec.CMD_FLUSH => flushReads(base),
        else => io.err = exec.IOERR_NOCMD,
    }
    io.flags |= exec.IOF_QUICK;
    base.sys_base.ReplyIO(io);
}

/// A request that waits is taken off the task's port or lists and
/// aborted. The frame being sent is not: it is on the wire, and goes
/// out whole.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const base = _rs485.rs485Base(dev);
    const sys = base.sys_base;
    sys.Forbid();
    defer sys.Permit();
    for ([_]*exec.List{ &base.unit.msg_port.msg_list, &base.reads, &base.writes }) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            if (_rs485.requestOfNode(node) != io) continue;
            sys.Remove(node);
            io.err = exec.IOERR_ABORTED;
            sys.ReplyIO(io);
            return 0;
        }
    }
    return -1;
}

fn fillParams(base: *RS485Base, io: *exec.IORequest) void {
    const req = _rs485.request(io);
    req.baud = base.line.baud;
    req.gap = base.line.gap;
    req.data_bits = base.line.data_bits;
    req.parity = base.line.parity;
    req.stop_bits = base.line.stop_bits;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const base = _rs485.rs485Base(dev);
    if (unit_number != 0) return exec.IOERR_OPENFAIL;
    if (base.ready == 0) return exec.IOERR_OPENFAIL;
    if (base.unit.open_cnt != 0) return rs485.RS485ERR_DEVBUSY;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    base.unit.open_cnt += 1;
    io.unit = &base.unit;
    clearFrames(base);
    if (_rs485.hasParams(io)) fillParams(base, io);
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const base = _rs485.baseOf(io);
    _ = abortIO(dev, io);
    flushReads(base);
    base.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    io.unit = null;
    return null;
}

/// The device stays: it owns its task, its interrupt and the UART.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

// --- making the device ----------------------------------------------------------

/// The pads of the board's RS-485 part, or null when it has none whose
/// data lines are pads of the chip.
fn findPort(sys: *ExecBase) ?struct { tx: u8, rx: u8 } {
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(expansion.EXPANSIONNAME, 1) orelse return null;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_RS485, st.CHIP_ANY) orelse return null;
    const tx = BoardPin.of(ub.GetTagData(st.PART_PinDataOut, 0, part.tags));
    const rx = BoardPin.of(ub.GetTagData(st.PART_PinDataIn, 0, part.tags));
    if (tx.kind != expansion.boardpin.BPIN_GPIO or rx.kind != expansion.boardpin.BPIN_GPIO) return null;
    return .{ .tx = tx.number, .rx = rx.number };
}

/// exec has copied the tag's name, version and ID string into the base.
/// A board without the port gets no device: null, before anything is
/// taken, so the base and the file both go. Otherwise the pads are
/// claimed, the block the interrupt reaches is allocated internal, the
/// UART is started and hooked, and the task is started and waited for.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _rs485.rs485Base(dev);
    const header = dev.*;
    base.* = .{ .dev = header, .sys_base = sys_base, .seg_list = seg_list };
    const pads = findPort(sys_base) orelse {
        sdk.exec.kprintf(sys_base, "%s: no RS-485 port on this board\n", .{DEVICE_NAME});
        return null;
    };
    base.tx_pad = pads.tx;
    base.rx_pad = pads.rx;
    const port_pads = [_]u8{ pads.tx, pads.rx };
    const gb: ?*GpioBase = @ptrCast(@alignCast(sys_base.OpenResource(gpio_resource.GPIONAME)));
    if (gb) |taken_from| {
        if (gpio_resource.allocPads(taken_from, &port_pads, DEVICE_NAME)) |refused| {
            sdk.exec.kprintf(sys_base, "%s: GPIO%d is %s's\n", .{ DEVICE_NAME, refused.pad, refused.holder });
            return null;
        }
    }
    const memory = sys_base.AllocMem(@sizeOf(Work), exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse {
        if (gb) |taken_from| gpio_resource.freePads(taken_from, &port_pads);
        return null;
    };
    const stack = sys_base.AllocMem(stack_size, exec.MEMF_CLEAR) orelse {
        sys_base.FreeMem(memory, @sizeOf(Work));
        if (gb) |taken_from| gpio_resource.freePads(taken_from, &port_pads);
        return null;
    };
    base.work_memory = memory;
    const work: *Work = @ptrCast(@alignCast(memory));
    work.* = .{};
    work.int = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = DEVICE_NAME },
        .data = base,
        .code = &port.intServer,
    };
    base.work = work;
    base.reads.init(.message);
    base.writes.init(.message);
    // PA_IGNORE until the task has a signal for it.
    base.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    base.unit.msg_port.msg_list.init(.message);

    sys_base.AddIntServer(port.source(), &work.int);
    port.start(base.tx_pad, base.rx_pad, base.line);

    base.stack = stack;
    base.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    const signal = sys_base.AllocSignal(-1);
    if (signal >= 0) {
        base.starter = sys_base.FindTask(null);
        base.start_signal = @intCast(signal);
    }
    _ = sys_base.AddTask(&base.task, &rs485Task, null);
    if (signal >= 0) {
        _ = sys_base.Wait(@as(u32, 1) << @intCast(signal));
        sys_base.FreeSignal(@intCast(signal));
    }
    return dev;
}

/// The jump table: the six standard vectors, nothing past AbortIO.
const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(RS485Base),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// No flags but AUTOINIT: the device is on the disk, in DEVS:, and is
/// made when something opens it. In `.resident`, which program.ld KEEPs.
export const rs485_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &rs485_device_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 0,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};

/// A device is not a command. Whoever runs this file gets nothing done and
/// a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;

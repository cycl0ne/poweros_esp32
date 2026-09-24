// SPDX-License-Identifier: MPL-2.0
//! mouse.device: a mouse, as raw mouse events.
//!
//! What the mouse does is handed out as IECLASS_RAWMOUSE events: a move
//! when the pointer goes somewhere, and an event for each button that goes
//! down or up - left, right, middle - with the buttons' qualifiers as they
//! are after it (`events.Mouse`). The device queues them until a
//! MOUSE_READEVENT takes them, and MOUSE_READSTATE says where the pointer is
//! and which buttons are down.
//!
//! The one mouse there is now is the emulator's: our QEMU build's display
//! reports the pointer over its window, where it is in the window's pixels
//! and which of its three buttons are down, and the device's task looks at
//! it every 10 ms. That pointer is absolute, so its events carry no
//! IEQUALIFIER_RELATIVEMOUSE. It is the qemu board's mouse part; a board
//! without one has no mouse.device in its ROM, and an open without the
//! part fails. A mouse on a board later is a second backend handing
//! `events.Mouse` what it reports.
//!
//! Nothing runs until the first OpenDevice starts the task; from then on the
//! task stays, as keyboard.device's does. A read waiting for the mouse is
//! queued on the unit, so AbortIO and CMD_FLUSH can take it back.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const mouse = sdk.devices.mouse;
const ie = sdk.devices.inputevent;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const TimerBase = timer.TimerBase;
const InputEvent = ie.InputEvent;
const events = @import("events.zig");
const qemu_rgb = sdk.hardware.qemu_rgb;

pub const DEVICE_NAME = mouse.MOUSENAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "22.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Above ordinary tasks, so the pointer is followed while a program
/// computes.
const task_pri = 10;
const stack_size = 4096;
/// How often the emulator's pointer is looked at.
const poll_us = 10_000;

const MouseBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    /// Reads waiting for the mouse are on its port's list.
    unit: exec.Unit,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The task is running and has a mouse.
    ready: u8 = 0,
    /// The task has been started.
    started: u8 = 0,
    start_signal: i8 = -1,
    pad: u8 = 0,
    starter: ?*exec.Task = null,
    /// Owned by the task.
    port: ?*exec.MsgPort = null,
    timer_io: timer.TimeRequest = .{},
    /// The emulator's count of pointer events when it was last looked at.
    pointer_seq: u32 = 0,
    /// What the mouse was, and the events not yet read.
    mouse: events.Mouse = .{},
    queue: events.Queue = .{},
};

fn mouseBase(dev: *exec.Device) *MouseBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @ptrCast(@alignCast(io));
}

// --- the task ---------------------------------------------------------------------

fn wait(mb: *MouseBase, us: u32) void {
    mb.timer_io.node.command = timer.TR_ADDREQUEST;
    mb.timer_io.time = timer.TimeVal.fromMicros(us);
    _ = mb.sys_base.DoIO(&mb.timer_io.node);
}

fn now(mb: *MouseBase) timer.TimeVal {
    var t: timer.TimeVal = .{};
    const tmb: *TimerBase = @ptrCast(mb.timer_io.node.device.?);
    tmb.GetSysTime(&t);
    return t;
}

/// Whether the board has the emulator's pointer: its part in the board's
/// system tag list.
fn boardHasIt(sys: *ExecBase) bool {
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const st = sdk.expansion.systemtags;
    return eb.FindBoardPart(null, st.PARTKIND_MOUSE, st.CHIP_QEMU_DISPLAY) != null;
}

/// The emulator's mouse, if the board has one.
fn bringUp(mb: *MouseBase) bool {
    const sys = mb.sys_base;
    if (!boardHasIt(sys)) {
        exec.kprintf(sys, "%s: this board has no mouse\n", .{DEVICE_NAME});
        return false;
    }
    if (!qemu_rgb.hasPointer()) {
        exec.kprintf(sys, "%s: this QEMU gives no pointer (build it with scripts/build-qemu.sh)\n", .{DEVICE_NAME});
        return false;
    }
    if (!qemu_rgb.hasAllButtons()) {
        exec.kprintf(sys, "%s: this QEMU gives the left button only (build it with scripts/build-qemu.sh)\n", .{DEVICE_NAME});
    }
    mb.port = sys.CreateMsgPort() orelse return false;
    mb.timer_io = .{};
    mb.timer_io.node.message.reply_port = mb.port;
    mb.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &mb.timer_io.node, 0) != 0) return false;
    // Where the pointer is now is where it starts: nothing has happened yet.
    const p = qemu_rgb.pointer();
    mb.pointer_seq = p.seq;
    var out: [4]InputEvent = undefined;
    _ = mb.mouse.change(nowOf(p), &out);
    return true;
}

fn giveBack(mb: *MouseBase) void {
    const sys = mb.sys_base;
    if (mb.timer_io.node.device != null) sys.CloseDevice(&mb.timer_io.node);
    sys.DeleteMsgPort(mb.port);
    mb.port = null;
}

fn nowOf(p: qemu_rgb.Pointer) events.Now {
    return .{ .x = @intCast(p.x), .y = @intCast(p.y), .left = p.left, .right = p.right, .middle = p.middle };
}

/// Reads that were waiting, given what is queued now. Under Forbid.
fn serveReads(mb: *MouseBase) void {
    const sys = mb.sys_base;
    const list = &mb.unit.msg_port.msg_list;
    while (mb.queue.count > 0) {
        const node = list.head orelse break;
        if (node.succ == null) break;
        const io: *exec.IORequest = @ptrCast(@alignCast(node));
        sys.Remove(node);
        io.flags &= ~exec.IOF_QUEUED;
        const std_io = stdReq(io);
        const room = std_io.length / @sizeOf(InputEvent);
        const into: [*]InputEvent = @ptrCast(@alignCast(std_io.data.?));
        const n = mb.queue.take(into[0..@intCast(room)]);
        std_io.actual = n * @sizeOf(InputEvent);
        sys.ReplyIO(io);
    }
}

/// What the emulator's pointer did since it was last looked at, as events.
fn poll(mb: *MouseBase) void {
    const p = qemu_rgb.pointer();
    if (p.seq == mb.pointer_seq) return;
    mb.pointer_seq = p.seq;
    const time = now(mb);
    const sys = mb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    var out: [4]InputEvent = undefined;
    const n = mb.mouse.change(nowOf(p), &out);
    for (out[0..n]) |*e| {
        e.time = time;
        mb.queue.push(e.*);
    }
    serveReads(mb);
}

fn mouseTask(sys: *ExecBase) callconv(.c) void {
    const mb: *MouseBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const ok = bringUp(mb);
    if (ok) mb.ready = 1 else giveBack(mb);
    if (mb.starter) |starter| {
        mb.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(mb.start_signal));
    }
    if (!ok) return;
    while (true) {
        wait(mb, poll_us);
        poll(mb);
    }
}

/// The task started and waited for; true if there is a mouse.
fn start(mb: *MouseBase) bool {
    const sys = mb.sys_base;
    if (mb.started != 0) return mb.ready != 0;
    const stack = mb.stack orelse blk: {
        const s = sys.AllocMem(stack_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
        mb.stack = s;
        break :blk s;
    };
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    defer sys.FreeSignal(signal);
    mb.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    mb.starter = sys.FindTask(null);
    mb.start_signal = signal;
    mb.ready = 0;
    _ = sys.AddTask(&mb.task, &mouseTask, null);
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    // A task that found no mouse has ended; the next open tries again.
    if (mb.ready != 0) mb.started = 1;
    return mb.ready != 0;
}

// --- the device --------------------------------------------------------------------

fn readEvent(mb: *MouseBase, io: *exec.IORequest) bool {
    const std_io = stdReq(io);
    const each = @sizeOf(InputEvent);
    if (std_io.length == 0 or std_io.length % each != 0) {
        io.err = exec.IOERR_BADLENGTH;
        return true;
    }
    if (std_io.data == null) {
        io.err = exec.IOERR_BADADDRESS;
        return true;
    }
    const sys = mb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    if (mb.queue.count > 0) {
        const into: [*]InputEvent = @ptrCast(@alignCast(std_io.data.?));
        const n = mb.queue.take(into[0..@intCast(std_io.length / each)]);
        std_io.actual = n * each;
        return true;
    }
    // Nothing yet: it waits on the unit for the mouse to do something.
    io.flags &= ~exec.IOF_QUICK;
    io.flags |= exec.IOF_QUEUED;
    // A queued request is a message again, as PutMsg would make it:
    // WaitIO looks at the node's type, and the reply left there by
    // its last use would let a caller past before this one has run.
    io.message.node.type = .message;
    sys.AddTail(&mb.unit.msg_port.msg_list, &io.message.node);
    return false;
}

fn readState(mb: *MouseBase, io: *exec.IORequest) void {
    const std_io = stdReq(io);
    if (std_io.data == null or std_io.length < @sizeOf(mouse.MouseState)) {
        io.err = exec.IOERR_BADLENGTH;
        return;
    }
    const sys = mb.sys_base;
    sys.Forbid();
    const state = mouse.MouseState{ .x = mb.mouse.x, .y = mb.mouse.y, .qualifier = mb.mouse.qualifier };
    sys.Permit();
    const into: *mouse.MouseState = @ptrCast(@alignCast(std_io.data.?));
    into.* = state;
    std_io.actual = @sizeOf(mouse.MouseState);
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const mb = mouseBase(dev);
    const sys = mb.sys_base;
    const std_io = stdReq(io);
    io.err = 0;
    std_io.actual = 0;
    switch (io.command) {
        mouse.MOUSE_READEVENT => if (!readEvent(mb, io)) return,
        mouse.MOUSE_READSTATE => readState(mb, io),
        exec.CMD_CLEAR => {
            sys.Forbid();
            mb.queue.clear();
            sys.Permit();
        },
        exec.CMD_FLUSH => flush(mb),
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

/// Every waiting read back, aborted.
fn flush(mb: *MouseBase) void {
    const sys = mb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    const list = &mb.unit.msg_port.msg_list;
    while (list.head) |node| {
        if (node.succ == null) break;
        const io: *exec.IORequest = @ptrCast(@alignCast(node));
        sys.Remove(node);
        io.flags &= ~exec.IOF_QUEUED;
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
    }
}

fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const mb = mouseBase(dev);
    const sys = mb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    if (io.flags & exec.IOF_QUEUED == 0) return -1;
    sys.Remove(&io.message.node);
    io.flags &= ~exec.IOF_QUEUED;
    io.err = exec.IOERR_ABORTED;
    sys.ReplyIO(io);
    return 0;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const mb = mouseBase(dev);
    if (unit_number != 0) return exec.IOERR_OPENFAIL;
    if (io.message.length < @sizeOf(exec.IOStdReq)) return exec.IOERR_OPENFAIL;
    if (!start(mb)) return exec.IOERR_OPENFAIL;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    mb.unit.open_cnt += 1;
    io.unit = &mb.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const mb = mouseBase(dev);
    _ = abortIO(dev, io);
    mb.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: its task is the machine's once it has come up.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// The unit, ready. Nothing is looked at here: that waits for the first
/// open.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    dev.revision = DEVICE_REVISION;
    const mb = mouseBase(dev);
    mb.sys_base = sys_base;
    mb.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    mb.unit.msg_port.msg_list.init(.message);
    mb.mouse = .{};
    mb.queue = .{};
    return dev;
}

const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(MouseBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// Cold start; the first open needs timer.device (50), which is up by then.
export const mouse_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &mouse_device_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 27,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..],
    .init = &init_table,
};

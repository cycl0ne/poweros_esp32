// SPDX-License-Identifier: MPL-2.0
//! mouse.device: a mouse, as raw mouse events.
//!
//! What the mouse does is handed out as IECLASS_RAWMOUSE events: a move
//! when the pointer goes somewhere, an event for each button that goes
//! down or up - left, right, middle - with the buttons' qualifiers as they
//! are after it, and an IECODE_WHEEL event with the wheel's notches when it
//! turned (`events.Mouse`). The device queues them until a
//! MOUSE_READEVENT takes them, and MOUSE_READSTATE says where the pointer is
//! and which buttons are down.
//!
//! **What the mouse does comes from sources.** A mouse's driver opens the
//! device with MOUSEF_SOURCE and gets a unit of its own, a `Source`, which
//! keeps the buttons it holds down; it hands over what its mouse did with
//! MOUSE_ADDEVENT, and that goes through the same `events.Mouse` as every
//! other source's, so readers see one mouse. A button two sources hold is
//! down once, and a source that closes lets go of what it still holds. A
//! source's move is a place or, marked IEQUALIFIER_RELATIVEMOUSE, a
//! distance, and goes to the readers as it came; a place across a
//! tablet (IESUBCLASS_TABLET) keeps that subclass. Every board has the
//! device; with no source it opens all the same and its readers wait.
//!
//! **The emulator's mouse** is a source the device keeps itself, on the
//! qemu board only (its mouse part): our QEMU build's display reports the
//! pointer over its window, where it is in the window's pixels, which of
//! its three buttons are down and how far its wheel turned, and the
//! device's task looks at it every 10 ms. That pointer is absolute, so its
//! events carry no IEQUALIFIER_RELATIVEMOUSE. On any other board there is
//! no task and nothing is polled.
//!
//! The first OpenDevice opens timer.device for the time each event
//! carries, and on the qemu board starts the task, which then stays, as
//! keyboard.device's does. A read waiting for the mouse is queued on the
//! unit, so AbortIO and CMD_FLUSH can take it back.

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
/// The emulator's display is there only where QEMU runs the chip: our
/// QEMU is an ESP32-S3's.
const emulated = sdk.hardware.chip == .esp32s3;
const qemu_rgb = if (emulated) sdk.hardware.qemu_rgb else struct {};

pub const DEVICE_NAME = mouse.MOUSENAME;
const DEVICE_VERSION = 1;
/// 1: the wheel (IECODE_WHEEL). 2: sources (MOUSEF_SOURCE,
/// MOUSE_ADDEVENT), and on every board. 4: the emulator's stack is the
/// system's, not the first opener's. 5: the standard stack.
const DEVICE_REVISION = 5;
const BUILD_DATE = "29.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Above ordinary tasks, so the pointer is followed while a program
/// computes.
const task_pri = 10;
/// The standard stack: 32 KiB on a 64-bit machine, 16 KiB on a 32-bit one.
const stack_size = 4096 * @sizeOf(usize);
/// How often the emulator's pointer is looked at.
const poll_us = 10_000;

const MouseBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    /// What the device's task and its callers share - the events queued,
    /// the state, the reads waiting on the unit's list - kept under this:
    /// a spinlock, held a few lines at a time and never across a wait.
    lock: exec.Lock = .{},
    /// Reads waiting for the mouse are on its port's list.
    unit: exec.Unit,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The task is running and has the emulator's mouse.
    ready: u8 = 0,
    /// The emulator's mouse has been looked for.
    started: u8 = 0,
    start_signal: i8 = -1,
    /// timer.device is open for the events' time.
    prepared: u8 = 0,
    starter: ?*exec.Task = null,
    /// Owned by the task.
    port: ?*exec.MsgPort = null,
    timer_io: timer.TimeRequest = .{},
    /// Only ever asked for the time: no request is sent on it.
    clock_io: timer.TimeRequest = .{},
    /// The emulator's count of pointer events when it was last looked at.
    pointer_seq: u32 = 0,
    /// Whether this QEMU gives the wheel (version 0.7 and up).
    wheel: u8 = 0,
    /// What the mice add up to, and the events not yet read.
    mouse: events.Mouse = .{},
    queue: events.Queue = .{},
    /// The buttons the emulator's mouse holds down, as qualifier bits.
    emulator: u32 = 0,
};

/// An open with MOUSEF_SOURCE: its request's unit, and the buttons it
/// holds, as qualifier bits. Allocated at the open, freed at the close.
const Source = extern struct {
    unit: exec.Unit = .{},
    held: u32 = 0,
};

fn mouseBase(dev: *exec.Device) *MouseBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @ptrCast(@alignCast(io));
}

/// The source a request was opened as, or null for a reader's.
fn sourceOf(mb: *MouseBase, io: *exec.IORequest) ?*Source {
    const unit = io.unit orelse return null;
    if (unit == &mb.unit) return null;
    return @alignCast(@fieldParentPtr("unit", unit));
}

fn now(mb: *MouseBase) timer.TimeVal {
    var t: timer.TimeVal = .{};
    const tmb: *TimerBase = @ptrCast(mb.clock_io.node.device.?);
    tmb.GetSysTime(&t);
    return t;
}

// --- the emulator's mouse ---------------------------------------------------------

fn wait(mb: *MouseBase, us: u32) void {
    mb.timer_io.node.command = timer.TR_ADDREQUEST;
    mb.timer_io.time = timer.TimeVal.fromMicros(us);
    _ = mb.sys_base.DoIO(&mb.timer_io.node);
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

/// The emulator's mouse, which the board has.
fn bringUp(mb: *MouseBase) bool {
    const sys = mb.sys_base;
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
    _ = mb.mouse.change(&mb.emulator, nowOf(p), &out);
    mb.wheel = @intFromBool(qemu_rgb.hasWheel());
    if (mb.wheel != 0) _ = qemu_rgb.wheel();
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

/// Reads that were waiting, given what is queued now. Under the device's
/// lock.
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
    const turned = if (mb.wheel != 0) qemu_rgb.wheel() else qemu_rgb.Wheel{ .x = 0, .y = 0 };
    const wheeled = turned.x != 0 or turned.y != 0;
    if (p.seq == mb.pointer_seq and !wheeled) return;
    mb.pointer_seq = p.seq;
    const time = now(mb);
    const sys = mb.sys_base;
    sys.AcquireLock(&mb.lock);
    defer sys.ReleaseLock(&mb.lock);
    var out: [4]InputEvent = undefined;
    const n = mb.mouse.change(&mb.emulator, nowOf(p), &out);
    for (out[0..n]) |*e| {
        e.time = time;
        mb.queue.push(e.*);
    }
    if (wheeled) {
        var e = mb.mouse.wheel(turned.x, turned.y);
        e.time = time;
        mb.queue.push(e);
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

/// The emulator's mouse looked for once, and its task started and waited
/// for if the board has it. A board without it, or a QEMU that gives no
/// pointer, leaves the device with the sources that open it.
fn startEmulator(mb: *MouseBase) void {
    const sys = mb.sys_base;
    if (mb.started != 0) return;
    mb.started = 1;
    if (!emulated or !boardHasIt(sys)) return;
    // The system's, not the first opener's.
    const stack = sys.AllocMem(stack_size, exec.MEMF_ANY | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) {
        sys.FreeMem(stack, stack_size);
        return;
    }
    defer sys.FreeSignal(signal);
    mb.stack = stack;
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
    // A task that found no mouse has ended; its stack stays with the
    // device, as a running task's would.
}

/// timer.device open for the time, once: whether it is.
fn prepare(mb: *MouseBase) bool {
    if (mb.prepared != 0) return true;
    const sys = mb.sys_base;
    mb.clock_io = .{};
    mb.clock_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &mb.clock_io.node, 0) != 0) return false;
    mb.prepared = 1;
    return true;
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
    sys.AcquireLock(&mb.lock);
    defer sys.ReleaseLock(&mb.lock);
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
    sys.AcquireLock(&mb.lock);
    const state = mouse.MouseState{ .x = mb.mouse.x, .y = mb.mouse.y, .qualifier = mb.mouse.qualifier | mb.mouse.relative };
    sys.ReleaseLock(&mb.lock);
    const into: *mouse.MouseState = @ptrCast(@alignCast(std_io.data.?));
    into.* = state;
    std_io.actual = @sizeOf(mouse.MouseState);
}

/// What a source's mouse did into the device: each event through the
/// source's own buttons, what changes for the readers queued.
fn addEvent(mb: *MouseBase, io: *exec.IORequest) void {
    const source = sourceOf(mb, io) orelse {
        io.err = exec.IOERR_NOCMD;
        return;
    };
    const std_io = stdReq(io);
    const each = @sizeOf(InputEvent);
    if (std_io.length % each != 0) {
        io.err = exec.IOERR_BADLENGTH;
        return;
    }
    if (std_io.length == 0) return;
    const data = std_io.data orelse {
        io.err = exec.IOERR_BADADDRESS;
        return;
    };
    const given: [*]const InputEvent = @ptrCast(@alignCast(data));
    const count: usize = @intCast(std_io.length / each);
    const time = now(mb);
    const sys = mb.sys_base;
    sys.AcquireLock(&mb.lock);
    defer sys.ReleaseLock(&mb.lock);
    for (given[0..count]) |*from| {
        var out: [2]InputEvent = undefined;
        const n = mb.mouse.take(&source.held, from, &out);
        for (out[0..n]) |*e| {
            e.time = time;
            mb.queue.push(e.*);
        }
    }
    std_io.actual = std_io.length;
    serveReads(mb);
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
        mouse.MOUSE_ADDEVENT => addEvent(mb, io),
        exec.CMD_CLEAR => {
            sys.AcquireLock(&mb.lock);
            mb.queue.clear();
            sys.ReleaseLock(&mb.lock);
        },
        exec.CMD_FLUSH => flush(mb),
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

/// Every waiting read back, aborted.
fn flush(mb: *MouseBase) void {
    const sys = mb.sys_base;
    sys.AcquireLock(&mb.lock);
    defer sys.ReleaseLock(&mb.lock);
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
    sys.AcquireLock(&mb.lock);
    defer sys.ReleaseLock(&mb.lock);
    if (io.flags & exec.IOF_QUEUED == 0) return -1;
    sys.Remove(&io.message.node);
    io.flags &= ~exec.IOF_QUEUED;
    io.err = exec.IOERR_ABORTED;
    sys.ReplyIO(io);
    return 0;
}

/// Unit 0, as a reader or with MOUSEF_SOURCE as a source. Runs inside the
/// device's own lock, so the first open's setting up is done once.
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const mb = mouseBase(dev);
    const sys = mb.sys_base;
    if (unit_number != 0) return exec.IOERR_OPENFAIL;
    if (io.message.length < @sizeOf(exec.IOStdReq)) return exec.IOERR_OPENFAIL;
    if (!prepare(mb)) return exec.IOERR_OPENFAIL;
    startEmulator(mb);
    if (flags & mouse.MOUSEF_SOURCE != 0) {
        const memory = sys.AllocMem(@sizeOf(Source), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return exec.IOERR_OPENFAIL;
        const source: *Source = @ptrCast(@alignCast(memory));
        source.* = .{};
        source.unit.open_cnt = 1;
        io.unit = &source.unit;
    } else {
        io.unit = &mb.unit;
    }
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    mb.unit.open_cnt += 1;
    return 0;
}

/// A source lets go of the buttons it holds, and its unit goes with it.
fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const mb = mouseBase(dev);
    const sys = mb.sys_base;
    _ = abortIO(dev, io);
    if (sourceOf(mb, io)) |source| {
        const time = now(mb);
        sys.AcquireLock(&mb.lock);
        mb.mouse.letGo(&source.held, &mb.queue, time);
        serveReads(mb);
        sys.ReleaseLock(&mb.lock);
        sys.FreeMem(source, @sizeOf(Source));
    }
    io.unit = null;
    mb.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: on the qemu board its task is the machine's once it
/// has come up, and readers keep it open for good everywhere.
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
    sys_base.InitLock(&mb.lock, DEVICE_NAME, exec.LOCKORDER_DRIVER, 0);
    mb.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    mb.unit.msg_port.msg_list.init(.message);
    mb.mouse = .{};
    mb.queue = .{};
    mb.emulator = 0;
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

/// What the device speaks, for ObtainDeviceUnits (expansion.library),
/// and where its units come from: its one unit, every source's mouse.
const device_speaks = [_]u32{ sdk.expansion.devices.DEVIF_MOUSE, 0 };

/// Cold start; the first open needs timer.device (50), which is up by then.
export const mouse_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&mouse_device_tag),
        .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
        .version = DEVICE_VERSION,
        .pri = 27,
        .type = .device,
        .name = DEVICE_NAME,
        .id_string = DEVICE_VERSION_STRING[1..],
        .init = &init_table,
    },
    .speaks = &device_speaks,
    .units = 1,
};

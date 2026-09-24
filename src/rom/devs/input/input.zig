// SPDX-License-Identifier: MPL-2.0
//! input.device: every input the machine has, as one stream of events down
//! a chain of handlers.
//!
//! The first OpenDevice starts the device's task, and the task opens what
//! it reads from: timer.device twice (the tick and the key repeat),
//! keyboard.device, touch.device and mouse.device. A source that does not
//! open - there is no keyboard or mouse on the board, no panel in the
//! emulator - is simply not read; the device is still there, and IND_WRITEEVENT still
//! feeds the chain. From then on the task keeps a read outstanding on each
//! source and waits:
//!
//!   - a key: the device's qualifiers take the key's, a key that repeats
//!     starts the threshold timer (and a key going up stops its own), the
//!     two keys down before it go in its `x` and `y` for keymap.library's
//!     dead keys, and the event goes down the chain;
//!   - a finger: an IECLASS_TOUCH event, and for the pointer finger an
//!     IECLASS_NEWPOINTERPOS after it (`events.Pointer`), linked, down the
//!     chain as one list;
//!   - the mouse: its IECLASS_RAWMOUSE event, the device's qualifiers taking
//!     the buttons', and for a mouse that says where it is an
//!     IECLASS_NEWPOINTERPOS after it with the same button, linked
//!     (`events.mousePointer`). A mouse that says only how far it went has
//!     no pointer to give; its events go down the chain on their own;
//!   - the repeat timer: the held key again with IEQUALIFIER_REPEAT, and the
//!     period timer started;
//!   - the tick: an IECLASS_TIMER event, ten times a second;
//!   - a command on the unit's port: IND_ADDHANDLER, IND_REMHANDLER and
//!     IND_WRITEEVENT are done here, on the task, so the handler list is only
//!     ever touched by the one task that walks it - a handler is never
//!     called while it is being taken off.
//!
//! Every event gets the system time just before it goes down the chain.
//! IND_SETTHRESH and IND_SETPERIOD are done in BeginIO: they only store a
//! time. The device stays once it is up, as its sources do.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const input = sdk.devices.input;
const ie = sdk.devices.inputevent;
const kb = sdk.devices.keyboard;
const touch = sdk.devices.touch;
const mouse = sdk.devices.mouse;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const TimerBase = timer.TimerBase;
const InputEvent = ie.InputEvent;
const events = @import("events.zig");

pub const DEVICE_NAME = input.INPUTNAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "19.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Above the devices it reads (10) and every program: input is handled
/// before anything that computes.
const task_pri = 20;
const stack_size = 4096;
const tick_us = 100_000;
const thresh_us = 800_000;
const period_us = 100_000;
/// Events taken from a source per read.
const batch = 8;

pub const interface = sdk.interface.input;
pub const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("input.device's lvo" ++ d.name ++ " doesn't match the SDK's Fn." ++ d.name);
        }
        if (vectors[@divExact(-@field(LVO, d.name), exec.slot_size) - 1] != vec(f)) {
            @compileError("input.device's lvo" ++ d.name ++ " isn't in the slot of LVO." ++ d.name);
        }
    }
}

const InputData = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    /// The commands the task does come to its port.
    unit: exec.Unit,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    ready: u8 = 0,
    started: u8 = 0,
    start_signal: i8 = -1,
    /// The repeat timer is running.
    repeating: u8 = 0,
    starter: ?*exec.Task = null,
    /// The handlers, highest priority first.
    handlers: exec.List = .{},
    /// What the device's qualifiers are now: the keys' and the pointer's.
    qualifier: u32 = 0,
    /// The key that repeats while it is held, if any (`repeating` says).
    repeat_code: u32 = 0,
    /// Whether that key is on the keypad.
    repeat_numeric: u32 = 0,
    /// The last two keys down that are not modifiers, the last first, as a
    /// key event's `x` and `y` carry them: what a dead key changes the key
    /// after it by (keymap.library).
    prev1: i32 = 0,
    prev2: i32 = 0,
    thresh: timer.TimeVal = timer.TimeVal.fromMicros(thresh_us),
    period: timer.TimeVal = timer.TimeVal.fromMicros(period_us),
    pointer: events.Pointer = .{},
    /// Owned by the task: the port every source replies to, and the reads.
    port: ?*exec.MsgPort = null,
    tick_io: timer.TimeRequest = .{},
    repeat_io: timer.TimeRequest = .{},
    kbd_io: exec.IOStdReq = .{},
    touch_io: exec.IOStdReq = .{},
    mouse_io: exec.IOStdReq = .{},
    kbd_events: [batch]InputEvent = undefined,
    touch_events: [batch]touch.TouchEvent = undefined,
    mouse_events: [batch]InputEvent = undefined,
    /// The events the task makes itself.
    tick_event: InputEvent = .{},
    repeat_event: InputEvent = .{},
    finger: [2]InputEvent = undefined,
    /// A mouse event and the pointer after it.
    pointer_events: [2]InputEvent = undefined,
};

fn inputData(dev: *exec.Device) *InputData {
    return @alignCast(@fieldParentPtr("dev", dev));
}

fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @ptrCast(@alignCast(io));
}

// --- the task ---------------------------------------------------------------------

fn openTimer(id: *InputData, io: *timer.TimeRequest) bool {
    io.* = .{};
    io.node.message.reply_port = id.port;
    io.node.message.length = @sizeOf(timer.TimeRequest);
    return id.sys_base.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &io.node, 0) == 0;
}

/// A source opened, or left closed (`device` null) if it is not there.
fn openSource(id: *InputData, io: *exec.IOStdReq, name: [*:0]const u8) void {
    io.* = .{};
    io.req.message.reply_port = id.port;
    io.req.message.length = @sizeOf(exec.IOStdReq);
    if (id.sys_base.OpenDevice(name, 0, &io.req, 0) != 0) io.req.device = null;
}

fn startTimer(id: *InputData, io: *timer.TimeRequest, time: timer.TimeVal) void {
    io.node.command = timer.TR_ADDREQUEST;
    io.time = time;
    id.sys_base.SendIO(&io.node);
}

fn readKeyboard(id: *InputData) void {
    const io = &id.kbd_io;
    io.req.command = kb.KBD_READEVENT;
    io.data = &id.kbd_events;
    io.length = @sizeOf(@TypeOf(id.kbd_events));
    id.sys_base.SendIO(&io.req);
}

fn readTouch(id: *InputData) void {
    const io = &id.touch_io;
    io.req.command = touch.TOUCH_READEVENT;
    io.data = &id.touch_events;
    io.length = @sizeOf(@TypeOf(id.touch_events));
    id.sys_base.SendIO(&io.req);
}

fn readMouse(id: *InputData) void {
    const io = &id.mouse_io;
    io.req.command = mouse.MOUSE_READEVENT;
    io.data = &id.mouse_events;
    io.length = @sizeOf(@TypeOf(id.mouse_events));
    id.sys_base.SendIO(&io.req);
}

fn stopRepeat(id: *InputData) void {
    if (id.repeating == 0) return;
    id.repeating = 0;
    _ = id.sys_base.AbortIO(&id.repeat_io.node);
    _ = id.sys_base.WaitIO(&id.repeat_io.node);
}

/// The events stamped with the time and down the chain.
fn dispatch(id: *InputData, list: *InputEvent) void {
    var t: timer.TimeVal = .{};
    const tmb: *TimerBase = @ptrCast(id.tick_io.node.device.?);
    tmb.GetSysTime(&t);
    var e: ?*InputEvent = list;
    while (e) |ev| : (e = ev.next) ev.time = t;
    events.dispatch(&id.handlers, list);
}

fn gotKeys(id: *InputData) void {
    const io = &id.kbd_io;
    if (io.req.err != 0) return; // the keyboard has gone: not read again
    const n: usize = @intCast(io.actual / @sizeOf(InputEvent));
    for (id.kbd_events[0..n]) |*e| {
        id.qualifier = events.keyQualifier(id.qualifier, e.qualifier);
        e.qualifier = (e.qualifier & ~events.key_qualifiers) | id.qualifier;
        const code = e.code & ie.IECODE_KEY_CODE_MASK;
        e.x = id.prev1;
        e.y = id.prev2;
        if (e.code & ie.IECODE_UP_PREFIX == 0) {
            if (events.repeats(code)) {
                id.prev2 = id.prev1;
                id.prev1 = events.prevKey(code, e.qualifier);
                stopRepeat(id);
                id.repeat_code = code;
                id.repeat_numeric = e.qualifier & ie.IEQUALIFIER_NUMERICPAD;
                id.repeating = 1;
                startTimer(id, &id.repeat_io, id.thresh);
            }
        } else if (id.repeating != 0 and code == id.repeat_code) {
            stopRepeat(id);
        }
        e.next = null;
        dispatch(id, e);
    }
    readKeyboard(id);
}

fn gotRepeat(id: *InputData) void {
    if (id.repeating == 0) return;
    id.repeat_event = .{
        .class = ie.IECLASS_RAWKEY,
        .code = id.repeat_code,
        .qualifier = id.qualifier | id.repeat_numeric | ie.IEQUALIFIER_REPEAT,
        .x = id.prev1,
        .y = id.prev2,
    };
    dispatch(id, &id.repeat_event);
    startTimer(id, &id.repeat_io, id.period);
}

fn gotTouch(id: *InputData) void {
    const io = &id.touch_io;
    if (io.req.err != 0) return;
    const n: usize = @intCast(io.actual / @sizeOf(touch.TouchEvent));
    for (id.touch_events[0..n]) |*e| {
        if (id.pointer.take(e, &id.qualifier, &id.finger) == 0) continue;
        dispatch(id, &id.finger[0]);
    }
    readTouch(id);
}

fn gotMouse(id: *InputData) void {
    const io = &id.mouse_io;
    if (io.req.err != 0) return; // the mouse has gone: not read again
    const n: usize = @intCast(io.actual / @sizeOf(InputEvent));
    for (id.mouse_events[0..n]) |*e| {
        _ = events.mousePointer(e, &id.qualifier, &id.pointer_events);
        dispatch(id, &id.pointer_events[0]);
    }
    readMouse(id);
}

fn gotTick(id: *InputData) void {
    id.tick_event = .{ .class = ie.IECLASS_TIMER, .qualifier = id.qualifier };
    dispatch(id, &id.tick_event);
    startTimer(id, &id.tick_io, timer.TimeVal.fromMicros(tick_us));
}

fn command(id: *InputData, io: *exec.IORequest) void {
    const sys = id.sys_base;
    const std_io = stdReq(io);
    switch (io.command) {
        input.IND_ADDHANDLER => sys.Enqueue(&id.handlers, @ptrCast(@alignCast(std_io.data.?))),
        input.IND_REMHANDLER => sys.Remove(@ptrCast(@alignCast(std_io.data.?))),
        input.IND_WRITEEVENT => {
            const e: *InputEvent = @ptrCast(@alignCast(std_io.data.?));
            e.next = null;
            dispatch(id, e);
            std_io.actual = @sizeOf(InputEvent);
        },
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyMsg(&io.message);
}

fn bringUp(id: *InputData) bool {
    const sys = id.sys_base;
    id.port = sys.CreateMsgPort() orelse return false;
    if (!openTimer(id, &id.tick_io)) return false;
    if (!openTimer(id, &id.repeat_io)) return false;
    openSource(id, &id.kbd_io, kb.KEYBOARDNAME);
    openSource(id, &id.touch_io, touch.TOUCHNAME);
    openSource(id, &id.mouse_io, mouse.MOUSENAME);
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    // The unit's port signals the task from now on.
    id.unit.msg_port.sig_bit = @intCast(signal);
    id.unit.msg_port.sig_task = &id.task;
    id.unit.msg_port.flags = exec.PA_SIGNAL;
    return true;
}

fn giveBack(id: *InputData) void {
    const sys = id.sys_base;
    for ([_]*exec.IORequest{ &id.mouse_io.req, &id.touch_io.req, &id.kbd_io.req, &id.repeat_io.node, &id.tick_io.node }) |io| {
        if (io.device != null) sys.CloseDevice(io);
    }
    sys.DeleteMsgPort(id.port);
    id.port = null;
}

fn inputTask(sys: *ExecBase) callconv(.c) void {
    const id: *InputData = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const ok = bringUp(id);
    if (ok) id.ready = 1 else giveBack(id);
    if (id.starter) |starter| {
        id.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(id.start_signal));
    }
    if (!ok) return;

    const port = id.port.?;
    startTimer(id, &id.tick_io, timer.TimeVal.fromMicros(tick_us));
    if (id.kbd_io.req.device != null) readKeyboard(id);
    if (id.touch_io.req.device != null) readTouch(id);
    if (id.mouse_io.req.device != null) readMouse(id);
    const mask = port.sigMask() | id.unit.msg_port.sigMask();
    while (true) {
        _ = sys.Wait(mask);
        while (sys.GetMsg(port)) |msg| {
            const io: *exec.IORequest = @ptrCast(msg);
            if (io == &id.tick_io.node) {
                gotTick(id);
            } else if (io == &id.repeat_io.node) {
                gotRepeat(id);
            } else if (io == &id.kbd_io.req) {
                gotKeys(id);
            } else if (io == &id.touch_io.req) {
                gotTouch(id);
            } else if (io == &id.mouse_io.req) {
                gotMouse(id);
            }
        }
        while (sys.GetMsg(&id.unit.msg_port)) |msg| command(id, @ptrCast(msg));
    }
}

/// The task started and waited for; true if it came up.
fn start(id: *InputData) bool {
    const sys = id.sys_base;
    if (id.started != 0) return id.ready != 0;
    const stack = id.stack orelse blk: {
        const s = sys.AllocMem(stack_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
        id.stack = s;
        break :blk s;
    };
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    defer sys.FreeSignal(signal);
    id.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    id.starter = sys.FindTask(null);
    id.start_signal = signal;
    id.ready = 0;
    _ = sys.AddTask(&id.task, &inputTask, null);
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    if (id.ready != 0) id.started = 1;
    return id.ready != 0;
}

// --- the device --------------------------------------------------------------------

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const id = inputData(dev);
    const sys = id.sys_base;
    const std_io = stdReq(io);
    io.err = 0;
    std_io.actual = 0;
    switch (io.command) {
        input.IND_ADDHANDLER, input.IND_REMHANDLER, input.IND_WRITEEVENT => {
            if (std_io.data == null) {
                io.err = exec.IOERR_BADADDRESS;
            } else if (io.command == input.IND_WRITEEVENT and std_io.length < @sizeOf(InputEvent)) {
                io.err = exec.IOERR_BADLENGTH;
            } else {
                // The task does these, so the chain is only touched by it.
                io.flags &= ~exec.IOF_QUICK;
                sys.PutMsg(&id.unit.msg_port, &io.message);
                return;
            }
        },
        input.IND_SETTHRESH, input.IND_SETPERIOD => {
            const tr: *timer.TimeRequest = @ptrCast(@alignCast(io));
            sys.Forbid();
            if (io.command == input.IND_SETTHRESH) id.thresh = tr.time else id.period = tr.time;
            sys.Permit();
        },
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

/// A command waiting for the task is taken back; one the task has, or has
/// done, is not.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const id = inputData(dev);
    const sys = id.sys_base;
    sys.Forbid();
    defer sys.Permit();
    var it = id.unit.msg_port.msg_list.iterator();
    while (it.next()) |n| {
        if (n != &io.message.node) continue;
        sys.Remove(n);
        io.err = exec.IOERR_ABORTED;
        sys.ReplyMsg(&io.message);
        return 0;
    }
    return -1;
}

fn lvoPeekQualifier(id: *InputData) callconv(.c) u32 {
    return id.qualifier;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const id = inputData(dev);
    if (unit_number != 0) return exec.IOERR_OPENFAIL;
    if (io.message.length < @sizeOf(exec.IOStdReq)) return exec.IOERR_OPENFAIL;
    if (!start(id)) return exec.IOERR_OPENFAIL;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    id.unit.open_cnt += 1;
    io.unit = &id.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const id = inputData(dev);
    _ = io;
    id.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays: its task and its sources are the machine's once up.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    _ = seg_list;
    dev.revision = DEVICE_REVISION;
    const id = inputData(dev);
    id.sys_base = sys_base;
    // Commands wait here for the task; until it runs nothing is signalled.
    id.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    id.unit.msg_port.msg_list.init(.message);
    id.handlers.init(.interrupt);
    id.thresh = timer.TimeVal.fromMicros(thresh_us);
    id.period = timer.TimeVal.fromMicros(period_us);
    id.pointer = .{};
    return dev;
}

const vectors = [_]*const anyopaque{
    vec(open),
    vec(close),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
    vec(lvoPeekQualifier),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(InputData),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// Cold start below keyboard.device (27) and touch.device (28), which the
/// first open reads from.
export const input_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &input_device_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 26,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..],
    .init = &init_table,
};

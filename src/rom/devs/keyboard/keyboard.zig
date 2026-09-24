// SPDX-License-Identifier: MPL-2.0
//! keyboard.device: the keys, as rawkey InputEvents.
//!
//! A key is handed out as its rawkey - its place on the keyboard, 0x00 to
//! 0x77, with IECODE_UP_PREFIX when it went up - and the qualifiers as they
//! are after it. What a key means is a keymap's business, above the device.
//! The device keeps which keys are down (KBD_READMATRIX) and queues events
//! until a KBD_READEVENT takes them.
//!
//! The one keyboard there is now is the emulator's: our QEMU build's display
//! queues the keys typed into its window, by Linux keycode, and the device's
//! task drains that queue every 10 ms. It is the qemu board's keyboard
//! part; a board without one has no keyboard.device in its ROM, and an
//! open without the part fails. A keyboard on a board later is a second
//! backend feeding
//! the same `rawkey.Keys`, as mouse.device leaves room for a mouse on the
//! board beside the emulator's.
//!
//! Nothing runs until the first OpenDevice starts the task; from then on the
//! task stays, as touch.device's does. A read waiting for a key is queued on
//! the unit, so AbortIO and CMD_FLUSH can take it back.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const kb = sdk.devices.keyboard;
const ie = sdk.devices.inputevent;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const TimerBase = timer.TimerBase;
const InputEvent = ie.InputEvent;
const rawkey = @import("rawkey.zig");
const qemu_rgb = sdk.hardware.qemu_rgb;

pub const DEVICE_NAME = kb.KEYBOARDNAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "19.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Above ordinary tasks, so a key is taken while a program computes.
const task_pri = 10;
const stack_size = 4096;
/// How often the emulator's queue is looked at.
const poll_us = 10_000;

const KeyboardBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    /// Reads waiting for a key are on its port's list.
    unit: exec.Unit,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The task is running and has a keyboard.
    ready: u8 = 0,
    /// The task has been started.
    started: u8 = 0,
    start_signal: i8 = -1,
    pad: u8 = 0,
    starter: ?*exec.Task = null,
    /// Owned by the task.
    port: ?*exec.MsgPort = null,
    timer_io: timer.TimeRequest = .{},
    /// What the keys add up to, and the events not yet read.
    keys: rawkey.Keys = .{},
    queue: rawkey.Queue = .{},
};

fn keyboardBase(dev: *exec.Device) *KeyboardBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @ptrCast(@alignCast(io));
}

// --- the task ---------------------------------------------------------------------

fn wait(kbb: *KeyboardBase, us: u32) void {
    kbb.timer_io.node.command = timer.TR_ADDREQUEST;
    kbb.timer_io.time = timer.TimeVal.fromMicros(us);
    _ = kbb.sys_base.DoIO(&kbb.timer_io.node);
}

fn now(kbb: *KeyboardBase) timer.TimeVal {
    var t: timer.TimeVal = .{};
    const tmb: *TimerBase = @ptrCast(kbb.timer_io.node.device.?);
    tmb.GetSysTime(&t);
    return t;
}

/// Whether the board has the emulator's keyboard: its part in the board's
/// system tag list.
fn boardHasIt(sys: *ExecBase) bool {
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return false;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const st = sdk.expansion.systemtags;
    return eb.FindBoardPart(null, st.PARTKIND_KEYBOARD, st.CHIP_QEMU_DISPLAY) != null;
}

/// The emulator's keyboard, if the board has one.
fn bringUp(kbb: *KeyboardBase) bool {
    const sys = kbb.sys_base;
    if (!boardHasIt(sys)) {
        exec.kprintf(sys, "%s: this board has no keyboard\n", .{DEVICE_NAME});
        return false;
    }
    if (!qemu_rgb.hasKeyboard()) {
        exec.kprintf(sys, "%s: this QEMU gives no keys (build it with scripts/build-qemu.sh)\n", .{DEVICE_NAME});
        return false;
    }
    kbb.port = sys.CreateMsgPort() orelse return false;
    kbb.timer_io = .{};
    kbb.timer_io.node.message.reply_port = kbb.port;
    kbb.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &kbb.timer_io.node, 0) != 0) return false;
    // Whatever was typed before anyone listened is not a key for them.
    while (qemu_rgb.key() != null) {}
    return true;
}

fn giveBack(kbb: *KeyboardBase) void {
    const sys = kbb.sys_base;
    if (kbb.timer_io.node.device != null) sys.CloseDevice(&kbb.timer_io.node);
    sys.DeleteMsgPort(kbb.port);
    kbb.port = null;
}

/// Reads that were waiting, given what is queued now. Under Forbid.
fn serveReads(kbb: *KeyboardBase) void {
    const sys = kbb.sys_base;
    const list = &kbb.unit.msg_port.msg_list;
    while (kbb.queue.count > 0) {
        const node = list.head orelse break;
        if (node.succ == null) break;
        const io: *exec.IORequest = @ptrCast(@alignCast(node));
        sys.Remove(node);
        io.flags &= ~exec.IOF_QUEUED;
        const std_io = stdReq(io);
        const room = std_io.length / @sizeOf(InputEvent);
        const into: [*]InputEvent = @ptrCast(@alignCast(std_io.data.?));
        const n = kbb.queue.take(into[0..@intCast(room)]);
        std_io.actual = n * @sizeOf(InputEvent);
        sys.ReplyIO(io);
    }
}

/// Every key the emulator has queued, as events.
fn poll(kbb: *KeyboardBase) void {
    const first = qemu_rgb.key() orelse return;
    const time = now(kbb);
    const sys = kbb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    var k: ?qemu_rgb.Key = first;
    while (k) |key| : (k = qemu_rgb.key()) {
        const code = rawkey.fromLinux(key.code) orelse continue;
        var e = kbb.keys.press(code, key.down);
        e.time = time;
        kbb.queue.push(e);
    }
    serveReads(kbb);
}

fn keyboardTask(sys: *ExecBase) callconv(.c) void {
    const kbb: *KeyboardBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const ok = bringUp(kbb);
    if (ok) kbb.ready = 1 else giveBack(kbb);
    if (kbb.starter) |starter| {
        kbb.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(kbb.start_signal));
    }
    if (!ok) return;
    while (true) {
        wait(kbb, poll_us);
        poll(kbb);
    }
}

/// The task started and waited for; true if there is a keyboard.
fn start(kbb: *KeyboardBase) bool {
    const sys = kbb.sys_base;
    if (kbb.started != 0) return kbb.ready != 0;
    const stack = kbb.stack orelse blk: {
        const s = sys.AllocMem(stack_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
        kbb.stack = s;
        break :blk s;
    };
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    defer sys.FreeSignal(signal);
    kbb.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    kbb.starter = sys.FindTask(null);
    kbb.start_signal = signal;
    kbb.ready = 0;
    _ = sys.AddTask(&kbb.task, &keyboardTask, null);
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    // A task that found no keyboard has ended; the next open tries again.
    if (kbb.ready != 0) kbb.started = 1;
    return kbb.ready != 0;
}

// --- the device --------------------------------------------------------------------

fn readEvent(kbb: *KeyboardBase, io: *exec.IORequest) bool {
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
    const sys = kbb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    if (kbb.queue.count > 0) {
        const into: [*]InputEvent = @ptrCast(@alignCast(std_io.data.?));
        const n = kbb.queue.take(into[0..@intCast(std_io.length / each)]);
        std_io.actual = n * each;
        return true;
    }
    // Nothing yet: it waits on the unit for the next key.
    io.flags &= ~exec.IOF_QUICK;
    io.flags |= exec.IOF_QUEUED;
    // A queued request is a message again, as PutMsg would make it:
    // WaitIO looks at the node's type, and the reply left there by
    // its last use would let a caller past before this one has run.
    io.message.node.type = .message;
    sys.AddTail(&kbb.unit.msg_port.msg_list, &io.message.node);
    return false;
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const kbb = keyboardBase(dev);
    const sys = kbb.sys_base;
    const std_io = stdReq(io);
    io.err = 0;
    std_io.actual = 0;
    switch (io.command) {
        kb.KBD_READEVENT => if (!readEvent(kbb, io)) return,
        kb.KBD_READMATRIX => {
            if (std_io.data == null) {
                io.err = exec.IOERR_BADADDRESS;
            } else {
                const n: usize = @min(@as(usize, @intCast(std_io.length)), kb.MATRIX_BYTES);
                const to: [*]u8 = @ptrCast(std_io.data.?);
                sys.Forbid();
                for (0..n) |i| to[i] = kbb.keys.matrix[i];
                sys.Permit();
                std_io.actual = n;
            }
        },
        exec.CMD_CLEAR => {
            sys.Forbid();
            kbb.queue.clear();
            sys.Permit();
        },
        exec.CMD_FLUSH => flush(kbb),
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

/// Every waiting read back, aborted.
fn flush(kbb: *KeyboardBase) void {
    const sys = kbb.sys_base;
    sys.Forbid();
    defer sys.Permit();
    const list = &kbb.unit.msg_port.msg_list;
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
    const kbb = keyboardBase(dev);
    const sys = kbb.sys_base;
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
    const kbb = keyboardBase(dev);
    if (unit_number != 0) return exec.IOERR_OPENFAIL;
    if (io.message.length < @sizeOf(exec.IOStdReq)) return exec.IOERR_OPENFAIL;
    if (!start(kbb)) return exec.IOERR_OPENFAIL;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    kbb.unit.open_cnt += 1;
    io.unit = &kbb.unit;
    return 0;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const kbb = keyboardBase(dev);
    _ = abortIO(dev, io);
    kbb.unit.open_cnt -= 1;
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
    const kbb = keyboardBase(dev);
    kbb.sys_base = sys_base;
    kbb.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    kbb.unit.msg_port.msg_list.init(.message);
    kbb.keys = .{};
    kbb.queue = .{};
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
    .data_size = @sizeOf(KeyboardBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// Cold start; the first open needs timer.device (50), which is up by then.
export const keyboard_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &keyboard_device_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 27,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..],
    .init = &init_table,
};

// SPDX-License-Identifier: MPL-2.0
//! keyboard.device: the keys, as rawkey InputEvents.
//!
//! A key is handed out as its rawkey - its place on the keyboard, 0x00 to
//! 0x77, with IECODE_UP_PREFIX when it went up - and the qualifiers as they
//! are after it. What a key means is a keymap's business, above the device.
//! The device keeps which keys are down (KBD_READMATRIX) and queues events
//! until a KBD_READEVENT takes them.
//!
//! **The keys come from sources.** A keyboard's driver opens the device
//! with KBDF_SOURCE and gets a unit of its own, a `Source`, which keeps the
//! keys it holds down; it hands keys over with KBD_ADDEVENT, and they go
//! through the same `rawkey.Keys` as every other source's, so readers see
//! one keyboard whichever keys came from where. A key two sources hold is
//! down once (`Keys.pressFrom` counts the holders), and a source that
//! closes lets go of what it still holds (`Keys.letGo`). Every board has
//! the device; with no source it opens all the same and its readers wait.
//!
//! **The emulator's keyboard** is a source the device keeps itself, on the
//! qemu board only (its keyboard part): our QEMU build's display queues the
//! keys typed into its window, by Linux keycode, and the device's task
//! drains that queue every 10 ms. On any other board there is no task and
//! nothing is polled.
//!
//! The first OpenDevice opens timer.device for the time each event
//! carries, and on the qemu board starts the task, which then stays, as
//! touch.device's does. A read waiting for a key is queued on the unit, so
//! AbortIO and CMD_FLUSH can take it back.

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
/// The emulator's display is there only where QEMU runs the chip: our
/// QEMU is an ESP32-S3's.
const emulated = sdk.hardware.chip == .esp32s3;
const qemu_rgb = if (emulated) sdk.hardware.qemu_rgb else struct {};

pub const DEVICE_NAME = kb.KEYBOARDNAME;
const DEVICE_VERSION = 1;
/// 1: sources (KBDF_SOURCE, KBD_ADDEVENT, KBD_READSOURCES), and on every
/// board. 2: the emulator's stack is the system's, not the first
/// opener's. 3: the standard stack.
const DEVICE_REVISION = 3;
const BUILD_DATE = "29.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Above ordinary tasks, so a key is taken while a program computes.
const task_pri = 10;
/// The standard stack: 32 KiB on a 64-bit machine, 16 KiB on a 32-bit one.
const stack_size = 4096 * @sizeOf(usize);
/// How often the emulator's queue is looked at.
const poll_us = 10_000;

const KeyboardBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    /// What the device's task and its callers share - the events queued,
    /// the state, the reads waiting on the unit's list - kept under this:
    /// a spinlock, held a few lines at a time and never across a wait.
    lock: exec.Lock = .{},
    /// Reads waiting for a key are on its port's list.
    unit: exec.Unit,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    /// The task is running and has the emulator's keyboard.
    ready: u8 = 0,
    /// The emulator's keyboard has been looked for.
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
    /// What the keys add up to, and the events not yet read.
    keys: rawkey.Keys = .{},
    queue: rawkey.Queue = .{},
    /// The keys the emulator's keyboard holds down.
    emulator: rawkey.Held = @splat(0),
    /// The sources open (KBDF_SOURCE), for KBD_READSOURCES.
    sources: u32 = 0,
};

/// An open with KBDF_SOURCE: its request's unit, and the keys it holds.
/// Allocated at the open, freed at the close.
const Source = extern struct {
    unit: exec.Unit = .{},
    held: rawkey.Held = @splat(0),
};

fn keyboardBase(dev: *exec.Device) *KeyboardBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

fn stdReq(io: *exec.IORequest) *exec.IOStdReq {
    return @ptrCast(@alignCast(io));
}

/// The source a request was opened as, or null for a reader's.
fn sourceOf(kbb: *KeyboardBase, io: *exec.IORequest) ?*Source {
    const unit = io.unit orelse return null;
    if (unit == &kbb.unit) return null;
    return @alignCast(@fieldParentPtr("unit", unit));
}

fn now(kbb: *KeyboardBase) timer.TimeVal {
    var t: timer.TimeVal = .{};
    const tmb: *TimerBase = @ptrCast(kbb.clock_io.node.device.?);
    tmb.GetSysTime(&t);
    return t;
}

/// Reads that were waiting, given what is queued now. Under the device's
/// lock.
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

// --- the emulator's keyboard ------------------------------------------------------

fn wait(kbb: *KeyboardBase, us: u32) void {
    kbb.timer_io.node.command = timer.TR_ADDREQUEST;
    kbb.timer_io.time = timer.TimeVal.fromMicros(us);
    _ = kbb.sys_base.DoIO(&kbb.timer_io.node);
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

/// The emulator's keyboard, which the board has.
fn bringUp(kbb: *KeyboardBase) bool {
    const sys = kbb.sys_base;
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

/// Every key the emulator has queued, as events.
fn poll(kbb: *KeyboardBase) void {
    const first = qemu_rgb.key() orelse return;
    const time = now(kbb);
    const sys = kbb.sys_base;
    sys.AcquireLock(&kbb.lock);
    defer sys.ReleaseLock(&kbb.lock);
    var k: ?qemu_rgb.Key = first;
    while (k) |key| : (k = qemu_rgb.key()) {
        const code = rawkey.fromLinux(key.code) orelse continue;
        var e = kbb.keys.pressFrom(&kbb.emulator, code, key.down) orelse continue;
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

/// The emulator's keyboard looked for once, and its task started and
/// waited for if the board has it. A board without it, or a QEMU that
/// gives no keys, leaves the device with the sources that open it.
fn startEmulator(kbb: *KeyboardBase) void {
    const sys = kbb.sys_base;
    if (kbb.started != 0) return;
    kbb.started = 1;
    if (!emulated or !boardHasIt(sys)) return;
    // The system's, not the first opener's.
    const stack = sys.AllocMem(stack_size, exec.MEMF_ANY | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) {
        sys.FreeMem(stack, stack_size);
        return;
    }
    defer sys.FreeSignal(signal);
    kbb.stack = stack;
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
    // A task that found no keyboard has ended; its stack stays with the
    // device, as a running task's would.
}

/// timer.device open for the time, once: whether it is.
fn prepare(kbb: *KeyboardBase) bool {
    if (kbb.prepared != 0) return true;
    const sys = kbb.sys_base;
    kbb.clock_io = .{};
    kbb.clock_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &kbb.clock_io.node, 0) != 0) return false;
    kbb.prepared = 1;
    return true;
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
    sys.AcquireLock(&kbb.lock);
    defer sys.ReleaseLock(&kbb.lock);
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

/// A source's keys into the device: each rawkey event through the
/// source's own `Held`, what changes for the readers queued.
fn addEvent(kbb: *KeyboardBase, io: *exec.IORequest) void {
    const source = sourceOf(kbb, io) orelse {
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
    const time = now(kbb);
    const sys = kbb.sys_base;
    sys.AcquireLock(&kbb.lock);
    defer sys.ReleaseLock(&kbb.lock);
    for (given[0..count]) |*from| {
        if (from.class != ie.IECLASS_RAWKEY) continue;
        const code: u8 = @intCast(from.code & ie.IECODE_KEY_CODE_MASK);
        const down = from.code & ie.IECODE_UP_PREFIX == 0;
        var e = kbb.keys.pressFrom(&source.held, code, down) orelse continue;
        e.time = time;
        kbb.queue.push(e);
    }
    std_io.actual = std_io.length;
    serveReads(kbb);
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
                sys.AcquireLock(&kbb.lock);
                for (0..n) |i| to[i] = kbb.keys.matrix[i];
                sys.ReleaseLock(&kbb.lock);
                std_io.actual = n;
            }
        },
        kb.KBD_ADDEVENT => addEvent(kbb, io),
        kb.KBD_READSOURCES => std_io.actual = kbb.sources + @as(u32, kbb.ready),
        exec.CMD_CLEAR => {
            sys.AcquireLock(&kbb.lock);
            kbb.queue.clear();
            sys.ReleaseLock(&kbb.lock);
        },
        exec.CMD_FLUSH => flush(kbb),
        else => io.err = exec.IOERR_NOCMD,
    }
    sys.ReplyIO(io);
}

/// Every waiting read back, aborted.
fn flush(kbb: *KeyboardBase) void {
    const sys = kbb.sys_base;
    sys.AcquireLock(&kbb.lock);
    defer sys.ReleaseLock(&kbb.lock);
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
    sys.AcquireLock(&kbb.lock);
    defer sys.ReleaseLock(&kbb.lock);
    if (io.flags & exec.IOF_QUEUED == 0) return -1;
    sys.Remove(&io.message.node);
    io.flags &= ~exec.IOF_QUEUED;
    io.err = exec.IOERR_ABORTED;
    sys.ReplyIO(io);
    return 0;
}

/// Unit 0, as a reader or with KBDF_SOURCE as a source. Runs inside the
/// device's own lock, so the first open's setting up is done once.
fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const kbb = keyboardBase(dev);
    const sys = kbb.sys_base;
    if (unit_number != 0) return exec.IOERR_OPENFAIL;
    if (io.message.length < @sizeOf(exec.IOStdReq)) return exec.IOERR_OPENFAIL;
    if (!prepare(kbb)) return exec.IOERR_OPENFAIL;
    startEmulator(kbb);
    if (flags & kb.KBDF_SOURCE != 0) {
        const memory = sys.AllocMem(@sizeOf(Source), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return exec.IOERR_OPENFAIL;
        const source: *Source = @ptrCast(@alignCast(memory));
        source.* = .{};
        source.unit.open_cnt = 1;
        io.unit = &source.unit;
        kbb.sources += 1;
    } else {
        io.unit = &kbb.unit;
    }
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    kbb.unit.open_cnt += 1;
    return 0;
}

/// A source lets go of the keys it holds, and its unit goes with it.
fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const kbb = keyboardBase(dev);
    const sys = kbb.sys_base;
    _ = abortIO(dev, io);
    if (sourceOf(kbb, io)) |source| {
        const time = now(kbb);
        sys.AcquireLock(&kbb.lock);
        kbb.keys.letGo(&source.held, &kbb.queue, time);
        serveReads(kbb);
        sys.ReleaseLock(&kbb.lock);
        sys.FreeMem(source, @sizeOf(Source));
        kbb.sources -= 1;
    }
    io.unit = null;
    kbb.unit.open_cnt -= 1;
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
    const kbb = keyboardBase(dev);
    kbb.sys_base = sys_base;
    sys_base.InitLock(&kbb.lock, DEVICE_NAME, exec.LOCKORDER_DRIVER, 0);
    kbb.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
    kbb.unit.msg_port.msg_list.init(.message);
    kbb.keys = .{};
    kbb.queue = .{};
    kbb.emulator = @splat(0);
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

/// What the device speaks, for ObtainDeviceUnits (expansion.library),
/// and where its units come from: its one unit, every source's keys.
const device_speaks = [_]u32{ sdk.expansion.devices.DEVIF_KEYBOARD, 0 };

/// Cold start; the first open needs timer.device (50), which is up by then.
export const keyboard_device_tag: exec.ResidentDevice linksection(".resident") = .{
    .resident = .{
        .match_tag = @ptrCast(&keyboard_device_tag),
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

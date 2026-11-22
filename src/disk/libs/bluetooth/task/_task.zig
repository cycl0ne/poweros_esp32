// SPDX-License-Identifier: MIT
//! The library's task: a process that owns every controller - opens its
//! device, keeps reads queued on it, hands each packet to its HCI and
//! sends what the HCI sends - and runs their time-outs. It spends its
//! life in one Wait on its two ports, the calls' commands and its
//! requests' answers (the controllers' and its timer's), so an idle
//! controller costs nothing.
//!
//! **Its life.** It is started by the first controller added and ends
//! when the last is removed. While it runs it holds the library open:
//! its starter hands it an open count, and dos closes it once the task's
//! code has returned (NP_HoldLibrary). A call puts its command on the
//! task's port under the base's `start_lock`, and the task decides to end
//! under it too, with its port empty: so no command is left on the port
//! of a task that has ended.
//!
//! **Time-outs.** Its timer is out while any command of any controller
//! waits for its answer, due when the earliest of them is.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const hcidev = sdk.devices.hci;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const TimerBase = sdk.interface.timer.TimerBase;
const _base = @import("../bluetooth_base.zig");
const BluetoothBase = _base.BluetoothBase;
const _controller = @import("../controller/_controller.zig");
const Controller = _controller.Controller;
const _hci = @import("../hci/_hci.zig");
const _notify = @import("../notify/_notify.zig");
const device = @import("device.zig");

const task_name = "bluetooth.library";
const stack_bytes = 8192;

/// What the controllers show others until they are told otherwise: a
/// desktop computer, named as the machine is on the network - or, with no
/// name there, so.
const class_of_device = hci.COD_MAJOR_COMPUTER << 8 | hci.COD_COMPUTER_DESKTOP << 2;
const hostname_file = sdk.bsdsocket.HOSTNAME_FILE;
const default_name = "PowerOS";

/// A call's command to the task.
pub const Command = extern struct {
    message: exec.Message = .{},
    kind: Kind = .add,
    unit: u32 = 0,
    device_name: [*:0]const u8 = "",
    /// What the call answers.
    result: i32 = 0,

    pub const Kind = enum(u32) { add, remove };
};

/// The task's own: its ports, its timer.
const Work = struct {
    base: *BluetoothBase,
    commands: *exec.MsgPort,
    replies: *exec.MsgPort,
    timer_io: timer.TimeRequest = .{},
    timer_open: bool = false,
    timer_out: bool = false,
    /// When the timer out is due, in milliseconds.
    timer_due: u64 = 0,
};

/// A command handed to the task, which is started if it does not run,
/// and its answer waited for: false if the task could not be started.
/// On a process.
pub fn ask(base: *BluetoothBase, command: *Command) bool {
    const sys = base.sys_base;
    const reply = sys.CreateMsgPort() orelse return false;
    defer sys.DeleteMsgPort(reply);
    command.message.reply_port = reply;
    command.message.length = @sizeOf(Command);
    sys.ObtainSemaphore(&base.start_lock);
    if (base.port == null and !startLocked(base)) {
        sys.ReleaseSemaphore(&base.start_lock);
        return false;
    }
    sys.PutMsg(base.port.?, &command.message);
    sys.ReleaseSemaphore(&base.start_lock);
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
    return true;
}

/// Whether the task runs; a command for a task that does not, which
/// would have nothing to act on, is not sent.
pub fn running(base: *BluetoothBase) bool {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.start_lock);
    defer sys.ReleaseSemaphore(&base.start_lock);
    return base.port != null;
}

/// The task started, under `start_lock`, and waited for until it is
/// ready: false if it could not be.
fn startLocked(base: *BluetoothBase) bool {
    const sys = base.sys_base;
    const dos_base = base.dos orelse blk: {
        const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return false;
        base.dos = @ptrCast(lib);
        break :blk base.dos.?;
    };
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    defer sys.FreeSignal(signal);
    base.starter = sys.FindTask(null);
    base.start_signal = signal;
    // The open count the task holds, taken here and handed to dos with it.
    holdLibrary(base, 1);
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&taskMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(@as([*:0]const u8, task_name)) },
        .{ .tag = dos.NP_StackSize, .data = stack_bytes },
        .{ .tag = dos.NP_Priority, .data = @as(usize, @bitCast(@as(isize, _base.task_pri))) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(base) },
        .{ .tag = dos.NP_HoldLibrary, .data = @intFromPtr(&base.lib) },
        .{},
    };
    if (dos_base.CreateNewProc(&tags) == null) {
        holdLibrary(base, -1);
        base.starter = null;
        return false;
    }
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    base.starter = null;
    return base.port != null;
}

/// The library's open count changed by `by`, under the library's own lock:
/// what OpenLibrary and CloseLibrary change it under.
fn holdLibrary(base: *BluetoothBase, by: i32) void {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lib.lock);
    defer sys.ReleaseSemaphore(&base.lib.lock);
    if (by > 0) base.lib.open_cnt += 1 else base.lib.open_cnt -= 1;
}

/// The starter told the task is ready, or could not be.
fn started(base: *BluetoothBase) void {
    const starter = base.starter orelse return;
    base.sys_base.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
}

fn taskMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const base: *BluetoothBase = @ptrCast(@alignCast(me.user_data orelse return));
    const work = makeWork(base) orelse {
        // An open count was handed over that dos gives back: the starter
        // sees no port and says it could not start.
        started(base);
        return;
    };
    base.task = me;
    base.port = work.commands;
    started(base);
    const mask = (@as(u32, 1) << @intCast(work.commands.sig_bit)) | (@as(u32, 1) << @intCast(work.replies.sig_bit));
    while (true) {
        var worked = true;
        while (worked) {
            worked = false;
            while (sys.GetMsg(work.commands)) |message| {
                const command: *Command = @fieldParentPtr("message", message);
                switch (command.kind) {
                    .add => command.result = add(work, command.device_name, command.unit),
                    .remove => remove(work, command.device_name, command.unit),
                }
                sys.ReplyMsg(message);
                worked = true;
            }
            while (sys.GetMsg(work.replies)) |message| {
                replied(work, message);
                worked = true;
            }
        }
        report(work);
        armTimer(work);
        if (ending(work)) break;
        _ = sys.Wait(mask);
    }
    unmakeWork(work);
}

fn makeWork(base: *BluetoothBase) ?*Work {
    const sys = base.sys_base;
    const memory = sys.AllocVec(@sizeOf(Work), exec.MEMF_CLEAR) orelse return null;
    const work: *Work = @ptrCast(@alignCast(memory));
    const commands = sys.CreateMsgPort() orelse {
        sys.FreeVec(memory);
        return null;
    };
    const replies = sys.CreateMsgPort() orelse {
        sys.DeleteMsgPort(commands);
        sys.FreeVec(memory);
        return null;
    };
    work.* = .{ .base = base, .commands = commands, .replies = replies };
    work.timer_io.node.message.reply_port = replies;
    work.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &work.timer_io.node, 0) != 0) {
        sys.DeleteMsgPort(replies);
        sys.DeleteMsgPort(commands);
        sys.FreeVec(memory);
        return null;
    }
    work.timer_open = true;
    return work;
}

fn unmakeWork(work: *Work) void {
    const sys = work.base.sys_base;
    if (work.timer_out) {
        _ = sys.AbortIO(&work.timer_io.node);
        _ = sys.WaitIO(&work.timer_io.node);
    }
    if (work.timer_open) sys.CloseDevice(&work.timer_io.node);
    sys.DeleteMsgPort(work.replies);
    sys.DeleteMsgPort(work.commands);
    sys.FreeVec(work);
}

/// Whether the task ends now: no controller left and no command waiting,
/// looked at under `start_lock`, which a caller holds to put one on the
/// port. Its port is no one's from then on.
fn ending(work: *Work) bool {
    const base = work.base;
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.start_lock);
    defer sys.ReleaseSemaphore(&base.start_lock);
    if (!base.controllers.isEmpty() or !work.commands.msg_list.isEmpty()) return false;
    base.port = null;
    base.task = null;
    return true;
}

/// The time in milliseconds, from the E-clock.
fn now(work: *Work) u64 {
    if (!work.timer_open) return 0;
    const timer_base: *TimerBase = @ptrCast(@alignCast(work.timer_io.node.device.?));
    var clock: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&clock);
    if (rate < 1000) return 0;
    return clock.toTicks() / (rate / 1000);
}

// --- the calls' commands --------------------------------------------------------

/// A controller made, its device opened, its reads sent and its bring-up
/// begun: its number, or BTERR_*. One already there answers its own; one
/// whose device is still setting it up (HCIERR_NOTREADY) is kept unopened
/// and opened when the device offers it - this command again. One the
/// device offers that still does not open is one it could not set up: it
/// stays on the list, failed, so that its listers see why.
fn add(work: *Work, device_name: [*:0]const u8, unit: u32) i32 {
    const base = work.base;
    const sys = base.sys_base;
    if (_controller.find(base, device_name, unit)) |known| {
        if (known.open) return @intCast(known.id);
        if (device.open(known, work.replies) != 0) {
            sys.ObtainSemaphore(&base.lock);
            _hci.fail(&known.layer, bluetooth.BTERR_OPENFAIL);
            sys.ReleaseSemaphore(&base.lock);
            return bluetooth.BTERR_OPENFAIL;
        }
        bringUp(work, known);
        return @intCast(known.id);
    }
    const memory = sys.AllocVec(@sizeOf(Controller), exec.MEMF_CLEAR) orelse return bluetooth.BTERR_NOMEM;
    const controller: *Controller = @ptrCast(@alignCast(memory));
    controller.* = .{ .base = base, .unit = unit, .layer = .{ .port = device.port(controller) } };
    _controller.copyString(&controller.device_name, device_name);
    const opened = device.open(controller, work.replies);
    if (opened != 0 and opened != hcidev.HCIERR_NOTREADY) {
        sys.FreeVec(memory);
        return bluetooth.BTERR_OPENFAIL;
    }
    sys.ObtainSemaphore(&base.lock);
    controller.id = _controller.freeId(base);
    sys.AddTail(&base.controllers, &controller.node);
    sys.ReleaseSemaphore(&base.lock);
    if (opened == 0) {
        bringUp(work, controller);
    } else {
        exec.kprintf(sys, "%s: controller %u is %s unit %u, which its device is setting up\n", .{ @as([*:0]const u8, task_name), controller.id, @as([*:0]const u8, &controller.device_name), unit });
        _notify.changed(base);
    }
    return @intCast(controller.id);
}

/// An opened controller's bring-up begun and its reads sent.
fn bringUp(work: *Work, controller: *Controller) void {
    const base = work.base;
    const sys = base.sys_base;
    const layer = &controller.layer;
    layer.class_of_device = class_of_device;
    machineName(work, &layer.name);
    sys.ObtainSemaphore(&base.lock);
    layer.now = now(work);
    _hci.start(layer);
    sys.ReleaseSemaphore(&base.lock);
    device.startReads(controller);
    exec.kprintf(sys, "%s: controller %u is %s unit %u\n", .{ @as([*:0]const u8, task_name), controller.id, @as([*:0]const u8, &controller.device_name), controller.unit });
}

/// A controller's requests taken back, its device closed, and it gone
/// from the list.
fn remove(work: *Work, device_name: [*:0]const u8, unit: u32) void {
    const base = work.base;
    const sys = base.sys_base;
    const controller = _controller.find(base, device_name, unit) orelse return;
    device.close(controller);
    sys.ObtainSemaphore(&base.lock);
    sys.Remove(&controller.node);
    sys.ReleaseSemaphore(&base.lock);
    exec.kprintf(sys, "%s: controller %u gone\n", .{ @as([*:0]const u8, task_name), controller.id });
    sys.FreeVec(controller);
    _notify.changed(base);
}

/// The machine's name on the network, its first line, into `into`; the
/// system's own name where it has none.
fn machineName(work: *Work, into: *[hci.HCI_MAX_NAME + 1]u8) void {
    const sys = work.base.sys_base;
    _controller.copyString(into, default_name);
    const dos_base = work.base.dos orelse return;
    var length: usize = 0;
    const bytes = dos_base.ReadFile(hostname_file, hci.HCI_MAX_NAME, exec.MEMF_ANY, &length) orelse return;
    defer sys.FreeVec(bytes);
    var end: usize = 0;
    while (end < length and bytes[end] != '\n' and bytes[end] != '\r' and bytes[end] != 0) : (end += 1) {}
    while (end > 0 and bytes[end - 1] == ' ') end -= 1;
    if (end == 0) return;
    for (bytes[0..end], 0..) |byte, index| into[index] = byte;
    into[end] = 0;
}

// --- the requests' answers ------------------------------------------------------

fn replied(work: *Work, message: *exec.Message) void {
    const base = work.base;
    const sys = base.sys_base;
    if (message == &work.timer_io.node.message) {
        work.timer_out = false;
        const time = now(work);
        sys.ObtainSemaphore(&base.lock);
        defer sys.ReleaseSemaphore(&base.lock);
        var it = base.controllers.iterator();
        while (it.next()) |node| {
            const controller = _controller.fromNode(node);
            controller.layer.now = time;
            _hci.tick(&controller.layer);
        }
        return;
    }
    const request = device.requestOf(message);
    const controller = request.controller orelse return;
    const time = now(work);
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    device.replied(controller, request, time);
}

/// The timer sent for the earliest time-out of any controller, or sent
/// again for an earlier one than it is out for.
fn armTimer(work: *Work) void {
    const base = work.base;
    const sys = base.sys_base;
    var earliest: ?u64 = null;
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const due = _hci.nextDeadline(&_controller.fromNode(node).layer) orelse continue;
        if (earliest == null or due < earliest.?) earliest = due;
    }
    const due = earliest orelse return;
    if (work.timer_out) {
        if (work.timer_due <= due) return;
        _ = sys.AbortIO(&work.timer_io.node);
        _ = sys.WaitIO(&work.timer_io.node);
        work.timer_out = false;
    }
    const time = now(work);
    const wait_ms: u64 = if (due > time) due - time + 1 else 1;
    work.timer_io.node.command = timer.TR_ADDREQUEST;
    work.timer_io.time = timer.TimeVal.fromMicros(wait_ms * 1000);
    work.timer_due = due;
    work.timer_out = true;
    sys.SendIO(&work.timer_io.node);
}

/// What changed said in the log, and whoever asked told.
fn report(work: *Work) void {
    const base = work.base;
    const sys = base.sys_base;
    var any = false;
    sys.ObtainSemaphoreShared(&base.lock);
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const controller = _controller.fromNode(node);
        const layer = &controller.layer;
        if (!layer.changed) continue;
        layer.changed = false;
        any = true;
        if (layer.state == controller.reported) continue;
        controller.reported = layer.state;
        say(sys, controller);
    }
    sys.ReleaseSemaphore(&base.lock);
    if (any) _notify.changed(base);
}

fn say(sys: *ExecBase, controller: *Controller) void {
    const layer = &controller.layer;
    const address = layer.address;
    switch (layer.state) {
        bluetooth.BTCS_UP => exec.kprintf(sys, "%s: controller %u up, %02x:%02x:%02x:%02x:%02x:%02x, HCI %u.%u, maker %u\n", .{
            @as([*:0]const u8, task_name), controller.id,
            @as(u32, address[5]),          @as(u32, address[4]),
            @as(u32, address[3]),          @as(u32, address[2]),
            @as(u32, address[1]),          @as(u32, address[0]),
            @as(u32, layer.hci_version),   @as(u32, layer.hci_revision),
            @as(u32, layer.manufacturer),
        }),
        bluetooth.BTCS_FAILED => exec.kprintf(sys, "%s: controller %u failed (%ld), at step %u\n", .{
            @as([*:0]const u8, task_name),
            controller.id,
            @as(i64, layer.failure),
            @as(u32, layer.step),
        }),
        else => {},
    }
}

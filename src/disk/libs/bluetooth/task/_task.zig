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
//! **Time-outs.** Its timer is out while anything of any controller is
//! due - a command's answer, a discovery's phase, the end of being
//! visible for a time - due when the earliest of them is. The time is
//! exec's (UptimeUs), in milliseconds: the calls that answer how long
//! ago something was read the same clock.
//!
//! **Settings.** A controller's bring-up stops once its address is known
//! until the task has read the settings kept for it (settings.zig) and
//! put them into its layer; SetBTControllerAttrs's changes are written
//! back there.
//!
//! **Calls that wait for the controller** - ConnectBTDevice,
//! DisconnectBTDevice - are not answered at once: their command is
//! parked on the task's list with the wait its layer made
//! (hci/connections.zig), and answered once that is done - or once its
//! controller has gone.
//!
//! **Pairing.** What a pairing asks of its agent, and what it tells it,
//! the task sends as a BTAgentMessage to the agent's port; the agent's
//! answer comes back on a port of the task's own and is handed to the
//! layer (hci/pairing.zig) - or let go, when the question was given up on
//! meanwhile. The task does not end while a message of its is out. A
//! controller's bonds are read with its settings and written as they
//! change (bondfiles.zig).

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const hcidev = sdk.devices.hci;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("../bluetooth_base.zig");
const BluetoothBase = _base.BluetoothBase;
const _controller = @import("../controller/_controller.zig");
const Controller = _controller.Controller;
const _hci = @import("../hci/_hci.zig");
const bringup = @import("../hci/bringup.zig");
const connections = @import("../hci/connections.zig");
const devices = @import("../hci/devices.zig");
const discovery = @import("../hci/discovery.zig");
const local = @import("../hci/local.zig");
const bonds = @import("../hci/bonds.zig");
const hci_pairing = @import("../hci/pairing.zig");
const _notify = @import("../notify/_notify.zig");
const _pairing = @import("../pairing/_pairing.zig");
const bondfiles = @import("bondfiles.zig");
const device = @import("device.zig");
const settings = @import("settings.zig");
const DosBase = sdk.interface.dos.DosBase;

const task_name = "bluetooth.library";
const stack_bytes = 8192;

/// What the controllers show others until they are told otherwise: a
/// desktop computer, named as the machine is on the network - or, with no
/// name there, so.
const class_of_device = hci.COD_MAJOR_COMPUTER << 8 | hci.COD_COMPUTER_DESKTOP << 2;
const hostname_file = sdk.bsdsocket.HOSTNAME_FILE;
/// The most of the hostname file read: room for the comments above its
/// name.
const hostname_most = 1024;
const default_name = "PowerOS";

/// A call's command to the task.
pub const Command = extern struct {
    message: exec.Message = .{},
    kind: Kind = .add,
    /// add, remove: the device's unit.
    unit: u32 = 0,
    device_name: [*:0]const u8 = "",
    /// set, discover, stop, connect, disconnect, pair, unpair: the
    /// controller (BTController.id), or BT_ALL_CONTROLLERS.
    controller: u32 = 0,
    /// discover: for how long, in milliseconds (0: the default).
    time_ms: u32 = 0,
    /// set: what is wanted.
    wanted: Wanted = .{},
    /// connect, disconnect, pair, unpair: the device's address; while
    /// parked, the controller waited on and its wait.
    address: bluetooth.BTAddress = .{},
    waiting_on: ?*anyopaque = null,
    wait: u32 = 0,
    /// pair: the agent to ask and tell, by its number, and what its user
    /// can do; agents: the one given back, 0 for one added.
    agent: u32 = 0,
    capability: u32 = 0,
    /// What the call answers.
    result: i32 = 0,

    pub const Kind = enum(u32) { add, remove, set, discover, stop, connect, disconnect, pair, unpair, agents };
};

/// What SetBTControllerAttrs wants of a controller: `which` says which of
/// the rest is set (WANT_*). The name is the caller's, who waits.
pub const Wanted = extern struct {
    which: u32 = 0,
    powered: u32 = 0,
    visible: u32 = 0,
    name: [*:0]const u8 = "",
};
pub const WANT_POWERED: u32 = 1 << 0;
pub const WANT_NAME: u32 = 1 << 1;
pub const WANT_VISIBLE: u32 = 1 << 2;

/// The task's own: its ports, its timer, the calls parked on a wait, and
/// its room for a controller's settings and a name.
const Work = struct {
    base: *BluetoothBase,
    commands: *exec.MsgPort,
    replies: *exec.MsgPort,
    parked: exec.List = .{},
    timer_io: timer.TimeRequest = .{},
    timer_open: bool = false,
    timer_out: bool = false,
    /// When the timer out is due, in milliseconds.
    timer_due: u64 = 0,
    kept: settings.Kept = .{},
    name: [hci.HCI_MAX_NAME + 1]u8 = @splat(0),
    /// The hostname file's start, as it was last read.
    hostname: [hostname_most]u8 = undefined,
    /// Where the agents' answers come back, and how many messages are out.
    agent_replies: *exec.MsgPort,
    agent_out: u32 = 0,
    /// Room for a bond file: its directory's entry, the bond read, its
    /// text.
    bond_info: dos.FileInfoBlock = .{},
    bond: bonds.Bond = .{},
    bond_text: [bondfiles.TEXT_MOST]u8 = undefined,
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

/// A command handed to the task if it runs, and its answer waited for:
/// false if it does not - there is no controller to act on - or no reply
/// port could be made.
pub fn tell(base: *BluetoothBase, command: *Command) bool {
    const sys = base.sys_base;
    const reply = sys.CreateMsgPort() orelse return false;
    defer sys.DeleteMsgPort(reply);
    command.message.reply_port = reply;
    command.message.length = @sizeOf(Command);
    sys.ObtainSemaphore(&base.start_lock);
    const port = base.port orelse {
        sys.ReleaseSemaphore(&base.start_lock);
        return false;
    };
    sys.PutMsg(port, &command.message);
    sys.ReleaseSemaphore(&base.start_lock);
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
    return true;
}

/// The time in milliseconds: exec's, so that the task and the calls read
/// the same clock.
pub fn clock(sys: *ExecBase) u64 {
    return sys.UptimeUs() / 1000;
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
    const mask = (@as(u32, 1) << @intCast(work.commands.sig_bit)) | (@as(u32, 1) << @intCast(work.replies.sig_bit)) |
        (@as(u32, 1) << @intCast(work.agent_replies.sig_bit));
    while (true) {
        var worked = true;
        while (worked) {
            worked = false;
            while (sys.GetMsg(work.commands)) |message| {
                const command: *Command = @fieldParentPtr("message", message);
                switch (command.kind) {
                    .add => command.result = add(work, command.device_name, command.unit),
                    .remove => remove(work, command.device_name, command.unit),
                    .set => command.result = setAttrs(work, command.controller, &command.wanted),
                    .discover => command.result = discover(work, command.controller, command.time_ms),
                    .stop => stopDiscovery(work, command.controller),
                    .connect, .disconnect => if (link(work, command)) {
                        worked = true;
                        continue;
                    },
                    .pair => command.result = pair(work, command),
                    .unpair => {
                        command.result = unpair(work, command);
                        // Its file deleted before the call returns.
                        keepBonds(work);
                    },
                    .agents => agentsChanged(work, command.agent),
                }
                sys.ReplyMsg(message);
                worked = true;
            }
            while (sys.GetMsg(work.replies)) |message| {
                replied(work, message);
                worked = true;
            }
            while (sys.GetMsg(work.agent_replies)) |message| {
                agentReplied(work, message);
                worked = true;
            }
        }
        answerWaits(work);
        settle(work);
        keepBonds(work);
        askAgents(work);
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
    const agent_replies = sys.CreateMsgPort() orelse {
        sys.DeleteMsgPort(replies);
        sys.DeleteMsgPort(commands);
        sys.FreeVec(memory);
        return null;
    };
    work.* = .{ .base = base, .commands = commands, .replies = replies, .agent_replies = agent_replies };
    work.parked.init(.message);
    work.timer_io.node.message.reply_port = replies;
    work.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &work.timer_io.node, 0) != 0) {
        sys.DeleteMsgPort(agent_replies);
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
    sys.DeleteMsgPort(work.agent_replies);
    sys.DeleteMsgPort(work.replies);
    sys.DeleteMsgPort(work.commands);
    sys.FreeVec(work);
}

/// Whether the task ends now: no controller left, no command waiting and
/// no message out to an agent, looked at under `start_lock`, which a
/// caller holds to put one on the port. Its port is no one's from then
/// on.
fn ending(work: *Work) bool {
    const base = work.base;
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.start_lock);
    defer sys.ReleaseSemaphore(&base.start_lock);
    if (!base.controllers.isEmpty() or !work.commands.msg_list.isEmpty() or !work.parked.isEmpty()) return false;
    if (work.agent_out != 0) return false;
    base.port = null;
    base.task = null;
    return true;
}

fn now(work: *Work) u64 {
    return clock(work.base.sys_base);
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
    // Read before the lock, which ObtainBTControllers copies the name under.
    machineName(work, &work.name);
    const agent = _pairing.current(base);
    sys.ObtainSemaphore(&base.lock);
    layer.class_of_device = class_of_device;
    layer.agent_current = agent.id;
    layer.agent_capability = agent.capability;
    _controller.copyString(&layer.name, @ptrCast(&work.name));
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
    // Its pairings' agents told that it went.
    sys.ObtainSemaphore(&base.lock);
    for (&controller.layer.connections) |*connection| hci_pairing.linkGone(&controller.layer, connection, bluetooth.BTERR_DETACHED);
    sys.ReleaseSemaphore(&base.lock);
    askAgents(work);
    answerGone(work, controller);
    device.close(controller);
    sys.ObtainSemaphore(&base.lock);
    sys.Remove(&controller.node);
    sys.ReleaseSemaphore(&base.lock);
    exec.kprintf(sys, "%s: controller %u gone\n", .{ @as([*:0]const u8, task_name), controller.id });
    sys.FreeVec(controller);
    _notify.changed(base);
}

// --- the settings ---------------------------------------------------------------

/// Every controller whose bring-up waits for its settings given them:
/// read from its files outside the lock, put into its layer under it.
fn settle(work: *Work) void {
    const base = work.base;
    const sys = base.sys_base;
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const controller = _controller.fromNode(node);
        const layer = &controller.layer;
        if (!layer.wants_settings) continue;
        const kept = &work.kept;
        kept.* = .{};
        if (base.dos) |dl| {
            settings.read(dl, &layer.address, kept);
            loadBonds(work, dl, controller);
        }
        sys.ObtainSemaphore(&base.lock);
        layer.now = now(work);
        layer.powered = kept.powered;
        layer.visible = kept.visible;
        layer.visible_until = null;
        if (kept.name[0] != 0) {
            _controller.copyString(&layer.name, @ptrCast(&kept.name));
            controller.own_name = true;
        }
        bringup.settled(layer);
        sys.ReleaseSemaphore(&base.lock);
    }
}

/// SetBTControllerAttrs: what is wanted done to the controller - or to
/// every controller that is up - and kept: 0, or the first BTERR_* one
/// of them answered.
fn setAttrs(work: *Work, id: u32, wanted: *const Wanted) i32 {
    var matched = false;
    var done = false;
    var failure: i32 = 0;
    var it = work.base.controllers.iterator();
    while (it.next()) |node| {
        const controller = _controller.fromNode(node);
        if (id != bluetooth.BT_ALL_CONTROLLERS and controller.id != id) continue;
        matched = true;
        if (id == bluetooth.BT_ALL_CONTROLLERS and controller.layer.state != bluetooth.BTCS_UP) continue;
        const result = setOne(work, controller, wanted);
        if (result == 0) done = true else if (failure == 0) failure = result;
    }
    if (!matched) return bluetooth.BTERR_NOCONTROLLER;
    if (failure != 0) return failure;
    return if (done) 0 else bluetooth.BTERR_NOTUP;
}

fn setOne(work: *Work, controller: *Controller, wanted: *const Wanted) i32 {
    const base = work.base;
    const sys = base.sys_base;
    const layer = &controller.layer;
    if (layer.state != bluetooth.BTCS_UP) return bluetooth.BTERR_NOTUP;
    const naming = wanted.which & WANT_NAME != 0;
    const own = naming and wanted.name[0] != 0;
    // An empty name is the machine's again.
    if (naming and !own) machineName(work, &work.name);
    var result: i32 = 0;
    sys.ObtainSemaphore(&base.lock);
    layer.now = now(work);
    if (wanted.which & WANT_POWERED != 0) result = firstFailure(result, local.setPowered(layer, wanted.powered != 0));
    if (wanted.which & WANT_VISIBLE != 0) result = firstFailure(result, local.setVisible(layer, wanted.visible));
    if (naming) {
        controller.own_name = own;
        result = firstFailure(result, local.setName(layer, if (own) wanted.name else @ptrCast(&work.name)));
    }
    const powered = layer.powered;
    const visible_always = layer.visible and layer.visible_until == null;
    sys.ReleaseSemaphore(&base.lock);
    // Kept for the next start.
    const dl = base.dos orelse return result;
    var saved = true;
    if (wanted.which & (WANT_POWERED | WANT_VISIBLE) != 0) saved = settings.writeSettings(dl, &layer.address, powered, visible_always);
    if (naming) saved = settings.writeName(dl, &layer.address, if (own) wanted.name else "") and saved;
    if (!saved) exec.kprintf(sys, "%s: the settings of controller %u could not be kept\n", .{ @as([*:0]const u8, task_name), controller.id });
    return result;
}

fn firstFailure(so_far: i32, result: i32) i32 {
    return if (so_far != 0) so_far else result;
}

/// StartBTDiscovery: the controller - or every one that is up and on -
/// made to look for devices: 0, or the first BTERR_* one answered.
fn discover(work: *Work, id: u32, ms: u32) i32 {
    const base = work.base;
    const sys = base.sys_base;
    var matched = false;
    var done = false;
    // Every controller passed over that is up, but off.
    var off = false;
    var failure: i32 = 0;
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const controller = _controller.fromNode(node);
        if (id != bluetooth.BT_ALL_CONTROLLERS and controller.id != id) continue;
        matched = true;
        const layer = &controller.layer;
        if (id == bluetooth.BT_ALL_CONTROLLERS and (layer.state != bluetooth.BTCS_UP or !layer.powered)) {
            if (layer.state == bluetooth.BTCS_UP) off = true;
            continue;
        }
        sys.ObtainSemaphore(&base.lock);
        layer.now = now(work);
        const result = discovery.start(layer, ms);
        sys.ReleaseSemaphore(&base.lock);
        if (result == 0) done = true else if (failure == 0) failure = result;
    }
    if (!matched) return bluetooth.BTERR_NOCONTROLLER;
    if (failure != 0) return failure;
    if (done) return 0;
    return if (off) bluetooth.BTERR_OFF else bluetooth.BTERR_NOTUP;
}

/// StopBTDiscovery: the controller's discovery - or every one's - ended.
fn stopDiscovery(work: *Work, id: u32) void {
    const base = work.base;
    const sys = base.sys_base;
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const controller = _controller.fromNode(node);
        if (id != bluetooth.BT_ALL_CONTROLLERS and controller.id != id) continue;
        sys.ObtainSemaphore(&base.lock);
        controller.layer.now = now(work);
        discovery.stop(&controller.layer);
        sys.ReleaseSemaphore(&base.lock);
    }
}

// --- links ------------------------------------------------------------------------

/// ConnectBTDevice, DisconnectBTDevice: the link asked of its controller,
/// and the command parked until the controller has done it - true - or
/// answered at once.
fn link(work: *Work, command: *Command) bool {
    const base = work.base;
    const sys = base.sys_base;
    const controller = linkController(work, command) orelse return false;
    const layer = &controller.layer;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    layer.now = now(work);
    const begun = switch (command.kind) {
        .connect => connections.connect(layer, command.address),
        else => connections.disconnect(layer, command.address),
    };
    switch (begun) {
        .done => |result| {
            command.result = result;
            return false;
        },
        .waiting => |index| {
            command.wait = index;
            command.waiting_on = controller;
            sys.AddTail(&work.parked, &command.message.node);
            return true;
        },
    }
}

/// The controller a link is asked of: the one named, or - for
/// BT_ALL_CONTROLLERS - the one with a link to the device, else (to make
/// one) the one whose discovery found it, else the first that is up and
/// on. Null, the command's result set, for none. The task changes the
/// layers, so it reads them without the lock.
fn linkController(work: *Work, command: *Command) ?*Controller {
    var found: ?*Controller = null;
    var first_on: ?*Controller = null;
    var any = false;
    var any_up = false;
    var it = work.base.controllers.iterator();
    while (it.next()) |node| {
        const controller = _controller.fromNode(node);
        if (command.controller != bluetooth.BT_ALL_CONTROLLERS) {
            if (controller.id == command.controller) return controller;
            continue;
        }
        any = true;
        const layer = &controller.layer;
        if (layer.state != bluetooth.BTCS_UP) continue;
        any_up = true;
        if (connections.find(layer, command.address) != null) return controller;
        if (found == null and devices.find(layer, command.address.bytes, command.address.kind) != null) found = controller;
        if (first_on == null and layer.powered) first_on = controller;
    }
    command.result = bluetooth.BTERR_NOCONTROLLER;
    if (!any) return null;
    if (command.kind == .disconnect) {
        command.result = bluetooth.BTERR_NOTCONNECTED;
        return null;
    }
    if (found orelse first_on) |chosen| return chosen;
    command.result = if (any_up) bluetooth.BTERR_OFF else bluetooth.BTERR_NOTUP;
    return null;
}

/// Every parked call whose wait is done answered with its result.
fn answerWaits(work: *Work) void {
    const base = work.base;
    const sys = base.sys_base;
    if (work.parked.isEmpty()) return;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    var it = work.parked.iterator();
    while (it.next()) |node| {
        const message: *exec.Message = @fieldParentPtr("node", node);
        const command: *Command = @fieldParentPtr("message", message);
        const controller: *Controller = @ptrCast(@alignCast(command.waiting_on.?));
        const index: u8 = @intCast(command.wait);
        const wait = &controller.layer.waits[index];
        if (!wait.done) continue;
        command.result = wait.result;
        connections.release(&controller.layer, index);
        sys.Remove(node);
        sys.ReplyMsg(message);
    }
}

/// The calls parked on a controller that goes answered: it is gone.
fn answerGone(work: *Work, controller: *Controller) void {
    const sys = work.base.sys_base;
    var it = work.parked.iterator();
    while (it.next()) |node| {
        const message: *exec.Message = @fieldParentPtr("node", node);
        const command: *Command = @fieldParentPtr("message", message);
        if (command.waiting_on != @as(?*anyopaque, controller)) continue;
        command.result = bluetooth.BTERR_DETACHED;
        sys.Remove(node);
        sys.ReplyMsg(message);
    }
}

/// The machine's name on the network - the hostname file's first line
/// that is neither blank nor a comment - into `into`, cut as the
/// controller's name is; the system's own name where it has none.
fn machineName(work: *Work, into: *[hci.HCI_MAX_NAME + 1]u8) void {
    const found = hostName(work) orelse return _controller.copyString(into, default_name);
    const length = local.fitName(found);
    @memcpy(into[0..length], found[0..length]);
    into[length] = 0;
}

/// The name in the hostname file, read into the work's room for it; null
/// without the file, or without a name in it.
fn hostName(work: *Work) ?[]const u8 {
    const dl = work.base.dos orelse return null;
    const file = dl.Open(hostname_file, dos.MODE_OLDFILE) orelse return null;
    const got = dl.Read(file, &work.hostname, work.hostname.len);
    _ = dl.Close(file);
    if (got <= 0) return null;
    return settings.hostNameIn(work.hostname[0..@intCast(got)]);
}

// --- pairing ----------------------------------------------------------------------

/// PairBTDevice: a pairing begun on the controller named - or, for
/// BT_ALL_CONTROLLERS, on the one a link would be made on: 0, or why not.
fn pair(work: *Work, command: *Command) i32 {
    const base = work.base;
    const sys = base.sys_base;
    const controller = linkController(work, command) orelse return command.result;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    controller.layer.now = now(work);
    const capability: ?u32 = if (command.agent != 0) command.capability else null;
    return hci_pairing.pair(&controller.layer, command.address, command.agent, capability);
}

/// UnpairBTDevice: the bond with the device ended on the controller named
/// - or on every controller that has one: 0, or why not.
fn unpair(work: *Work, command: *Command) i32 {
    const base = work.base;
    const sys = base.sys_base;
    var matched = false;
    var done = false;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const controller = _controller.fromNode(node);
        if (command.controller != bluetooth.BT_ALL_CONTROLLERS and controller.id != command.controller) continue;
        matched = true;
        controller.layer.now = now(work);
        if (hci_pairing.unpair(&controller.layer, command.address) == 0) done = true;
    }
    if (!matched) return bluetooth.BTERR_NOCONTROLLER;
    return if (done) 0 else bluetooth.BTERR_NOTBONDED;
}

/// The agents changed - one added, or `gone` given back: every
/// controller's pairings that asked the one gone refused, and the agent
/// added last made the one a device's pairing goes to.
fn agentsChanged(work: *Work, gone: u32) void {
    const base = work.base;
    const sys = base.sys_base;
    const agent = _pairing.current(base);
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const layer = &_controller.fromNode(node).layer;
        layer.now = now(work);
        if (gone != 0) hci_pairing.agentGone(layer, gone);
        layer.agent_current = agent.id;
        layer.agent_capability = agent.capability;
    }
}

/// A controller's bond files read into its table, each put in under the
/// lock.
fn loadBonds(work: *Work, dl: *DosBase, controller: *Controller) void {
    const base = work.base;
    const sys = base.sys_base;
    var reader = bondfiles.Reader.open(dl, &controller.layer.address, &work.bond_info);
    defer reader.close();
    var count: u32 = 0;
    while (reader.next(&work.bond_info, &work.bond)) {
        sys.ObtainSemaphore(&base.lock);
        const kept = bonds.loaded(&controller.layer, &work.bond);
        sys.ReleaseSemaphore(&base.lock);
        if (kept) count += 1;
    }
    if (count != 0) exec.kprintf(sys, "%s: controller %u has %u bonds\n", .{ @as([*:0]const u8, task_name), controller.id, count });
}

/// Every bond made or changed since written to its file, and every one
/// ended its file deleted. The task alone changes the tables, so it reads
/// a bond without the lock and marks it written under it.
fn keepBonds(work: *Work) void {
    const base = work.base;
    const sys = base.sys_base;
    const dl = base.dos orelse return;
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const controller = _controller.fromNode(node);
        const layer = &controller.layer;
        if (!layer.bonds_changed) continue;
        var kept = true;
        while (true) {
            sys.ObtainSemaphore(&base.lock);
            const next = bonds.nextDirty(layer);
            sys.ReleaseSemaphore(&base.lock);
            const bond = next orelse break;
            const done = if (bond.gone) bondfiles.delete(dl, &layer.address, &bond.address.bytes) else bondfiles.write(dl, &layer.address, bond, &work.bond_text);
            if (!done) kept = false;
            sys.ObtainSemaphore(&base.lock);
            bonds.written(bond);
            sys.ReleaseSemaphore(&base.lock);
        }
        if (!kept) exec.kprintf(sys, "%s: the bonds of controller %u could not all be kept\n", .{ @as([*:0]const u8, task_name), controller.id });
    }
}

/// What the pairings ask of their agents, and tell them, sent: each in a
/// message of its own, which the agent replies. A question with no agent
/// to ask - none, or one gone - or no memory for its message, is refused;
/// a notice without either is let go. The agents' lock is held while
/// their ports are sent to.
fn askAgents(work: *Work) void {
    const base = work.base;
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    sys.ObtainSemaphoreShared(&base.agents_lock);
    defer sys.ReleaseSemaphore(&base.agents_lock);
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const controller = _controller.fromNode(node);
        const layer = &controller.layer;
        layer.now = now(work);
        for (&layer.connections) |*connection| {
            const question = &connection.pairing.question;
            if (question.kind == 0 or question.sent) continue;
            const agent = _pairing.find(base, connection.pairing.agent) orelse {
                hci_pairing.unasked(layer, connection);
                continue;
            };
            const message = newMessage(work, layer, question.kind, controller.id, connection.address) orelse {
                hci_pairing.unasked(layer, connection);
                continue;
            };
            message.number = question.number;
            message.ours = @intFromBool(connection.pairing.ours);
            question.sent = true;
            question.message = message;
            send(work, agent, message);
        }
        for (layer.notices[0..layer.notice_count]) |*item| {
            const agent = _pairing.find(base, item.agent) orelse continue;
            const kind = switch (item.kind) {
                .show => bluetooth.BTAK_SHOW,
                .done => bluetooth.BTAK_DONE,
            };
            const message = newMessage(work, layer, kind, controller.id, item.address) orelse continue;
            message.number = item.number;
            message.result = item.result;
            message.ours = @intFromBool(item.ours);
            send(work, agent, message);
        }
        layer.notice_count = 0;
    }
}

/// A message for an agent, its reply port the task's, the device's name in
/// it as the controller knows it; null for no memory.
fn newMessage(work: *Work, layer: *_hci.Hci, kind: u32, id: u32, address: bluetooth.BTAddress) ?*bluetooth.BTAgentMessage {
    const sys = work.base.sys_base;
    const memory = sys.AllocVec(@sizeOf(bluetooth.BTAgentMessage), exec.MEMF_CLEAR) orelse return null;
    const message: *bluetooth.BTAgentMessage = @ptrCast(@alignCast(memory));
    message.* = .{ .kind = kind, .controller = id, .address = address };
    message.message.node.type = .message;
    message.message.reply_port = work.agent_replies;
    message.message.length = @sizeOf(bluetooth.BTAgentMessage);
    nameOf(layer, address, &message.name);
    return message;
}

/// The device's name - its link's, its bond's, or what the discovery
/// heard - into `into`, cut to what a message carries; empty for none.
fn nameOf(layer: *_hci.Hci, address: bluetooth.BTAddress, into: *[bluetooth.BT_BOND_NAME_MOST + 1]u8) void {
    var name: []const u8 = "";
    if (connections.find(layer, address)) |connection| {
        name = &connection.name;
    } else if (bonds.find(layer, address)) |bond| {
        name = &bond.name;
    } else if (devices.find(layer, address.bytes, address.kind)) |heard| {
        name = &heard.name;
    }
    var length: usize = 0;
    while (length < name.len and length < bluetooth.BT_BOND_NAME_MOST and name[length] != 0) length += 1;
    // A whole character: a cut UTF-8 sequence is let go.
    while (length > 0 and length < name.len and name[length] & 0xC0 == 0x80) length -= 1;
    @memcpy(into[0..length], name[0..length]);
    into[length] = 0;
}

fn send(work: *Work, agent: *_pairing.Agent, message: *bluetooth.BTAgentMessage) void {
    work.agent_out += 1;
    work.base.sys_base.PutMsg(agent.port, &message.message);
}

/// A message an agent replied: an answer handed to its controller's
/// layer, which lets it go when the question was given up on; then
/// freed.
fn agentReplied(work: *Work, message: *exec.Message) void {
    const base = work.base;
    const sys = base.sys_base;
    const answer: *bluetooth.BTAgentMessage = @fieldParentPtr("message", message);
    work.agent_out -= 1;
    switch (answer.kind) {
        bluetooth.BTAK_CONFIRM, bluetooth.BTAK_PASSKEY, bluetooth.BTAK_PIN => {
            sys.ObtainSemaphore(&base.lock);
            defer sys.ReleaseSemaphore(&base.lock);
            var it = base.controllers.iterator();
            while (it.next()) |node| {
                const controller = _controller.fromNode(node);
                if (controller.id != answer.controller) continue;
                controller.layer.now = now(work);
                const length = @min(answer.pin_length, bluetooth.BT_PIN_MOST);
                _ = hci_pairing.agentAnswered(&controller.layer, answer, answer.accept != 0, answer.passkey, answer.pin[0..length]);
            }
        },
        else => {},
    }
    sys.FreeVec(answer);
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

/// What changed said in the log - a controller's state, its links - and
/// whoever asked told.
fn report(work: *Work) void {
    const base = work.base;
    const sys = base.sys_base;
    var any = false;
    sys.ObtainSemaphore(&base.lock);
    var it = base.controllers.iterator();
    while (it.next()) |node| {
        const controller = _controller.fromNode(node);
        const layer = &controller.layer;
        for (layer.notes[0..layer.note_count]) |*note| sayLink(sys, controller.id, note);
        layer.note_count = 0;
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

/// A link up, not made or down - a pairing over, a link not made secure -
/// in the log: the device, how, and why.
fn sayLink(sys: *ExecBase, id: u32, note: *const connections.Note) void {
    const bytes = note.address.bytes;
    const over: [*:0]const u8 = if (!note.le) "BR/EDR" else if (note.address.kind == bluetooth.BTADDR_LE_RANDOM) "LE random" else "LE";
    const line = "%s: controller %u, %02x:%02x:%02x:%02x:%02x:%02x over %s ";
    const name: [*:0]const u8 = task_name;
    const head = .{ name, id, @as(u32, bytes[5]), @as(u32, bytes[4]), @as(u32, bytes[3]), @as(u32, bytes[2]), @as(u32, bytes[1]), @as(u32, bytes[0]), over };
    switch (note.kind) {
        .up => {
            const made: [*:0]const u8 = if (note.incoming) "the device" else "this machine";
            exec.kprintf(sys, line ++ "up, handle %u, made by %s\n", head ++ .{ @as(u32, note.handle), made });
        },
        .not_made => sayReason(sys, line ++ "not made: ", head, note.reason),
        .down => sayReason(sys, line ++ "down: ", head, note.reason),
        .paired => exec.kprintf(sys, line ++ "paired\n", head),
        .not_paired => sayReason(sys, line ++ "not paired: ", head, note.reason),
        .not_secured => sayReason(sys, line ++ "not made secure: ", head, note.reason),
    }
}

/// A note's line ended with its reason: the controller's status in hex,
/// BTERR_* as it is.
fn sayReason(sys: *ExecBase, comptime text: []const u8, head: anytype, reason: i32) void {
    if (reason >= 0) {
        exec.kprintf(sys, text ++ "0x%02lx\n", head ++ .{@as(u64, @intCast(reason))});
    } else {
        exec.kprintf(sys, text ++ "%ld\n", head ++ .{@as(i64, reason)});
    }
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

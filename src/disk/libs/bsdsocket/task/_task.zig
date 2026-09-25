// SPDX-License-Identifier: MIT
//! The stack task: a process that keeps the reads on every network device
//! outstanding, takes what the devices answer, and runs the timers. It
//! spends its life in one Wait on four signals - the devices' answers,
//! commands, a changed deadline, its timer - and does nothing else, so
//! an idle network costs nothing.
//!
//! It is started by the first interface on a device (loopback needs no
//! task) and ends with the last one: removing an interface is a command
//! to it, since only the task can wait for the device's answers on its own
//! port. Its last act is to answer that command under Forbid, so it is
//! gone before the library can be expunged under it.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const _base = @import("../bsdsocket_base.zig");
const StackBase = _base.StackBase;
const _lock = @import("../lock/_lock.zig");
const _timer = @import("../timer/_timer.zig");
const _netif = @import("../netif/_netif.zig");
const Interface = _netif.Interface;
const device = @import("../netif/device.zig");
const _route = @import("../route/_route.zig");
const _arp = @import("../arp/_arp.zig");

const task_name = "bsdsocket.library";
const stack_bytes = 8192;

/// A command for the task: an interface to take down.
pub const Command = extern struct {
    message: exec.Message = .{},
    interface: ?*Interface = null,
};

/// The task started, if it is not running; false if it could not be.
/// On the caller's task, which waits until the task is ready.
pub fn start(stack: *StackBase) bool {
    const sys = stack.sys_base;
    if (stack.task != null) return true;
    const dos_base = stack.dos orelse blk: {
        const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return false;
        stack.dos = @ptrCast(lib);
        break :blk stack.dos.?;
    };
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    defer sys.FreeSignal(signal);
    stack.starter = sys.FindTask(null);
    stack.start_signal = signal;
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&stackTask) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(task_name) },
        .{ .tag = dos.NP_StackSize, .data = stack_bytes },
        .{ .tag = dos.NP_Priority, .data = @as(usize, @bitCast(@as(isize, _base.stack_pri))) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(stack) },
        .{},
    };
    if (dos_base.CreateNewProc(&tags) == null) return false;
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    stack.starter = null;
    return stack.task != null;
}

/// The one who started the task told it is ready, or could not be.
fn started(stack: *StackBase) void {
    const starter = stack.starter orelse return;
    stack.sys_base.Signal(starter, @as(u32, 1) << @intCast(stack.start_signal));
}

/// A port given the task's signal, or put back to take messages without
/// one.
fn claimPort(sys: *ExecBase, port: *exec.MsgPort, task: ?*exec.Task, signal: i8) void {
    sys.Disable();
    defer sys.Enable();
    if (task) |owner| {
        port.sig_bit = @intCast(signal);
        port.sig_task = owner;
        port.flags = exec.PA_SIGNAL;
    } else {
        port.flags = exec.PA_IGNORE;
        port.sig_task = null;
    }
}

fn stackTask(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const stack: *StackBase = @ptrCast(@alignCast(me.user_data orelse return));
    const port_signal = sys.AllocSignal(-1);
    const command_signal = sys.AllocSignal(-1);
    const rethink_signal = sys.AllocSignal(-1);
    const timer_port = sys.CreateMsgPort();
    var clock: timer.TimeRequest = .{};
    if (port_signal < 0 or command_signal < 0 or rethink_signal < 0 or timer_port == null) return started(stack);
    clock.node.message.reply_port = timer_port;
    clock.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return started(stack);
    stack.timer_base = @ptrCast(clock.node.device.?);
    claimPort(sys, &stack.port, me, port_signal);
    claimPort(sys, &stack.commands, me, command_signal);
    stack.rethink_mask = @as(u32, 1) << @intCast(rethink_signal);
    stack.task = me;
    started(stack);

    const wake = stack.port.sigMask() | stack.commands.sigMask() | stack.rethink_mask | timer_port.?.sigMask();
    var armed = false;
    var armed_for: u64 = 0;
    while (true) {
        _ = sys.Wait(wake);
        if (armed and sys.CheckIO(&clock.node) != null) {
            _ = sys.WaitIO(&clock.node);
            armed = false;
        }

        const held = _lock.take(stack);
        const now = _timer.systemTime(stack);
        _timer.run(stack, now);
        while (sys.GetMsg(&stack.port)) |message| device.complete(stack, &message.node, now);
        for (&stack.interfaces) |*interface| {
            if (interface.used == 0 or interface.device == null) continue;
            device.retryReads(stack, @ptrCast(@alignCast(interface.device.?)));
        }
        const next = _timer.earliest(stack);
        _lock.give(stack, held);

        // The one timer request set for the earliest deadline.
        if (armed and (next == null or next.? != armed_for)) {
            _ = sys.AbortIO(&clock.node);
            _ = sys.WaitIO(&clock.node);
            armed = false;
        }
        if (!armed) {
            if (next) |deadline| {
                clock.node.command = timer.TR_ADDREQUEST;
                clock.time = timer.TimeVal.fromMicros(if (deadline > now) deadline - now else 1);
                sys.SendIO(&clock.node);
                armed = true;
                armed_for = deadline;
            }
        }

        while (sys.GetMsg(&stack.commands)) |message| {
            const command: *Command = @fieldParentPtr("message", message);
            remove(stack, command.interface.?);
            if (devicesLeft(stack)) {
                sys.ReplyMsg(message);
                continue;
            }
            // The last one: the task goes, and says so under Forbid, so it
            // is gone before anything can unload the code it runs.
            if (armed) {
                _ = sys.AbortIO(&clock.node);
                _ = sys.WaitIO(&clock.node);
            }
            sys.CloseDevice(&clock.node);
            sys.DeleteMsgPort(timer_port);
            claimPort(sys, &stack.port, null, -1);
            claimPort(sys, &stack.commands, null, -1);
            sys.Forbid();
            stack.timer_base = null;
            stack.task = null;
            stack.rethink_mask = 0;
            sys.ReplyMsg(message);
            return;
        }
    }
}

fn devicesLeft(stack: *StackBase) bool {
    for (&stack.interfaces) |*interface| {
        if (interface.used != 0 and interface.device != null) return true;
    }
    return false;
}

/// `interface` taken down, on the task: off the routes and the ARP cache
/// first, then every request the device has taken back, the device
/// closed, and the slot free.
fn remove(stack: *StackBase, interface: *Interface) void {
    const sys = stack.sys_base;
    const link: *device.Device = @ptrCast(@alignCast(interface.device.?));
    {
        const held = _lock.take(stack);
        defer _lock.give(stack, held);
        link.going = 1;
        interface.up = 0;
        _route.removeAll(stack, interface);
        _arp.forget(stack, interface);
    }
    device.drain(stack, link);
    sys.CloseDevice(&link.opened.req);
    {
        const held = _lock.take(stack);
        defer _lock.give(stack, held);
        interface.* = .{};
    }
    sys.FreeMem(link, @sizeOf(device.Device));
    sys.Forbid();
    stack.lib.open_cnt -= 1;
    sys.Permit();
}

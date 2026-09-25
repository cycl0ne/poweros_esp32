// SPDX-License-Identifier: MIT
//! The stack task: a process that keeps the reads on every network device
//! outstanding, takes what the devices answer, and runs the timers. It
//! spends its life in one Wait on four signals - the devices' answers,
//! commands, a changed deadline, its timer - and does nothing else, so
//! an idle network costs nothing.
//!
//! **Its life.** It is started when there is work only it can do: the
//! first interface on a device, or the first stream socket, whose timers
//! it runs. It ends when there is neither any more - no device
//! interface, no TCP connection, not even one its program has closed and
//! that is still saying goodbye. While it runs it holds the library open,
//! and it lets go of that last, under Forbid, so the library cannot be
//! expunged under code that is still running.
//!
//! Removing an interface is a command to it, since only the task can
//! wait for the device's answers on its own port.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bsd = sdk.bsdsocket;
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
const _socket = @import("../socket/_socket.zig");

const task_name = "bsdsocket.library";
const stack_bytes = 8192;

/// A command for the task: an interface to take down.
pub const Command = extern struct {
    message: exec.Message = .{},
    interface: ?*Interface = null,
};

/// The task started, if it is not running; false if it could not be.
/// On the caller's task, which waits until the task is ready. One caller
/// at a time starts it.
pub fn start(stack: *StackBase) bool {
    const sys = stack.sys_base;
    if (stack.no_task != 0) return true;
    sys.ObtainSemaphore(&stack.start_lock);
    defer sys.ReleaseSemaphore(&stack.start_lock);
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

/// Whether the task has work: an interface on a device, or a stream
/// socket. Under the lock.
fn busy(stack: *StackBase) bool {
    for (&stack.interfaces) |*interface| {
        if (interface.used != 0 and interface.device != null) return true;
    }
    var it = stack.sockets.iterator();
    while (it.next()) |node| {
        if (_socket.fromNode(node).socket_type == bsd.SOCK_STREAM) return true;
    }
    return false;
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
    // The library stays while the task runs.
    sys.Forbid();
    stack.lib.open_cnt += 1;
    sys.Permit();
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

        var held = _lock.take(stack);
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
            sys.ReplyMsg(message);
        }

        // Nothing left to do: the task goes. It gives up its ports and
        // its place under the lock, so a caller that needs a task from
        // here on starts a new one.
        held = _lock.take(stack);
        const idle = !busy(stack);
        if (idle) {
            claimPort(sys, &stack.port, null, -1);
            claimPort(sys, &stack.commands, null, -1);
            stack.rethink_mask = 0;
            stack.timer_base = null;
            stack.task = null;
        }
        _lock.give(stack, held);
        if (!idle) continue;
        if (armed) {
            _ = sys.AbortIO(&clock.node);
            _ = sys.WaitIO(&clock.node);
        }
        sys.CloseDevice(&clock.node);
        sys.DeleteMsgPort(timer_port);
        // The last thing, under Forbid: the library may go once this
        // count is down, and nothing of the task runs after it.
        sys.Forbid();
        stack.lib.open_cnt -= 1;
        return;
    }
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
        // The lease given back while the device still sends.
        @import("../dhcp/_dhcp.zig").stop(stack, interface);
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

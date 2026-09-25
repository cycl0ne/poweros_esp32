// SPDX-License-Identifier: MIT
//! telnet.device: a TCP connection as a stream of bytes, the Telnet
//! protocol taken off it (sdk/devices/telnet.zig). It is in DEVS:, loaded
//! by ramlib when a console is put on it.
//!
//! **A unit is a connection**, and its number the id a socket was left
//! under. OpenDevice makes the unit and starts its task (unit.zig), which
//! takes the socket with its own bsdsocket.library base - a socket
//! belongs to its opener's base - and answers once it has it; without it
//! the open fails. CloseDevice ends the task and with it the connection,
//! and frees the unit. Requests go to the task: BeginIO only queues
//! them.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const _telnet = @import("_telnet.zig");
const TelnetBase = _telnet.TelnetBase;
const Unit = _telnet.Unit;
const unit_file = @import("unit.zig");

pub const DEVICE_NAME = _telnet.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "25.9.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// bsdsocket.library's calls run on the task's stack.
const stack_size = 8192;
/// Above the shells it serves, as the other devices' tasks are.
const task_pri = 5;

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const base = _telnet.telnetBase(dev);
    io.err = 0;
    switch (io.command) {
        exec.CMD_READ, exec.CMD_WRITE, exec.CMD_FLUSH => {
            // It will be replied, so it needs a reply port, and it is not
            // quick I/O.
            if (io.message.reply_port == null) {
                io.err = exec.IOERR_NOREPLYPORT;
            } else {
                io.flags &= ~exec.IOF_QUICK;
                return base.sys_base.PutMsg(&_telnet.unitOf(io).unit.msg_port, &io.message);
            }
        },
        else => io.err = exec.IOERR_NOCMD,
    }
    base.sys_base.ReplyIO(io);
}

/// A request the task has not taken yet, or a read waiting for data, is
/// answered as aborted; a write being sent cannot be stopped.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const sys = _telnet.telnetBase(dev).sys_base;
    const unit = _telnet.unitOf(io);
    sys.Forbid();
    for ([_]*exec.List{ &unit.unit.msg_port.msg_list, &unit.reads }) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            const msg: *exec.Message = @fieldParentPtr("node", node);
            if (&_telnet.requestOf(msg).req != io) continue;
            sys.Remove(node);
            sys.Permit();
            io.err = exec.IOERR_ABORTED;
            sys.ReplyIO(io);
            return 0;
        }
    }
    sys.Permit();
    return -1;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const base = _telnet.telnetBase(dev);
    const sys = base.sys_base;
    if (io.message.length != 0 and io.message.length < @sizeOf(exec.IOStdReq)) return exec.IOERR_BADLENGTH;
    const memory = sys.AllocVec(@sizeOf(Unit), exec.MEMF_CLEAR) orelse return exec.IOERR_OPENFAIL;
    const unit: *Unit = @ptrCast(@alignCast(memory));
    unit.* = .{ .base = base, .id = @bitCast(unit_number) };
    // PA_IGNORE until the task has a signal for it.
    unit.unit.msg_port = .{ .flags = exec.PA_IGNORE };
    unit.unit.msg_port.msg_list.init(.message);
    unit.reads.init(.message);
    const stack = sys.AllocVec(stack_size, exec.MEMF_CLEAR) orelse {
        sys.FreeVec(memory);
        return exec.IOERR_OPENFAIL;
    };
    unit.stack = stack;
    unit.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    if (!runTask(sys, unit, null) or unit.socket < 0) {
        sys.FreeVec(stack);
        sys.FreeVec(memory);
        return exec.IOERR_OPENFAIL;
    }
    unit.unit.open_cnt = 1;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    io.unit = &unit.unit;
    return 0;
}

/// The task started, or told to quit, and waited for: until it has the
/// socket, or until it is gone.
fn runTask(sys: *ExecBase, unit: *Unit, quit: ?u32) bool {
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    defer sys.FreeSignal(signal);
    unit.wait_signal = signal;
    unit.waiter = sys.FindTask(null);
    if (quit) |mask| {
        sys.Signal(&unit.task, mask);
    } else {
        _ = sys.AddTask(&unit.task, &unit_file.unitTask, null);
    }
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    return true;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const base = _telnet.telnetBase(dev);
    const sys = base.sys_base;
    const unit = _telnet.unitOf(io);
    // A signal of the closer's is needed to see the task go; with none
    // left the unit is left behind rather than freed under it.
    if (runTask(sys, unit, unit.quit_mask)) {
        sys.FreeVec(unit.stack);
        sys.FreeVec(unit);
    }
    io.unit = null;
    dev.open_cnt -= 1;
    return null;
}

/// The device stays once it is loaded: the seglist is kept in the base.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _telnet.telnetBase(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;
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
    .data_size = @sizeOf(TelnetBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// No flags but AUTOINIT: the device is on the disk, and is made when
/// something opens it. In `.resident`, which program.ld KEEPs.
export const telnet_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &telnet_device_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 0,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};

/// A device is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;

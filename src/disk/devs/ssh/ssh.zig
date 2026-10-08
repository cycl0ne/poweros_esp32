// SPDX-License-Identifier: MIT
//! ssh.device: a TCP connection that speaks SSH as a stream of bytes
//! (sdk/devices/ssh.zig). It is in DEVS:, loaded by ramlib when
//! ShellServer opens it.
//!
//! **A unit is a connection**, its number the id a socket was left under.
//! The first OpenDevice makes the unit: its protocol's state
//! (`connection.zig`), crypto.library opened for it, and its task
//! (`unit.zig`), which takes the socket and answers once it has it;
//! without it the open fails. Later opens of the same number - the
//! console's - share the unit. The last CloseDevice ends the task and with
//! it the connection, and frees the unit. Requests go to the task:
//! BeginIO only queues them.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ssh = sdk.devices.ssh;
const serial = sdk.devices.serial;
const crypto = sdk.crypto;
const ExecBase = sdk.interface.exec.ExecBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const _ssh = @import("_ssh.zig");
const SshBase = _ssh.SshBase;
const Unit = _ssh.Unit;
const unit_file = @import("unit.zig");
const Connection = @import("connection.zig").Connection;

pub const DEVICE_NAME = _ssh.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 1;
const BUILD_DATE = "08.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// bsdsocket.library's and crypto.library's calls run on the task's
/// stack, the curves' and ML-KEM's among them.
const stack_size = 24576;
/// Above the shells it serves, as the other devices' tasks are.
const task_pri = 5;

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const base = _ssh.sshBase(dev);
    io.err = 0;
    switch (io.command) {
        exec.CMD_READ, exec.CMD_WRITE, exec.CMD_FLUSH, ssh.SSHCMD_ACCEPT, ssh.SSHCMD_EXIT, serial.SDCMD_TERMSIZE => {
            // It will be replied, so it needs a reply port, and it is not
            // quick I/O.
            if (io.message.reply_port == null) {
                io.err = exec.IOERR_NOREPLYPORT;
            } else {
                io.flags &= ~exec.IOF_QUICK;
                return base.sys_base.PutMsg(&_ssh.unitOf(io).unit.msg_port, &io.message);
            }
        },
        else => io.err = exec.IOERR_NOCMD,
    }
    base.sys_base.ReplyIO(io);
}

/// A request the task has not taken yet, a read waiting for data, a
/// write waiting for the window or an accept waiting for the session is
/// answered as aborted; a write being sent cannot be stopped.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const sys = _ssh.sshBase(dev).sys_base;
    const unit = _ssh.unitOf(io);
    // Not taken by the task yet: off its port, under the port's own lock.
    if (sys.RemoveMsg(&unit.unit.msg_port, &io.message)) {
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    sys.AcquireLock(&unit.lock);
    var found = false;
    if (unit.accept) |waiting| {
        if (&waiting.req == io) {
            unit.accept = null;
            found = true;
        }
    }
    if (!found) {
        for ([_]*exec.List{ &unit.reads, &unit.writes }, 0..) |list, index| {
            var it = list.iterator();
            while (it.next()) |node| {
                const msg: *exec.Message = @fieldParentPtr("node", node);
                if (&_ssh.requestOf(msg).req != io) continue;
                // A write partly gone is let finish.
                if (index == 1 and node == list.first() and unit.written > 0) break;
                sys.Remove(node);
                found = true;
                break;
            }
            if (found) break;
        }
    }
    sys.ReleaseLock(&unit.lock);
    if (!found) return -1;
    io.err = exec.IOERR_ABORTED;
    sys.ReplyIO(io);
    return 0;
}

/// The unit already open on the socket left under `id`.
fn findUnit(base: *SshBase, id: i32) ?*Unit {
    var it = base.units.iterator();
    while (it.next()) |node| {
        const unit: *Unit = @alignCast(@fieldParentPtr("link", node));
        if (unit.id == id) return unit;
    }
    return null;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const base = _ssh.sshBase(dev);
    const sys = base.sys_base;
    if (io.message.length != 0 and io.message.length < @sizeOf(exec.IOStdReq)) return exec.IOERR_BADLENGTH;
    const id: i32 = @bitCast(unit_number);
    const unit = findUnit(base, id) orelse (makeUnit(sys, base, id) orelse return exec.IOERR_OPENFAIL);
    unit.unit.open_cnt += 1;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    io.unit = &unit.unit;
    return 0;
}

/// A new unit for the socket left under `id`, its task running and the
/// socket taken; null when any of it fails, with nothing left behind.
fn makeUnit(sys: *ExecBase, base: *SshBase, id: i32) ?*Unit {
    const crypto_lib = sys.OpenLibrary(crypto.CRYPTONAME, 1) orelse return null;
    const cb: *CryptoBase = @ptrCast(crypto_lib);
    const connection_memory = sys.AllocVec(@sizeOf(Connection), exec.MEMF_ANY) orelse {
        sys.CloseLibrary(crypto_lib);
        return null;
    };
    const conn: *Connection = @ptrCast(@alignCast(connection_memory));
    conn.* = .{ .cb = cb };
    const memory = sys.AllocVec(@sizeOf(Unit), exec.MEMF_CLEAR) orelse return giveBack(sys, crypto_lib, connection_memory, null, null);
    const unit: *Unit = @ptrCast(@alignCast(memory));
    unit.* = .{ .base = base, .id = id, .crypto = cb, .connection = conn };
    // PA_IGNORE until the task has a signal for it.
    unit.unit.msg_port = .{ .flags = exec.PA_IGNORE };
    unit.unit.msg_port.msg_list.init(.message);
    unit.reads.init(.message);
    unit.writes.init(.message);
    sys.InitLock(&unit.lock, DEVICE_NAME, exec.LOCKORDER_DRIVER, 0);
    const stack = sys.AllocVec(stack_size, exec.MEMF_CLEAR) orelse return giveBack(sys, crypto_lib, connection_memory, memory, null);
    unit.stack = stack;
    unit.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    if (!runTask(sys, unit, null) or unit.socket < 0) return giveBack(sys, crypto_lib, connection_memory, memory, stack);
    sys.AddTail(&base.units, &unit.link);
    return unit;
}

/// What makeUnit took, given back: null, for it to answer.
fn giveBack(sys: *ExecBase, crypto_lib: *exec.Library, connection_memory: *anyopaque, memory: ?*anyopaque, stack: ?*anyopaque) ?*Unit {
    if (stack) |taken| sys.FreeVec(taken);
    if (memory) |taken| sys.FreeVec(taken);
    sys.FreeVec(connection_memory);
    sys.CloseLibrary(crypto_lib);
    return null;
}

/// The task started, or told to quit, and waited for: until it has the
/// socket, or until it is gone. Gone is exec's to say (SetTaskEndMsg): it
/// replies a message once nothing runs on the task's stack any more, so
/// the stack and the unit may be freed at once.
fn runTask(sys: *ExecBase, unit: *Unit, quit: ?u32) bool {
    const port = sys.CreateMsgPort() orelse return false;
    defer sys.DeleteMsgPort(port);
    var ended: exec.Message = .{ .reply_port = port };
    // The task's word that it is ready comes on the port's signal too.
    unit.wait_signal = @intCast(port.sig_bit);
    unit.waiter = sys.FindTask(null);
    if (quit) |quit_mask| {
        sys.SetTaskEndMsg(&unit.task, &ended);
        sys.Signal(&unit.task, quit_mask);
        while (sys.GetMsg(port) == null) _ = sys.Wait(port.sigMask());
        return true;
    }
    // Told when it has the socket - or, should it fail, once it is gone:
    // set before it runs, so its end cannot come first.
    unit.task.end_msg = &ended;
    _ = sys.AddTask(&unit.task, &unit_file.unitTask, null);
    while (true) {
        _ = sys.Wait(port.sigMask());
        if (sys.GetMsg(port) != null) return true; // gone, without a socket
        if (unit.socket >= 0) break;
    }
    // Running: its end is Close's to hear, with a message of Close's own.
    sys.SetTaskEndMsg(&unit.task, null);
    return true;
}

fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const base = _ssh.sshBase(dev);
    const sys = base.sys_base;
    const unit = _ssh.unitOf(io);
    io.unit = null;
    dev.open_cnt -= 1;
    unit.unit.open_cnt -= 1;
    if (unit.unit.open_cnt != 0) return null;
    sys.Remove(&unit.link);
    // A signal of the closer's is needed to see the task go; with none
    // left the unit is left behind rather than freed under it.
    if (runTask(sys, unit, unit.quit_mask)) {
        const crypto_lib = unit.crypto.lib();
        sys.FreeVec(unit.stack);
        sys.FreeVec(unit.connection);
        sys.FreeVec(unit);
        sys.CloseLibrary(crypto_lib);
    }
    return null;
}

/// The device stays once it is loaded: the seglist is kept in the base.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _ssh.sshBase(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;
    base.units.init(.unknown);
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
    .data_size = @sizeOf(SshBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// No flags but AUTOINIT: the device is on the disk, and is made when
/// something opens it. In `.resident`, which program.ld KEEPs.
export const ssh_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &ssh_device_tag,
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

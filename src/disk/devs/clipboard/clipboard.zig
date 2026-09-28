// SPDX-License-Identifier: MIT
//! clipboard.device: what is cut, copied and pasted, a unit at a time.
//! It is in DEVS:, loaded by ramlib when something opens it.
//!
//! A unit is a clip and its bytes are a file in `CLIPS:`, which the
//! startup-sequence assigns to a drawer of `RAM:`. Writing one is
//! `CMD_WRITE` from offset 0 and then `CMD_UPDATE`; reading it is
//! `CMD_READ` from wherever the reader is. What goes in is IFF - an
//! `FTXT` form for text, an `ILBM` for a picture - so that what one
//! program cuts another can paste whatever it is, and
//! iffparse.library's `InitIFFasClip` reads and writes it.
//!
//! The work is done by a process of the device's own (`server.zig`),
//! because dos needs one; `BeginIO` puts the request on its port and
//! nothing else. The unit and the base are `_clipboard.zig`.
//!
//! Not done: `CBD_POST`, which names a port instead of writing and
//! leaves the data with the program that offered it until somebody asks
//! for it. It needs the offering program to stay alive and to answer a
//! message with the data, which is a conversation nothing here holds;
//! a program that would post writes the clip instead.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const clipboard = sdk.devices.clipboard;
const ExecBase = sdk.interface.exec.ExecBase;
const _clip = @import("_clipboard.zig");
const ClipBase = _clip.ClipBase;
const Unit = _clip.Unit;
const server = @import("server.zig");

pub const DEVICE_NAME = _clip.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "29.09.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const base = _clip.clipBase(dev);
    io.err = 0;
    switch (io.command) {
        exec.CMD_READ,
        exec.CMD_WRITE,
        exec.CMD_UPDATE,
        clipboard.CBD_CURRENTREADID,
        clipboard.CBD_CURRENTWRITEID,
        clipboard.CBD_CHANGEHOOK,
        => {
            // The work is the server's, so it is never quick I/O and it
            // needs somewhere to come back to.
            if (io.message.reply_port == null) {
                io.err = exec.IOERR_NOREPLYPORT;
            } else {
                io.flags &= ~exec.IOF_QUICK;
                return base.sys_base.PutMsg(&base.port, &io.message);
            }
        },
        else => io.err = exec.IOERR_NOCMD,
    }
    base.sys_base.ReplyIO(io);
}

/// A request the server has not taken yet is answered as aborted; one it
/// is doing is a file call that cannot be stopped.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const sys = _clip.clipBase(dev).sys_base;
    const base = _clip.clipBase(dev);
    sys.Forbid();
    defer sys.Permit();
    var it = base.port.msg_list.iterator();
    while (it.next()) |node| {
        const msg: *exec.Message = @fieldParentPtr("node", node);
        if (&_clip.requestOf(msg).io.req != io) continue;
        sys.Remove(node);
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    return -1;
}

/// The server started and waited for, so that the first request finds a
/// port that answers.
fn startServer(base: *ClipBase) bool {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.start_lock);
    defer sys.ReleaseSemaphore(&base.start_lock);
    if (base.server != null) return true;
    const dl = base.dos_base orelse return false;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return false;
    defer sys.FreeSignal(signal);
    base.starter = sys.FindTask(null);
    base.start_signal = signal;
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&server.serverProcess) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(DEVICE_NAME) },
        .{ .tag = dos.NP_StackSize, .data = _clip.stack_bytes },
        .{ .tag = dos.NP_Priority, .data = @as(usize, @bitCast(@as(isize, _clip.server_pri))) },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(base) },
        .{},
    };
    if (dl.CreateNewProc(&tags) == null) {
        base.starter = null;
        return false;
    }
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
    base.starter = null;
    return base.server != null;
}

/// The unit of that number, made the first time it is asked for.
fn unitFor(base: *ClipBase, number: u32) ?*Unit {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.lock);
    defer sys.ReleaseSemaphore(&base.lock);
    var it = base.units.iterator();
    while (it.next()) |node| {
        const unit: *Unit = @fieldParentPtr("unit", @as(*exec.Unit, @ptrCast(@alignCast(node))));
        if (unit.number == number) return unit;
    }
    const memory = sys.AllocVec(@sizeOf(Unit), exec.MEMF_CLEAR) orelse return null;
    const unit: *Unit = @ptrCast(@alignCast(memory));
    unit.* = .{ .base = base, .number = number };
    unit.unit.msg_port.msg_list.init(.message);
    unit.hooks.init();
    _clip.nameUnit(unit);
    unit.unit.msg_port.node.name = @ptrCast(&unit.name);
    sys.AddTail(&base.units, @ptrCast(&unit.unit.msg_port.node));
    return unit;
}

fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    _ = flags;
    const base = _clip.clipBase(dev);
    const sys = base.sys_base;
    if (io.message.length != 0 and io.message.length < @sizeOf(clipboard.IOClipReq)) return exec.IOERR_BADLENGTH;
    if (base.dos_base == null) {
        const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return exec.IOERR_OPENFAIL;
        base.dos_base = @ptrCast(lib);
    }
    if (!startServer(base)) return exec.IOERR_OPENFAIL;
    const unit = unitFor(base, unit_number) orelse return exec.IOERR_OPENFAIL;
    unit.unit.open_cnt += 1;
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    io.unit = &unit.unit;
    return 0;
}

/// A unit stays once it is made: the clip it holds outlives the program
/// that cut it, which is the whole point of a clipboard.
fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const unit = _clip.unitOf(io);
    if (unit.unit.open_cnt != 0) unit.unit.open_cnt -= 1;
    if (unit.unit.open_cnt == 0) _clip.closeFiles(unit);
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
    const base = _clip.clipBase(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;
    base.dos_base = null;
    base.server = null;
    base.starter = null;
    base.units.init(.unknown);
    base.port = .{ .flags = exec.PA_IGNORE };
    base.port.msg_list.init(.message);
    sys_base.InitSemaphore(&base.start_lock);
    sys_base.InitSemaphore(&base.lock);
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
    .data_size = @sizeOf(ClipBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// No flags but AUTOINIT: the device is on the disk, and is made when
/// something opens it. In `.resident`, which program.ld KEEPs.
export const clipboard_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &clipboard_device_tag,
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

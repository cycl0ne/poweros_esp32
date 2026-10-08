// SPDX-License-Identifier: MIT
//! slip.device: IP over a serial line (RFC 1055) as a network device
//! (sdk/devices/network.zig, sdk/devices/slip.zig). Each unit is a line:
//! the serial device, unit and speed its first opener names in the open's
//! tags, opened then and given back at its last close. A frame is a bare
//! IPv4 or IPv6 packet, the link has no addresses, and its MTU is 1006.
//!
//! **Every request runs on the device's own task**, except S2_DEVICEQUERY
//! and S2_GETSTATIONADDRESS, which are answered where they are asked. The
//! serial line's answers come to the same task, on the same signal, so
//! one Wait serves the openers and the lines. OpenDevice and CloseDevice
//! open and close the serial line through the task as well - a request of
//! the device's own that the caller waits for - since the line's answers
//! are the task's.
//!
//! **The link is up while the line is open.** A serial line says nothing
//! of the other end, so the unit is online as it is told to be.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const serial = sdk.devices.serial;
const slip = sdk.devices.slip;
const timer = sdk.devices.timer;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const _slip = @import("_slip.zig");
const SlipBase = _slip.SlipBase;
const Line = _slip.Line;

pub const DEVICE_NAME = _slip.DEVICE_NAME;
const DEVICE_VERSION = 1;
const DEVICE_REVISION = 0;
const BUILD_DATE = "08.10.2026";
const DEVICE_VERSION_STRING =
    "\x00$VER: " ++ DEVICE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ DEVICE_VERSION, DEVICE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const vec = exec.libraries.vec;

/// Enough for a request and the openers' copy calls; nothing here
/// recurses.
const stack_size = 4096;
/// As the other network devices' tasks.
const task_pri = 5;

/// The device's own requests, which OpenDevice and CloseDevice send to
/// the task: the serial line opened, and closed.
const attach: u16 = 0xF000;
const detach: u16 = 0xF001;

// --- the task -------------------------------------------------------------

/// Every request, and every serial answer, of every line.
fn slipTask(sys: *ExecBase) callconv(.c) void {
    const base: *SlipBase = @fieldParentPtr("task", sys.FindTask(null).?);
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return started(base);
    base.work_mask = @as(u32, 1) << @intCast(signal);
    sys.Disable();
    for (&base.lines) |*line| {
        for ([_]*exec.MsgPort{ &line.unit.msg_port, &line.serial_port }) |port| {
            port.sig_bit = @intCast(signal);
            port.sig_task = &base.task;
            port.flags = exec.PA_SIGNAL;
        }
    }
    sys.Enable();

    base.timer_io = .{};
    base.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &base.timer_io.node, 0) == 0) base.timer_open = 1;
    base.ready = 1;
    started(base);

    while (true) {
        // Every port looked at again after any work: a write waits for
        // the serial line on the same signal, and may take it from an
        // answer that came meanwhile.
        var worked = true;
        while (worked) {
            worked = false;
            for (&base.lines) |*line| {
                while (sys.GetMsg(&line.serial_port)) |_| {
                    line.readDone();
                    worked = true;
                }
                while (sys.GetMsg(&line.unit.msg_port)) |msg| {
                    perform(line, _slip.requestOf(msg));
                    worked = true;
                }
            }
        }
        _ = sys.Wait(base.work_mask);
    }
}

/// The init is waiting to hear that the task is ready for requests.
fn started(base: *SlipBase) void {
    if (base.starter) |starter| {
        const bit: u5 = @intCast(base.start_signal);
        base.starter = null;
        base.sys_base.Signal(starter, @as(u32, 1) << bit);
    }
}

fn perform(line: *Line, io: *exec.IORequest) void {
    switch (io.command) {
        attach => {
            io.err = open(line);
            line.base.?.sys_base.ReplyIO(io);
        },
        detach => {
            close(line);
            line.base.?.sys_base.ReplyIO(io);
        },
        else => line.net.perform(_slip.sanaReq(io)),
    }
}

/// The serial line opened, on the task, as the first opener named it.
fn open(line: *Line) i8 {
    const sys = line.base.?.sys_base;
    line.reader = .{ .io_ser = .{ .req = .{ .message = .{ .reply_port = &line.serial_port, .length = @sizeOf(serial.IOExtSer) } } } };
    line.reader.rbuf_len = _slip.serial_buffer_bytes;
    const name: [*:0]const u8 = @ptrCast(&line.serial_name);
    if (sys.OpenDevice(name, line.serial_unit, &line.reader.io_ser.req, 0) != 0) return exec.IOERR_OPENFAIL;
    line.writer = line.reader;
    line.serial_open = 1;
    // A unit that was configured on a line before goes on line again.
    line.net.setCarrier(true);
    return 0;
}

/// The serial line given back, on the task: the read taken back first.
fn close(line: *Line) void {
    if (line.serial_open == 0) return;
    line.setRunning(false);
    line.net.setCarrier(false);
    line.base.?.sys_base.CloseDevice(&line.reader.io_ser.req);
    line.serial_open = 0;
}

// --- the device -----------------------------------------------------------

/// The commands the task answers.
fn queued(command: u16) bool {
    return switch (command) {
        exec.CMD_READ,
        exec.CMD_WRITE,
        exec.CMD_FLUSH,
        net.S2_CONFIGINTERFACE,
        net.S2_ADDMULTICASTADDRESS,
        net.S2_DELMULTICASTADDRESS,
        net.S2_MULTICAST,
        net.S2_BROADCAST,
        net.S2_TRACKTYPE,
        net.S2_UNTRACKTYPE,
        net.S2_GETTYPESTATS,
        net.S2_GETSPECIALSTATS,
        net.S2_GETGLOBALSTATS,
        net.S2_ONEVENT,
        net.S2_READORPHAN,
        net.S2_ONLINE,
        net.S2_OFFLINE,
        attach,
        detach,
        => true,
        else => false,
    };
}

fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
    const base = _slip.slipBase(dev);
    const line = _slip.lineOf(io);
    const req = _slip.sanaReq(io);
    io.err = 0;
    // S2_ONEVENT carries its mask here; every other request is told of a
    // wire error only if there is one.
    if (io.command != net.S2_ONEVENT and io.command != attach and io.command != detach) req.wire_error = 0;
    switch (io.command) {
        net.S2_DEVICEQUERY => line.net.query(req),
        net.S2_GETSTATIONADDRESS => line.net.stationAddress(req),
        else => if (queued(io.command)) {
            // It will be replied, so it needs a reply port, and it is not
            // quick I/O.
            if (io.message.reply_port == null) {
                io.err = exec.IOERR_NOREPLYPORT;
                io.flags |= exec.IOF_QUICK;
            } else {
                io.flags &= ~exec.IOF_QUICK;
                return base.sys_base.PutMsg(&line.unit.msg_port, &io.message);
            }
        } else {
            io.err = exec.IOERR_NOCMD;
        },
    }
    base.sys_base.ReplyIO(io);
}

/// A request the task hasn't taken yet, or one waiting in the unit - a
/// read, a write, an event - is taken back and answered as aborted. One
/// being sent can't be stopped.
fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
    const base = _slip.slipBase(dev);
    const sys = base.sys_base;
    const line = _slip.lineOf(io);
    sys.Disable();
    var it = line.unit.msg_port.msg_list.iterator();
    while (it.next()) |node| {
        const msg: *exec.Message = @fieldParentPtr("node", node);
        if (_slip.requestOf(msg) != io) continue;
        sys.Remove(node);
        sys.Enable();
        io.err = exec.IOERR_ABORTED;
        sys.ReplyIO(io);
        return 0;
    }
    sys.Enable();
    return if (line.net.abort(_slip.sanaReq(io))) 0 else -1;
}

/// One of the device's own requests to `line`'s task, waited for: 0, or
/// its error.
fn control(dev: *exec.Device, line: *Line, command: u16) i8 {
    const sys = _slip.slipBase(dev).sys_base;
    const port = sys.CreateMsgPort() orelse return exec.IOERR_OPENFAIL;
    defer sys.DeleteMsgPort(port);
    var req: net.IOSana2Req = .{};
    req.req.message.reply_port = port;
    req.req.message.length = @sizeOf(net.IOSana2Req);
    req.req.device = dev;
    req.req.unit = &line.unit;
    req.req.command = command;
    return @truncate(sys.DoIO(&req.req));
}

/// The unit's first opener names the line from its tags, and the task
/// opens it; every opener then gets its record from the unit.
fn openDevice(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
    const base = _slip.slipBase(dev);
    if (unit_number >= slip.SLIP_UNITS or base.ready == 0) return exec.IOERR_OPENFAIL;
    if (io.message.length != 0 and io.message.length < @sizeOf(net.IOSana2Req)) return exec.IOERR_BADLENGTH;
    const line = &base.lines[unit_number];
    const req = _slip.sanaReq(io);
    const first = line.unit.open_cnt == 0;
    if (first) {
        const ub = base.utility.?;
        const tags: ?[*]const utility.TagItem = @ptrCast(@alignCast(req.buffer_management));
        const name: [*:0]const u8 = @ptrFromInt(ub.GetTagData(slip.SLIP_SerialDevice, @intFromPtr(serial.SERIALNAME.ptr), tags));
        var length: usize = 0;
        while (name[length] != 0 and length < line.serial_name.len - 1) : (length += 1) line.serial_name[length] = name[length];
        line.serial_name[length] = 0;
        line.serial_unit = @truncate(ub.GetTagData(slip.SLIP_SerialUnit, _slip.default_serial_unit, tags));
        line.baud = @truncate(ub.GetTagData(slip.SLIP_Baud, _slip.default_baud, tags));
        const refused = control(dev, line, attach);
        if (refused != 0) return refused;
    }
    const refused = line.net.open(req, flags, base.utility.?);
    if (refused != 0) {
        if (first) _ = control(dev, line, detach);
        return refused;
    }
    dev.open_cnt += 1;
    dev.flags &= ~exec.LIBF_DELEXP;
    line.unit.open_cnt += 1;
    io.unit = &line.unit;
    return 0;
}

/// The unit's last opener gives the line back.
fn closeDevice(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    const line = _slip.lineOf(io);
    line.net.close(_slip.sanaReq(io));
    line.unit.open_cnt -= 1;
    dev.open_cnt -= 1;
    if (line.unit.open_cnt == 0) _ = control(dev, line, detach);
    return null;
}

/// The device stays: it owns its task. The seglist it was loaded from is
/// kept in the base for the day it does go.
fn expunge(_: *exec.Device) callconv(.c) ?*anyopaque {
    return null;
}

/// exec has copied the tag's name, version and ID string into the base.
/// The lines are made, each not configured and with no serial line yet,
/// and the task is started; this waits until it takes requests.
fn init(dev: *exec.Device, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Device {
    dev.revision = DEVICE_REVISION;
    const base = _slip.slipBase(dev);
    base.sys_base = sys_base;
    base.seg_list = seg_list;

    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    base.utility = @ptrCast(utility_lib);

    const factory: [6]u8 = @splat(0);
    for (&base.lines) |*line| {
        // PA_IGNORE until the task has a signal for them: a request that
        // comes in while the device starts is queued, and the task takes
        // it then.
        line.unit = .{ .msg_port = .{ .flags = exec.PA_IGNORE } };
        line.unit.msg_port.msg_list.init(.message);
        line.serial_port = .{ .flags = exec.PA_IGNORE };
        line.serial_port.msg_list.init(.message);
        line.base = base;
        line.serial_unit = _slip.default_serial_unit;
        line.baud = _slip.default_baud;
        line.net.init(sys_base, line, &factory);
    }

    const stack = sys_base.AllocMem(stack_size, exec.MEMF_CLEAR) orelse {
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    base.stack = stack;
    base.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = DEVICE_NAME },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };

    const signal = sys_base.AllocSignal(-1);
    if (signal >= 0) {
        base.starter = sys_base.FindTask(null);
        base.start_signal = @intCast(signal);
    }
    _ = sys_base.AddTask(&base.task, &slipTask, null);
    if (signal >= 0) {
        _ = sys_base.Wait(@as(u32, 1) << @intCast(signal));
        sys_base.FreeSignal(@intCast(signal));
    }
    return dev;
}

/// The jump table: the six standard vectors, nothing past AbortIO.
const vectors = [_]*const anyopaque{
    vec(openDevice),
    vec(closeDevice),
    vec(expunge),
    vec(exec.libExtFunc),
    vec(beginIO),
    vec(abortIO),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(SlipBase),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// No flags but AUTOINIT: the device is on the disk, in DEVS:networks/,
/// and is made when something opens it - ramlib loads the file and hands
/// this tag to InitResident.
export const slip_device_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &slip_device_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = DEVICE_VERSION,
    .pri = 0,
    .type = .device,
    .name = DEVICE_NAME,
    .id_string = DEVICE_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};

/// A device is not a command. Whoever runs this file gets nothing done and
/// a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a device, not a command\n", .{DEVICE_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [DEVICE_VERSION_STRING.len:0]u8 linksection(".version") = DEVICE_VERSION_STRING.*;
